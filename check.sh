#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 KDE-FP-Patch contributors
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Compare the installed patch with this repository. No root needed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QML_DIR="/usr/share/plasma/shells/org.kde.plasma.desktop/contents/lockscreen"
rc=0

check() {
    local src="$1" dst="$2"
    if [[ ! -e "${dst}" ]]; then
        echo "MISSING  ${dst}"
        rc=1
    elif ! cmp -s "${src}" "${dst}"; then
        echo "DIFFERS  ${dst}"
        rc=1
    else
        echo "ok       ${dst}"
    fi
}

echo "KDE-FP-Patch installation check"
check "${HERE}/pam/kde" /etc/pam.d/kde
check "${HERE}/pam/kde-fingerprint" /etc/pam.d/kde-fingerprint
for f in LockScreen.qml LockScreenUi.qml MainBlock.qml; do
    check "${HERE}/qml/${f}" "${QML_DIR}/${f}"
done
check "${HERE}/system-sleep/50-kde-fp-patch" /usr/lib/systemd/system-sleep/50-kde-fp-patch

if [[ ${rc} -eq 0 ]]; then
    echo "All installed files match this repository."
else
    echo "Run 'sudo ./install.sh' from this directory to install/update."
fi
exit "${rc}"
