/*
    SPDX-FileCopyrightText: 2016 David Edmundson <davidedmundson@kde.org>

    SPDX-License-Identifier: LGPL-2.0-or-later
    SPDX-FileCopyrightText: 2026 KDE-FP-Patch contributors
    (modified: password fallback, fingerprint prompt and smartcard hint)
*/

import QtQuick

import QtQuick.Layouts
import QtQuick.Controls as QQC2

import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami
import org.kde.kscreenlocker as ScreenLocker

import org.kde.breeze.components

SessionManagementScreen {
    id: sessionManager

    readonly property alias mainPasswordBox: passwordBox
    property bool lockScreenUiVisible: false
    property alias showPassword: passwordBox.showPassword

    // --- fingerprint UX state, driven by LockScreenUi.qml ---
    property bool fingerprintAvailable: false
    // Set once the reader has been seen during this lock, so the prompt keeps
    // showing even after the PAM worker temporarily goes away.
    property bool fingerprintSeen: false
    property string fingerprintStatus: ""
    property string fingerprintError: ""
    property bool passwordVisible: true

    signal passwordChosen()

    onPasswordVisibleChanged: {
        if (passwordVisible) {
            passwordBox.forceActiveFocus();
        }
    }

    //the y position that should be ensured visible when the on screen keyboard is visible
    property int visibleBoundary: mapFromItem(loginButton, 0, 0).y
    onHeightChanged: visibleBoundary = mapFromItem(loginButton, 0, 0).y + loginButton.height + Kirigami.Units.smallSpacing
    /*
     * Login has been requested with the following username and password
     * If username field is visible, it will be taken from that, otherwise from the "name" property of the currentIndex
     */
    signal passwordResult(string password)

    onUserSelected: {
        const nextControl = (passwordBox.visible ? passwordBox : loginButton);
        // Don't startLogin() here, because the signal is connected to the
        // Escape key as well, for which it wouldn't make sense to trigger
        // login. Using TabFocusReason, so that the loginButton gets the
        // visual highlight.
        nextControl.forceActiveFocus(Qt.TabFocusReason);
    }

    function startLogin() {
        const password = passwordBox.text

        // This is partly because it looks nicer, but more importantly it
        // works round a Qt bug that can trigger if the app is closed with a
        // TextField focused.
        //
        // See https://bugreports.qt.io/browse/QTBUG-55460
        loginButton.forceActiveFocus();
        passwordResult(password);
    }

    RowLayout {
        id: passwordLayout
        Layout.fillWidth: true
        visible: sessionManager.passwordVisible
        enabled: sessionManager.passwordVisible

        PlasmaExtras.PasswordField {
            id: passwordBox
            font.pointSize: Kirigami.Theme.defaultFont.pointSize + 1
            Layout.fillWidth: true
            text: PasswordSync.password

            placeholderText: i18ndc("plasma_shell_org.kde.plasma.desktop", "@info:placeholder in text field", "Password")
            focus: true
            enabled: !authenticator.graceLocked

            // In Qt this is implicitly active based on focus rather than visibility
            // in any other application having a focussed invisible object would be weird
            // but here we are using to wake out of screensaver mode
            // We need to explicitly disable cursor flashing to avoid unnecessary renders
            cursorVisible: visible

            onAccepted: {
                if (sessionManager.lockScreenUiVisible) {
                    sessionManager.startLogin();
                }
            }

            //if empty and left or right is pressed change selection in user switch
            //this cannot be in keys.onLeftPressed as then it doesn't reach the password box
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Left && !text) {
                    sessionManager.userList.decrementCurrentIndex();
                    event.accepted = true
                }
                if (event.key === Qt.Key_Right && !text) {
                    sessionManager.userList.incrementCurrentIndex();
                    event.accepted = true
                }
            }

            Connections {
                target: root
                function onClearPassword() {
                    passwordBox.forceActiveFocus()
                    passwordBox.text = "";
                    passwordBox.text = Qt.binding(() => PasswordSync.password);
                }
                function onNotificationRepeated() {
                    sessionManager.playHighlightAnimation();
                }
            }
        }
        Binding {
            target: PasswordSync
            property: "password"
            value: passwordBox.text
        }

        PlasmaComponents3.Button {
            id: loginButton
            Accessible.name: i18ndc("plasma_shell_org.kde.plasma.desktop", "@action:button accessible only", "Unlock")
            Layout.preferredHeight: passwordBox.implicitHeight
            Layout.preferredWidth: loginButton.Layout.preferredHeight

            icon.name: LayoutMirroring.enabled ? "go-previous" : "go-next"

            onClicked: sessionManager.startLogin()
            Keys.onEnterPressed: clicked()
            Keys.onReturnPressed: clicked()
        }
    }

    PlasmaComponents3.Button {
        Layout.alignment: Qt.AlignHCenter
        visible: sessionManager.fingerprintAvailable && !sessionManager.passwordVisible
        text: i18ndc("plasma_shell_org.kde.plasma.desktop", "@action:button", "Use password instead")
        onClicked: {
            sessionManager.passwordVisible = true;
            sessionManager.passwordChosen();
        }
    }

    component FailableLabel : PlasmaComponents3.Label {
        id: _failableLabel
        required property int kind
        required property string label
        property bool extraVisible: true

        visible: extraVisible && (authenticator.authenticatorTypes & kind)
        text: label
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignHCenter
        Layout.fillWidth: true

        RejectPasswordAnimation {
            id: _rejectAnimation
            target: _failableLabel
            onFinished: _timer.restart()
        }

        Connections {
            target: authenticator
            function onNoninteractiveError(kind, authenticator) {
                if (kind & _failableLabel.kind) {
                    _failableLabel.text = Qt.binding(() => authenticator.errorMessage)
                    _rejectAnimation.start()
                }
            }
        }
        Timer {
            id: _timer
            interval: Kirigami.Units.humanMoment
            onTriggered: {
                _failableLabel.text = Qt.binding(() => _failableLabel.label)
            }
        }
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing

        PlasmaComponents3.Label {
            id: fingerprintPromptLabel
            Layout.fillWidth: true
            visible: sessionManager.fingerprintSeen
            text: sessionManager.fingerprintError.length > 0
                  ? sessionManager.fingerprintError
                  : (sessionManager.fingerprintStatus.length > 0
                     ? sessionManager.fingerprintStatus
                     : i18ndc("plasma_shell_org.kde.plasma.desktop", "@info:usagetip", "Please scan your fingerprint on the reader"))
            textFormat: Text.PlainText
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap

            // Same shake the stock theme uses for a rejected password.
            RejectPasswordAnimation {
                id: _fingerprintReject
                target: fingerprintPromptLabel
            }

            Connections {
                target: authenticator
                function onNoninteractiveError(kind, authenticator) {
                    if (kind & ScreenLocker.Authenticator.Fingerprint) {
                        _fingerprintReject.start()
                    }
                }
            }
        }

        FailableLabel {
            kind: ScreenLocker.Authenticator.Smartcard
            label: i18ndc("plasma_shell_org.kde.plasma.desktop", "@info:usagetip", "(or scan your smartcard)")
        }
    }
}
