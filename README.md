# KDE-FP-Patch

Make fingerprint unlock on the KDE Plasma 6.6 lock screen behave like a phone:
lock, touch the sensor, unlock — with live prompts and no Enter key.

Tested on **Kubuntu 26.04** with **Plasma 6.6.5** (`libkscreenlocker6 6.6.5`),
**fprintd 1.94.5**, an Elan `04f3:0c7e` reader and a Wayland session.

## What it fixes

- A matched finger does not unlock until you press Enter: Debian/Ubuntu's
  `kde-fingerprint` PAM file runs `pam_kwallet5` after `pam_fprintd`, which opens
  a password prompt the greeter cannot answer
  ([Launchpad #2172578](https://bugs.launchpad.net/ubuntu/+source/kscreenlocker/+bug/2172578)).
- The reader is not armed until you move the mouse or press a key
  ([KDE bug 469810](https://bugs.kde.org/show_bug.cgi?id=469810)).
- “Place your finger”, failure and timeout messages are not shown, and the
  reader dies after the PAM timeout until an interactive failure revives it
  ([KDE bug 469951](https://bugs.kde.org/show_bug.cgi?id=469951)).
- Pressing Enter starts a 10 s fingerprint attempt (from `common-auth`) before
  the password is even checked.
- The password field is always visible, even when the reader is working.
- Suspending while locked leaves fprintd's device open (`ReleaseDevice
  failed: ... still busy`), so the rest of that lock session has no fingerprint.

## Install

```bash
git clone <repo-url> KDE-FP-Patch
cd KDE-FP-Patch
sudo ./install.sh              # PAM + lock-screen theme
sudo ./install.sh --pam-only   # PAM + resume hook, no theme files
```

A timestamped backup of every replaced file goes to
`/var/backups/kscreenlocker-fingerprint-ux/`. `sudo ./restore.sh` puts
everything back from the newest backup. If no backup exists it asks first and
exits without changing anything by default; `sudo ./restore.sh --reinstall`
forces a `plasma-desktop-data` reinstall instead.

## Behaviour after installing

- Locking starts PAM immediately — no mouse or keyboard needed.
- The lock screen shows `Please scan your fingerprint on the reader`; fprintd
  info and error messages replace it live.
- A rejected scan shows `Failed to match fingerprint` for 2.5 s and shakes the
  prompt. After three failures the password field appears with
  `Fingerprint not recognized. Try again or enter your password.`
- The password field stays hidden until three failed scans, a typed key, or
  the **Use password instead** button.
- The smartcard hint is shown on its own line below the fingerprint prompt.
- A matched finger unlocks immediately; no Enter.

## Files

| File | Purpose |
| --- | --- |
| `install.sh` | root installer (`--pam-only` supported) |
| `restore.sh` | restores the newest backup |
| `check.sh` | compares installed files with this repository |
| `system-sleep/50-kde-fp-patch` | restarts fprintd on resume to clear a device left open by suspend |
| `pam/kde` | lock-screen password stack, password-only (no `pam_fprintd`) |
| `pam/kde-fingerprint` | fingerprint stack: no `pam_kwallet5`, unlimited retries/timeout |
| `qml/LockScreen.qml` | starts authentication when the lock becomes effective |
| `qml/LockScreenUi.qml` | prompt, error handling, fallback, re-arm |
| `qml/MainBlock.qml` | hides the password field, shows prompt and smartcard hint |
| `docs/research.md` | full write-up: root causes, bug links, evidence |

## Notes and limitations

- **KWallet** cannot be unlocked with a fingerprint (no password to derive the
  key). A password unlock still unlocks it, as before.
- **SDDM's login screen is not covered.** It still uses Ubuntu's `common-auth`
  (`pam_fprintd max-tries=1 timeout=10`) and may need Enter.
- `pam/kde-fingerprint` uses `max-tries=-1 timeout=-1` so the sensor stays
  armed while locked. This costs a little battery and keeps the reader claimed
  while locked; change the line to `timeout=120` if you prefer a bound.
- **Suspend/resume:** while locked, the sensor is continuously verifying. If
  the machine suspends during a verify, fprintd 1.94.5 reports `Cannot run
  while suspended`, fails to release the device, and the reader stays open
  until the greeter exits — the lock screen then only offers the password.
  `install.sh` installs `/usr/lib/systemd/system-sleep/50-kde-fp-patch`, which
  restarts fprintd after resume; the lock screen re-arms automatically. To
  recover by hand: `sudo systemctl restart fprintd`.
- `plasma-desktop-data` upgrades overwrite the three QML files — re-run
  `install.sh`. The `/etc/pam.d` overrides survive upgrades.
- Plasma 6.8 fixes the timeout/re-arm bug (KDE #469951) upstream; this
  repository targets 6.6.x LTS (Kubuntu/Ubuntu 26.04), which will not get 6.8
  through normal updates.
- The lock screen is on the critical path. Keep a TTY (Ctrl+Alt+F3) or SSH
  available; if the theme fails to load, kscreenlocker falls back to its
  built-in theme.

## License

The scripts and PAM files are GPL-2.0-or-later. The QML files are derived
from `plasma-desktop`'s Breeze lock screen: `LockScreen.qml` and
`LockScreenUi.qml` are GPL-2.0-or-later, `MainBlock.qml` is
LGPL-2.0-or-later. Each file keeps its upstream SPDX header plus the
modification notice; see `docs/research.md` for the exact changes.