#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 KDE-FP-Patch contributors
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Install the fingerprint lock-screen fix for Plasma 6.6 (Kubuntu/Ubuntu 26.04).
set -euo pipefail

VERSION="1.0.0"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QML_DIR="/usr/share/plasma/shells/org.kde.plasma.desktop/contents/lockscreen"
PAM_DIR="/etc/pam.d"
SLEEP_HOOK_DIR="/usr/lib/systemd/system-sleep"
BK_ROOT="/var/backups/kscreenlocker-fingerprint-ux"

usage() {
    cat <<EOT
KDE-FP-Patch ${VERSION} - fingerprint unlock for the Plasma 6.6 lock screen

Usage: sudo ./install.sh [--pam-only]

  (no option)   install the PAM fix and the lock-screen theme
  --pam-only    install the PAM overrides and resume hook only
  -h, --help    show this help and exit

Files replaced: ${PAM_DIR}/{kde,kde-fingerprint}
                ${QML_DIR}/{LockScreen,LockScreenUi,MainBlock}.qml
                ${SLEEP_HOOK_DIR}/50-kde-fp-patch

Backup:   ${BK_ROOT}/<timestamp>/
Rollback: sudo ./restore.sh
EOT
}

MODE="all"
case "${1:-}" in
    "")
        ;;
    --pam-only)
        MODE="pam-only"
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
esac

if [[ ${EUID} -ne 0 ]]; then
    echo "Please run as root:  sudo $0 ${1:-}" >&2
    exit 1
fi

for f in pam/kde pam/kde-fingerprint; do
    [[ -f "${HERE}/${f}" ]] || { echo "ERROR: ${HERE}/${f} is missing" >&2; exit 1; }
done
if [[ "${MODE}" == "all" ]]; then
    for f in LockScreen.qml LockScreenUi.qml MainBlock.qml; do
        [[ -f "${HERE}/qml/${f}" ]] || { echo "ERROR: ${HERE}/qml/${f} is missing" >&2; exit 1; }
    done
    [[ -d "${QML_DIR}" ]] || { echo "ERROR: ${QML_DIR} not found. Is plasma-desktop-data installed?" >&2; exit 1; }
fi

BK="${BK_ROOT}/$(date +%Y%m%d-%H%M%S)"
mkdir -p "${BK}"

backup() {
    local f="$1"
    if [[ -e "${f}" ]]; then
        mkdir -p "${BK}$(dirname "${f}")"
        cp -a "${f}" "${BK}${f}"
        echo "backed up ${f}"
    fi
}

backup "${PAM_DIR}/kde"
backup "${PAM_DIR}/kde-fingerprint"

install -m 0644 "${HERE}/pam/kde" "${PAM_DIR}/kde"
install -m 0644 "${HERE}/pam/kde-fingerprint" "${PAM_DIR}/kde-fingerprint"
echo "installed ${PAM_DIR}/kde and ${PAM_DIR}/kde-fingerprint"

if [[ -d "${SLEEP_HOOK_DIR}" ]]; then
    backup "${SLEEP_HOOK_DIR}/50-kde-fp-patch"
    install -m 0755 "${HERE}/system-sleep/50-kde-fp-patch" "${SLEEP_HOOK_DIR}/50-kde-fp-patch"
    echo "installed ${SLEEP_HOOK_DIR}/50-kde-fp-patch"
else
    echo "WARNING: ${SLEEP_HOOK_DIR} not found; suspend recovery hook not installed" >&2
fi

if [[ "${MODE}" == "all" ]]; then
    for f in LockScreen.qml LockScreenUi.qml MainBlock.qml; do
        backup "${QML_DIR}/${f}"
        install -m 0644 "${HERE}/qml/${f}" "${QML_DIR}/${f}"
        echo "installed ${QML_DIR}/${f}"
    done
fi

cat <<EOT

KDE-FP-Patch ${VERSION} installed. Backup: ${BK}

Test it:
  1. Lock the screen (Meta+L); do not touch the mouse or keyboard.
  2. Touch the fingerprint sensor. It should unlock directly.
  3. If it does not, check:
       journalctl -f | grep -E 'kscreenlocker|pam_|fprint'
     Expected right after locking: "PamAuthenticators: starting authenticators"
     and "Place your ... finger on the fingerprint reader", with no
     "pam_kwallet5(kde-fingerprint" line.

Check installed files:  ./check.sh
Rollback:               sudo ./restore.sh

Note: plasma-desktop-data upgrades overwrite the three QML files; re-run this
script afterwards. The /etc/pam.d overrides survive upgrades.
EOT
