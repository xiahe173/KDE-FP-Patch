/*
    SPDX-FileCopyrightText: 2014 Aleix Pol Gonzalez <aleixpol@blue-systems.com>

    SPDX-License-Identifier: GPL-2.0-or-later
    SPDX-FileCopyrightText: 2026 KDE-FP-Patch contributors
    (modified: auto-arm at lock, live fingerprint status, password fallback)
*/

import QtQuick

Item {
    id: root
    property bool debug: false
    property string notification

    // Magical property: kscreenlocker writes this when the lock becomes
    // effective (immediately for a manual lock, after the grace period for an
    // idle lock). Without it the write is silently dropped and fingerprint
    // authentication does not start until the user moves the mouse.
    property bool locked: false
    onLockedChanged: {
        if (locked) {
            authenticator.startAuthenticating();
        }
    }
    signal clearPassword()
    signal notificationRepeated()

    // These are magical properties that kscreenlocker looks for
    property bool viewVisible: false
    property bool suspendToRamSupported: false
    property bool suspendToDiskSupported: false

    // These are magical signals that kscreenlocker looks for
    signal suspendToDisk()
    signal suspendToRam()

    LayoutMirroring.enabled: Application.layoutDirection === Qt.RightToLeft
    LayoutMirroring.childrenInherit: true

    implicitWidth: 800
    implicitHeight: 600

    LockScreenUi {
        anchors.fill: parent
    }
}
