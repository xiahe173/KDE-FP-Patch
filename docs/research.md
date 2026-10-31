# Fingerprint unlock on the KDE lock screen — research & fix

**Machine:** Kubuntu / Ubuntu 26.04.1 (resolute), Plasma **6.6.5/6.6.6**, Wayland
**Reader:** Elan `04f3:0c7e` (libfprint 1.95.1 TOD), one enrolled finger
**Stack:** `fprintd 1.94.5`, `pam_fprintd`, `kscreenlocker 6.6.5`, SDDM 0.21

---

## 1. Short answer

Yes, there is a solution, and it does **not** need a kernel/driver change or a
Plasma upgrade. What you are seeing is a combination of three separate
integration bugs:

1. **Ubuntu/Debian's `kde-fingerprint` PAM file is broken** — it contains
   `auth optional pam_kwallet5.so`, which asks for a password *after* the finger
   was accepted. kscreenlocker cannot answer prompts in its non-interactive PAM
   stack, so the whole stack hangs until you press Enter. This is exactly
   [Launchpad #2172578](https://bugs.launchpad.net/ubuntu/+source/kscreenlocker/+bug/2172578),
   reported against the very same `libkscreenlocker6 6.6.5-0ubuntu0.1`.
2. **kscreenlocker 6.6 does not start authentication until you move the
   mouse/press a key** — so the first finger touch does nothing
   ([KDE bug 469810](https://bugs.kde.org/show_bug.cgi?id=469810), still open).
3. **The lock-screen theme throws away the fingerprint status messages and does
   not re-arm the reader after the PAM timeout** — hence "no prompt", "silent
   timeout", "must press Enter to start the next recognition"
   ([KDE bug 469951](https://bugs.kde.org/show_bug.cgi?id=469951), fixed only in
   Plasma 6.8).

A two-part fix lives in this repository:

| Part | Files | What it fixes |
|---|---|---|
| **A. PAM** (safe, 2 files) | `/etc/pam.d/kde-fingerprint`, `/etc/pam.d/kde` | finger accepted → immediate unlock; no wallet prompt; no 10 s fingerprint wait when you press Enter; no double-claim of the reader |
| **B. Lock-screen QML** (3 files) | `LockScreen.qml`, `LockScreenUi.qml`, `MainBlock.qml` | auth starts at lock time; live "Place your finger…" / "not recognized" prompts; automatic re-arm after timeout; password field only after 3 failed scans (or one click) |

Part A alone already removes the "finger accepted, but nothing happens until
Enter" behaviour (you still have to wake the screen with the mouse/keyboard
first). Part B gives the Windows/phone-like experience. Both can be rolled
back.

---

## 2. What is actually happening (evidence from this machine)

kscreenlocker has supported several PAM services in parallel since Plasma 6.0
(`kde` = password, `kde-fingerprint`, `kde-smartcard`). It starts all of them
when the lock UI is armed. On this machine:

```
$ ls /usr/lib/pam.d/
kde  kde-fingerprint  kde-smartcard
```

`/usr/lib/pam.d/kde-fingerprint` (shipped by `libkscreenlocker6`) ends with:

```
auth    required   pam_fprintd.so
auth    optional   pam_kwallet5.so      <-- the problem
...
session optional   pam_kwallet5.so auto_start
```

`pam_kwallet5.so` wants the login password to unlock the wallet. After a
successful fingerprint there is no `PAM_AUTHTOK`, so it opens a PAM
conversation and asks `Password: `. That conversation belongs to the
*non-interactive* stack, which by design has no way to answer prompts. The
stack blocks. When you finally press Enter, the interactive stack's
conversation gets an error, `pam_kwallet5` (optional) gives up and returns
success, and only then does the fingerprint stack report success.

The journal on this machine shows exactly that sequence:

```
kscreenlocker_greet: pam_kwallet5(kde-fingerprint:auth): pam_sm_authenticate
kscreenlocker_greet: pam_kwallet5(kde-fingerprint:auth): Couldn't get password (it is empty)
...
kscreenlocker_greet: pam_kwallet5(kde-fingerprint:auth): Prompt for password failed Conversation error
kscreenlocker_greet: pam_kwallet5(kde-fingerprint:setcred): pam_sm_setcred   <- unlock happens here
```

(It also explains why the same bug is reported for smartcards — `kde-smartcard`
has the same `pam_kwallet5` line.)

### Measured proof of the password-stack problem

I reproduced both stacks in an isolated PAM config directory (via
`pam_start_confdir`, so the system config was not touched) and authenticated
with a deliberately wrong password:

```
stock   /usr/lib/pam.d/kde : 12.77 s
        messages: "Place your right index finger on the fingerprint reader"
                  "Verification timed out"
                  "Password: "

patched /etc/pam.d/kde     :  1.58 s
        messages: "Password: "
```

So today, every Enter on the lock screen first starts a 10-second fingerprint
attempt (from `common-auth`) before `pam_unix` is even asked. That is the
"press Enter and wait / press Enter again to retry" behaviour, and it also
means two PAM stacks fight over the same fprintd device.

The theme problems are visible in the shipped QML:

* `LockScreenUi.qml` only handles `onNoninteractiveError` and shows it for
  `Kirigami.Units.humanMoment` in `FailableLabel`; `onNoninteractiveInfo`
  ("Place your finger on the fingerprint reader", "Verification timed out") is
  never connected, so those messages are dropped on the floor.
* `MainBlock.qml` has no status line for the fingerprint reader at all.
* Authentication is only started from `onUiVisibleChanged` (mouse/key) and a
  3-second grace timer — never when the lock becomes effective.
* In 6.6.5, `PamAuthenticators::startAuthenticating()` returns early while
  `state == Authenticating`. After a non-interactive failure the state is *not*
  reset, so the reader stays dead until an interactive (password) failure resets
  it. That is the "only Enter revives it" behaviour.
* `pam_fprintd` defaults are `max-tries=3 timeout=30`; "Verification timed out"
  is sent as `PAM_TEXT_INFO`, which the theme ignores → silent 90-second death.

One more detail specific to this machine: Ubuntu's `/etc/pam.d/common-auth`
starts with

```
auth [success=2 default=ignore] pam_fprintd.so max-tries=1 timeout=10
```

Since the lock screen's password service (`kde`) includes `common-auth`, the
password stack *also* starts `pam_fprintd` in parallel with the fingerprint
stack. Both try to `Claim` the same fprintd device; one fails with
"Device was already claimed", and pressing Enter can sit in the 10-second
fingerprint timeout before `pam_unix` is even consulted. The PAM patch removes
`pam_fprintd` from the lock screen's password stack only; `sudo`/SDDM keep
Ubuntu's behaviour.

### Symptom → cause map

| What you see | Root cause | Fixed by |
|---|---|---|
| No fingerprint event/prompt ever shown | theme ignores `noninteractiveInfo`; errors only flash for ~1 s | B |
| Finger accepted, but unlock only after Enter | `pam_kwallet5` blocks `kde-fingerprint` | A |
| Touch sensor before moving mouse does nothing | auth starts only on `uiVisible` | B |
| Reader silently times out and dies | 30 s PAM timeout, message is info-only, no re-arm | A (`timeout=-1`) + B (re-arm) |
| Have to press Enter to start the *next* recognition | `state` stays `Authenticating`, so re-arm is a no-op | B |
| After several failures you get no explanation | `max-tries=3` then generic "Unlocking failed" | A + B (counter + message) |
| Password field always visible | stock theme layout | B |

---

## 3. Upstream status (checked 2026-10-31)

* **Bug 469951** ("fingerprint times out … only re-activated by entering your
  password incorrectly") — **RESOLVED FIXED in 6.8.0**. Plasma 6.8 got the
  heartbeat/re-arm rework in `PamAuthenticators`.
* **Bug 469810** ("allow non-password auth without moving the mouse first") —
  still **CONFIRMED** (last change 2026-10-26). MR
  [!3891](https://invent.kde.org/plasma/plasma-desktop/-/merge_requests/3891)
  tried to start auth from the magical `locked` property but was **closed**;
  [kscreenlocker !351](https://invent.kde.org/plasma/kscreenlocker/-/merge_requests/351)
  (re-arm after timeout) is still **open**. Plasma 6.8 reworks the PAM layer
  and arms certain paths earlier, but the theme still starts on `uiVisible` and
  the bug has not been closed, so this is not something to rely on.
* **Bug 514444** ("stuck until nudged by another request") — closed WORKSFORME.
* **Launchpad 2172578** — new, unassigned; it is a packaging bug in
  `/usr/lib/pam.d/kde-fingerprint`, not an upstream kscreenlocker bug.
* `v6.6.6` and `v6.6.7` of kscreenlocker contain **only version bumps** — no
  fingerprint fixes. Kubuntu 26.04's backports PPA currently offers
  `plasma-workspace 4:6.6.6`, i.e. still 6.6.x.
* Plasma 6.8 was released 2026-10-14, but 26.04 is an LTS on 6.6 and will not
  get it through normal updates.

So: waiting for updates on 26.04 will not fix this. The patch below backports
the required behaviour into 6.6 without rebuilding kscreenlocker.

---

## 4. What the patch changes

### A. PAM (`/etc/pam.d/kde-fingerprint`, `/etc/pam.d/kde`)

`/etc/pam.d` overrides the vendor files in `/usr/lib/pam.d` (libpam searches
`/etc/pam.d` first), so no package files are touched.

`kde-fingerprint` becomes:

```
auth requisite pam_nologin.so
auth required  pam_succeed_if.so user != root quiet_success
auth required  pam_fprintd.so max-tries=-1 timeout=-1
...
```

* `pam_kwallet5` removed from `auth` and `session` → no more blocking prompt.
* `max-tries=-1 timeout=-1` → reader stays armed and keeps retrying; no silent
  30 s/90 s death. Negative values are supported since fprintd 1.94.5 (the
  "unlimited timeout" fix, upstream MR 195, merged 2025-02-20).
* `password required pam_fprintd.so` (nonsense for password changes) removed.

`kde` becomes the same stack as before but with `pam_unix` instead of
`@include common-auth`, so the lock screen's password stack no longer starts a
second `pam_fprintd` and no longer waits 10 s before checking the password.
`pam_kwallet5` is kept here, so a password unlock still unlocks the wallet.

### B. Lock-screen QML

`LockScreen.qml` (theme root):

```qml
property bool locked: false
onLockedChanged: if (locked) authenticator.startAuthenticating()
```

kscreenlocker already writes this magical `locked` property
(`QQmlProperty(view->rootObject(), "locked")` in `greeterapp.cpp`); the Breeze
theme simply never declared it, so the write was silently dropped. With the
property declared, authentication (fingerprint + password) starts the moment
the lock becomes effective — no mouse, no key.

`LockScreenUi.qml`:

* shows `noninteractiveInfo` / `noninteractiveError` in a persistent status
  string (`"Place your right index finger on the fingerprint reader"`,
  `"Failed to match fingerprint"`, …);
* counts failed scans and reveals the password after 3;
* on a non-interactive failure calls `stopAuthenticating()` then
  `startAuthenticating()` after 1.5 s, which resets the stuck `Authenticating`
  state in 6.6 and re-arms the reader (up to 5 times, then falls back to
  password);
* shows a dim "Touch the fingerprint sensor" hint in the clock-only view, so
  there is a prompt before you touch anything;
* stops pending PAM jobs on success.

`MainBlock.qml`:

* hides the password row while fingerprint is available and no failures;
* keeps a permanent prompt on the user/login page: "Please scan your
  fingerprint on the reader", replaced by live messages ("Place your right
  index finger…", "Failed to match fingerprint", "Fingerprint not recognized.
  Try again or enter your password.", "Fingerprint reader unavailable…");
* shows the smartcard hint "(or scan your smartcard)" on its own line below the
  fingerprint prompt, so they never overlap;
* on a non-matching scan, shows the PAM error ("Failed to match fingerprint")
  for 2.5 s and shakes the prompt like the stock theme — fprintd immediately
  re-sends "Place your finger" after each no-match, so the error must not be
  driven by the latest status message;
* offers a **"Use password instead"** button, and any typed character also
  reveals the field. After 3 failed scans the field appears automatically.

Net behaviour: lock → "Touch the fingerprint sensor" → touch → unlock, with
live messages. Password only after 3 failures or one click.

### Suspend/resume

Because `timeout=-1` keeps a verify running for the whole lock session, a
suspend during that verify hits a libfprint/fprintd bug:

```
18:24:22 fprintd: Device reported an error during verify: Cannot run while suspended.
18:24:22 kscreenlocker_greet: pam_fprintd(kde-fingerprint:auth):
         ReleaseDevice failed: Release failed with error: The device is still
         busy with another operation, please try again later.
```

After resume the device is left open inside fprintd; every further verify
fails with `The device has already been opened!`, so the fingerprint
authenticator stays unavailable and the lock screen shows only the password.
Opening System Settings / `fprintd-verify` fails the same way. The device is
released only when the greeter exits (i.e. after a password unlock).

`system-sleep/50-kde-fp-patch` (installed to
`/usr/lib/systemd/system-sleep/`) restarts `fprintd` on resume, which closes
the stale device; `LockScreenUi.qml`'s retry timer then re-arms the reader.
Manual recovery without logging out: `sudo systemctl restart fprintd`.

---

## 5. Install & test

```bash
cd KDE-FP-Patch
sudo ./install.sh              # both parts
# or: sudo ./install.sh --pam-only
```

The installer needs root. It was validated on the test machine by installing
it and probing the running greeter (see below); `./check.sh` compares the
installed files with the repository at any time.

If you only want the single most important change (finger accepted → unlock
immediately, no Enter), do it by hand and skip the theme patch:

```bash
sudo install -m 644 /usr/lib/pam.d/kde-fingerprint /etc/pam.d/kde-fingerprint
sudo sed -i '/pam_kwallet5/d' /etc/pam.d/kde-fingerprint
```

(That still leaves the "no prompt / times out / must move mouse first"
problems; `install.sh` handles those.)

Then:

1. `Meta+L`, **do not touch the mouse/keyboard**, touch the sensor.
2. If it does not unlock, watch the log:

   ```bash
   journalctl -f | grep -E 'kscreenlocker|pam_|fprint'
   ```

   Expected on lock: `PamAuthenticators: starting authenticators` immediately,
   then `[PAM worker kde-fingerprint] Message: Info message: Place your ...
   finger on the fingerprint reader`, and **no** `pam_kwallet5(kde-fingerprint`
   line.
3. `sudo ./restore.sh` rolls everything back from the timestamped backup.
   If no backup exists it asks before reinstalling `plasma-desktop-data`
   (`--reinstall` forces that path; the default answer is to exit).

I validated the patched theme by loading it in a user-local copy of the shell
package with `kscreenlocker_greet --testing` (offscreen): it loads with no QML
errors, `starting authenticators` fires at lock time with no input, and the
"Place your right index finger…" info message reaches the QML. I could not
physically place a finger or judge the on-screen layout from here, so the
first real lock/unlock is the remaining test.

---

## 6. Caveats / trade-offs

* **KWallet cannot be unlocked by a fingerprint** (there is no password to
  derive the key). It stays locked after a fingerprint unlock; that is also
  true of the stock setup. The password path still unlocks it.
* **SDDM login screen is not covered.** It uses the `sddm` PAM service →
  `common-auth` → `pam_fprintd max-tries=1 timeout=10`, and SDDM has no
  non-interactive stack, so fingerprint there still needs Enter and can wait
  10 s. Fixing it means changing common-auth or SDDM itself; leaving it alone
  keeps `sudo` fingerprint working as Ubuntu configured it.
* **`timeout=-1` keeps the sensor armed while locked.** On a laptop this costs
  some battery and blocks other apps (System Settings) from claiming the reader
  until you unlock. If that matters, change that one line to `timeout=120`
  (the QML re-arms after a timeout anyway).
* The three QML files are owned by `plasma-desktop-data`. A package upgrade
  will overwrite them; re-run `install.sh`. The `/etc/pam.d` overrides survive
  upgrades.
* If the QML ever fails to load, kscreenlocker falls back to its built-in
  fallback theme (verified by injecting a syntax error) — you are not locked
  out.
* Fingerprint remains one factor; the password is still accepted at any time
  after the first three failures / one click.

---

## 7. References

* KDE bug 469810 — non-password auth requires mouse first:
  <https://bugs.kde.org/show_bug.cgi?id=469810>
* KDE bug 469951 — fingerprint times out, Enter revives it (fixed 6.8.0):
  <https://bugs.kde.org/show_bug.cgi?id=469951>
* KDE bug 514444 — fingerprint unlock stuck until nudged:
  <https://bugs.kde.org/show_bug.cgi?id=514444>
* KDE bug 475024 — password blocked by fingerprint timeout (fixed 6.0):
  <https://bugs.kde.org/show_bug.cgi?id=475024>
* Launchpad 2172578 — same Ubuntu 26.04 / kscreenlocker 6.6.5 symptom:
  <https://bugs.launchpad.net/ubuntu/+source/kscreenlocker/+bug/2172578>
* kscreenlocker MR !351 (re-arm after timeout, open):
  <https://invent.kde.org/plasma/kscreenlocker/-/merge_requests/351>
* plasma-desktop MR !3891 (start auth at lock, closed):
  <https://invent.kde.org/plasma/plasma-desktop/-/merge_requests/3891>
* fprintd issue 147 / MR 195 (unlimited timeout fix):
  <https://gitlab.freedesktop.org/libfprint/fprintd/-/issues/147>
* Plasma 6.8 announcement:
  <https://kde.org/announcements/plasma/6/6.8.0/>

---

## Appendix — files

```
.
├── README.md             # install and usage
├── install.sh            # root installer (--pam-only supported)
├── restore.sh            # restore the newest backup
├── check.sh              # installed-vs-repo comparison
├── pam/
│   ├── kde               # password stack, no pam_fprintd
│   └── kde-fingerprint   # fingerprint stack, no pam_kwallet5, unlimited
├── qml/
│   ├── LockScreen.qml    # declares "locked", starts auth at lock
│   ├── LockScreenUi.qml  # status messages, failure counter, re-arm, idle hint
│   └── MainBlock.qml     # hides password until needed, prompt, "Use password"
├── system-sleep/
│   └── 50-kde-fp-patch   # restart fprintd on resume
└── docs/
    └── research.md       # this document
```