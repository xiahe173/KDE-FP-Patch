#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 KDE-FP-Patch contributors
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Undo install.sh: restore the newest timestamped backup.
set -euo pipefail

BK_ROOT="/var/backups/kscreenlocker-fingerprint-ux"
QML_REL="usr/share/plasma/shells/org.kde.plasma.desktop/contents/lockscreen"
FORCE_REINSTALL=no

usage() {
    cat <<EOT
Usage: sudo ./restore.sh [--reinstall]

Restores the newest backup from ${BK_ROOT}/ (PAM and, if backed up, QML).

If no backup exists, the script asks before reinstalling plasma-desktop-data.
  --reinstall   skip the question and reinstall the package (non-interactive)
  -h, --help    show this help
EOT
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    --reinstall)
        FORCE_REINSTALL=yes
        ;;
    "")
        ;;
    *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
esac

if [[ ${EUID} -ne 0 ]]; then
    echo "Please run as root:  sudo $0" >&2
    exit 1
fi

BK="$(ls -d "${BK_ROOT}"/*/ 2>/dev/null | sort | tail -n 1 || true)"

restore_or_remove() {
    local rel="$1"
    if [[ -n "${BK}" && -e "${BK}${rel}" ]]; then
        install -D -m 0644 "${BK}${rel}" "/${rel}"
        echo "restored /${rel}"
    else
        rm -f "/${rel}"
        echo "removed /${rel}"
    fi
}

if [[ -n "${BK}" ]]; then
    echo "Using backup ${BK}"
    restore_or_remove "etc/pam.d/kde"
    restore_or_remove "etc/pam.d/kde-fingerprint"
    for f in LockScreen.qml LockScreenUi.qml MainBlock.qml; do
        if [[ -e "${BK}${QML_REL}/${f}" ]]; then
            install -D -m 0644 "${BK}${QML_REL}/${f}" "/${QML_REL}/${f}"
            echo "restored /${QML_REL}/${f}"
        fi
    done
    echo "Done. Lock the screen once to confirm the stock behaviour is back."
    exit 0
fi

# No backup. Only offer the destructive fallback if something is installed.
found=no
for f in /etc/pam.d/kde /etc/pam.d/kde-fingerprint \
         "/${QML_REL}/LockScreen.qml" "/${QML_REL}/LockScreenUi.qml" "/${QML_REL}/MainBlock.qml"; do
    [[ -e "${f}" ]] && found=yes
done
if [[ "${found}" == "no" ]]; then
    echo "No backup in ${BK_ROOT}/ and nothing to restore."
    exit 0
fi

echo "No backup found in ${BK_ROOT}/."
echo "The installed PAM overrides cannot be restored, and the lock-screen QML"
echo "files can only be reset by reinstalling plasma-desktop-data."
echo

if [[ "${FORCE_REINSTALL}" == "yes" ]]; then
    answer=yes
elif [[ -t 0 ]]; then
    read -r -p "Reinstall plasma-desktop-data now? [y/N] " answer || answer=""
else
    echo "Not running on a terminal; nothing changed." >&2
    echo "Re-run with --reinstall to force the package reinstall." >&2
    exit 1
fi

case "${answer}" in
    y|Y|yes|YES)
        echo "Removing /etc/pam.d overrides and reinstalling plasma-desktop-data..."
        rm -f /etc/pam.d/kde /etc/pam.d/kde-fingerprint
        apt-get install --reinstall -y plasma-desktop-data
        echo "Done. Lock the screen once to confirm the stock behaviour is back."
        ;;
    *)
        echo "Aborted; nothing changed."
        exit 1
        ;;
esac
