// Lab Security bar pill for serpantinum (replaces the "kb" module slot).
// Durable source — installed by ~/.local/bin/homelab-widget-install into
// bar/faces/security/. Click toggles the "security" popup (security/SecurityPopup.qml).
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../../reusables"
import "../../../"
import "../../"

BarFaceBase {
    id: root

    property var snap: null
    readonly property string level: snap ? snap.level : ""
    readonly property color levelColor: level === "alert" ? ThemeBackend.red
                                      : level === "warn"  ? ThemeBackend.yellow
                                      : ThemeBackend.text
    readonly property string label: level === "alert" ? "Alert"
                                  : level === "warn"  ? "Check"
                                  : level === "ok"    ? "Secure" : "…"
    readonly property string shieldIcon: "󰒃"

    property bool showFace: (!barWindow || isPreview) ? true : false
    readonly property var secPill: pillLoader.item
    readonly property bool wantsData: !root.isPreview && (!module || module.moduleActive)

    function togglePopup() {
        if (root.isPreview) return;
        Quickshell.execDetached(["bash", "-c", Caching.serpantinumDir + "/scripts/qs_manager.sh toggle security"]);
    }

    Process {
        id: poll
        command: [Quickshell.env("HOME") + "/.local/bin/homelab-status"]
        stdout: StdioCollector {
            id: pollOut
            onStreamFinished: { try { root.snap = JSON.parse(pollOut.text); } catch (e) {} }
        }
    }
    Timer {
        interval: 10000; repeat: true; triggeredOnStart: true
        running: root.wantsData
        onTriggered: if (!poll.running) poll.running = true
    }

    readonly property real pillLength: pillLoader.item ? (isVertical ? pillLoader.item.height : pillLoader.item.width) : 0
    property real targetLength: {
        if (module && !module.moduleActive) return 0;
        return (pillLength > 0) ? (pillLength + s(root.isCompact ? 8 : 10)) : 0;
    }
    property bool isFaceVisible: showFace && targetLength > 0

    function syncImplicitSize() {
        let cross = module ? module.thickness : (parent ? (isVertical ? parent.width : parent.height) : 0);
        implicitWidth = isVertical ? cross : targetLength;
        implicitHeight = isVertical ? targetLength : cross;
    }
    onTargetLengthChanged: syncImplicitSize()
    onIsVerticalChanged: syncImplicitSize()
    onModuleChanged: syncImplicitSize()
    onParentChanged: syncImplicitSize()
    Component.onCompleted: { if (barWindow) barWindow.fastPollerLoaded = true; }
    onBarWindowChanged: { if (barWindow) barWindow.fastPollerLoaded = true; }

    Timer { running: true; interval: 0; onTriggered: root.syncImplicitSize() }
    Timer {
        running: !root.isPreview && (!module || module.moduleActive) && barWindow && barWindow.isStartupReady && barWindow.isDataReady
        interval: 100
        onTriggered: root.showFace = true
    }

    transform: Translate {
        x: (root.isVertical || root.showFace) ? 0 : s(60)
        Behavior on x { NumberAnimation { duration: 800; easing.type: Easing.OutQuint } }
    }

    Loader {
        id: pillLoader
        anchors.centerIn: parent
        sourceComponent: root.isVertical ? sideButtonComponent : topButtonComponent
    }

    Component {
        id: topButtonComponent
        ClickButton {
            id: pill
            property bool initAnimTrigger: root.isPreview
            readonly property bool lockLook: root.activeTarget ? root.activeTarget.lockLook === true : false
            height: s(lockLook ? 36 : (root.isCompact ? 28 : 30))
            maxWidth: s(root.isCompact ? 110 : 120)
            cornerRadius: lockLook ? ThemeBackend.borderRadius : Math.max(0, ThemeBackend.borderRadius - s(2))
            horizontalPadding: s(root.isCompact ? 10 : 12)
            buttonIcon: root.shieldIcon
            iconFontSize: s(root.isCompact ? 14 : 15)
            buttonText: root.label
            textFontSize: s(root.isCompact ? 11 : 12)
            accentColor: root.level === "alert" ? Qt.alpha(ThemeBackend.red, 0.25)
                       : (lockLook ? Qt.lighter(ThemeBackend.surface0, 1.28) : (root.isCompact ? Qt.lighter(ThemeBackend.surface0, 1.18) : ThemeBackend.surface0))
            textColor: root.levelColor

            width: Math.max(s(root.isCompact ? 48 : 52), implicitWidth)
            Behavior on width {
                enabled: barWindow && barWindow.startupCascadeFinished
                NumberAnimation { duration: 480; easing.type: Easing.OutQuint }
            }

            Timer { running: !root.isPreview && (!module || module.moduleActive) && root.showFace && !pill.initAnimTrigger; interval: 70; onTriggered: pill.initAnimTrigger = true }
            opacity: initAnimTrigger ? 1.0 : 0.0
            transform: Translate { y: pill.initAnimTrigger ? 0 : s(15); Behavior on y { NumberAnimation { duration: 620; easing.type: Easing.OutQuint } } }
            Behavior on opacity { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }

            onClicked: root.togglePopup()
        }
    }

    Component {
        id: sideButtonComponent
        ClickButton {
            width: s(root.isCompact ? 28 : 30)
            height: s(root.isCompact ? 28 : 30)
            cornerRadius: Math.max(0, ThemeBackend.borderRadius - s(2))
            horizontalPadding: 0
            buttonIcon: root.shieldIcon
            iconFontSize: s(root.isCompact ? 14 : 15)
            accentColor: root.isCompact ? Qt.lighter(ThemeBackend.surface0, 1.18) : ThemeBackend.surface0
            textColor: root.levelColor
            onClicked: root.togglePopup()
        }
    }
}
