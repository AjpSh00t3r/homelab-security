// Lab Security dropdown popup for serpantinum (opened from the bar pill:
// `qs_manager.sh toggle security`). Durable source — installed by
// ~/.local/bin/homelab-widget-install into quickshell/security/.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../"
import "../reusables"

Item {
    id: window
    visible: false
    focus: true

    function s(val) { return Scaler.s(val); }

    property var snap: null
    readonly property string level: snap ? snap.level : ""
    readonly property color levelColor: level === "alert" ? ThemeBackend.red
                                      : level === "warn"  ? ThemeBackend.yellow
                                      : level === "ok"    ? ThemeBackend.green
                                      : ThemeBackend.subtext0
    readonly property string statusCmd: Quickshell.env("HOME") + "/.local/bin/homelab-status"

    function apply(txt) { try { window.snap = JSON.parse(txt); } catch (e) {} }
    function ago(ts) {
        let d = Math.max(0, Math.round(Date.now() / 1000 - ts));
        if (d < 60) return d + "s ago";
        if (d < 3600) return Math.round(d / 60) + "m ago";
        return Math.round(d / 3600) + "h ago";
    }

    Process {
        id: poll
        command: [window.statusCmd]
        stdout: StdioCollector { id: pollOut; onStreamFinished: window.apply(pollOut.text) }
    }
    Process {
        id: rescan
        command: [window.statusCmd, "--rescan"]
        stdout: StdioCollector { id: rescanOut; onStreamFinished: window.apply(rescanOut.text) }
    }
    Timer {
        interval: 3000; repeat: true; triggeredOnStart: true
        running: window.visible
        onTriggered: if (!poll.running && !rescan.running) poll.running = true
    }

    // ---- lifecycle expected by the serpantinum popup host
    property var exitCallback: null
    property real introMain: 0
    property real introContent: 0

    function startExit(onFinished) {
        introAnim.stop();
        exitCallback = onFinished;
        exitAnim.restart();
    }
    function resetAndPlayIntro() {
        exitAnim.stop();
        introMain = 0; introContent = 0;
        introAnim.restart();
    }
    onVisibleChanged: {
        if (visible) { forceActiveFocus(); resetAndPlayIntro(); }
        else { introAnim.stop(); exitAnim.stop(); introMain = 0; introContent = 0; }
    }
    Component.onCompleted: if (visible) resetAndPlayIntro()

    ParallelAnimation {
        id: introAnim
        NumberAnimation { target: window; property: "introMain"; from: 0; to: 1; duration: 700; easing.type: Easing.OutExpo }
        SequentialAnimation {
            PauseAnimation { duration: 150 }
            NumberAnimation { target: window; property: "introContent"; from: 0; to: 1; duration: 700; easing.type: Easing.OutExpo }
        }
    }
    SequentialAnimation {
        id: exitAnim
        ParallelAnimation {
            NumberAnimation { target: window; property: "introContent"; to: 0; duration: 140; easing.type: Easing.InCubic }
            NumberAnimation { target: window; property: "introMain"; to: 0; duration: 180; easing.type: Easing.InQuart }
        }
        ScriptAction {
            script: {
                if (window.exitCallback) { let cb = window.exitCallback; window.exitCallback = null; cb(); }
            }
        }
    }

    // ---- building blocks
    component Txt: Text {
        font.family: ThemeBackend.fontFamily
        font.pixelSize: window.s(13)
        color: ThemeBackend.text
        elide: Text.ElideRight
    }
    component Ico: Text {
        font.family: ThemeBackend.iconFont
        font.pixelSize: window.s(16)
        color: ThemeBackend.subtext0
        Layout.preferredWidth: window.s(22)
        horizontalAlignment: Text.AlignHCenter
    }
    component Section: Rectangle {
        id: sec
        property string title: ""
        property string icon: ""
        property string badge: ""
        property color badgeColor: ThemeBackend.subtext0
        default property alias content: body.data
        Layout.fillWidth: true
        implicitHeight: col.implicitHeight + window.s(24)
        radius: Math.max(0, ThemeBackend.borderRadius - window.s(2))
        color: Qt.alpha(ThemeBackend.surface0, 0.55)
        ColumnLayout {
            id: col
            anchors.fill: parent
            anchors.margins: window.s(12)
            spacing: window.s(8)
            RowLayout {
                spacing: window.s(8)
                Ico { text: sec.icon; color: ThemeBackend.blue }
                Txt { text: sec.title; font.weight: Font.Black; Layout.fillWidth: true }
                Txt { text: sec.badge; color: sec.badgeColor; font.weight: Font.Bold }
            }
            ColumnLayout { id: body; spacing: window.s(5); Layout.fillWidth: true }
        }
    }
    component KV: RowLayout {
        property string k: ""
        property string v: ""
        property color vColor: ThemeBackend.text
        Layout.fillWidth: true
        Txt { text: parent.k; color: ThemeBackend.subtext0; elide: Text.ElideNone; Layout.minimumWidth: implicitWidth }
        Txt { text: parent.v; color: parent.vColor; Layout.fillWidth: true; horizontalAlignment: Text.AlignRight }
    }

    Item {
        anchors.fill: parent
        scale: 0.95 + 0.05 * window.introMain
        opacity: window.introMain
        transform: Translate { y: window.s(20) * (1 - window.introMain) }

        Rectangle {
            anchors.fill: parent
            radius: ThemeBackend.borderRadius
            color: Qt.alpha(ThemeBackend.base, ThemeBackend.elementOpacity)
            border.width: window.level === "alert" ? window.s(2) : 0
            border.color: window.levelColor
            clip: true

            WallpaperBlur { z: -1; anchors.fill: parent; radius: parent.radius }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: window.s(18)
                spacing: window.s(12)

                // header
                RowLayout {
                    spacing: window.s(14)
                    Rectangle {
                        Layout.preferredWidth: window.s(56); Layout.preferredHeight: window.s(56)
                        radius: ThemeBackend.borderRadius
                        color: Qt.alpha(window.levelColor, 0.18)
                        Text {
                            anchors.centerIn: parent
                            font.family: ThemeBackend.iconFont
                            font.pixelSize: window.s(30)
                            color: window.levelColor
                            text: window.level === "alert" ? "󰒙" : "󰒃"
                        }
                    }
                    ColumnLayout {
                        spacing: window.s(2)
                        Layout.fillWidth: true
                        Txt { text: "Lab Security"; font.pixelSize: window.s(20); font.weight: Font.Black }
                        Txt {
                            color: window.levelColor; font.weight: Font.Bold
                            text: !window.snap ? "loading…"
                                : window.level === "alert" ? "ALERT — check below"
                                : window.level === "warn" ? "Needs attention" : "All clear"
                        }
                    }
                    // Hold-to-confirm (serpantinum FillButton): hold the left
                    // button until the bar fills left→right, then it rescans.
                    FillButton {
                        Layout.preferredWidth: window.s(132)
                        Layout.preferredHeight: window.s(32)
                        maxWidth: window.s(132)
                        cornerRadius: Math.max(0, ThemeBackend.borderRadius - window.s(2))
                        horizontalPadding: window.s(12)
                        buttonIcon: rescan.running ? "󰑓" : "󰑐"
                        iconFontSize: window.s(14)
                        buttonText: rescan.running ? "Scanning" : "Rescan"
                        textFontSize: window.s(12)
                        accentColor: ThemeBackend.blue
                        baseColor: ThemeBackend.surface0
                        hoverColor: ThemeBackend.surface1
                        fillDuration: 1000
                        onTriggered: if (!rescan.running) rescan.running = true
                    }
                }

                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentHeight: sections.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    opacity: window.introContent
                    transform: Translate { y: window.s(20) * (1 - window.introContent) }

                    ColumnLayout {
                        id: sections
                        width: parent.width
                        spacing: window.s(10)

                        // ---------- Wi-Fi
                        Section {
                            readonly property var w: window.snap ? window.snap.wifi : null
                            title: "Wi-Fi"
                            icon: "󰖩"
                            badge: w ? w.apCount + " APs nearby" : ""
                            KV {
                                readonly property var w: window.snap ? window.snap.wifi : null
                                k: "Network"; v: w && w.connected ? w.ssid : "Not connected"
                            }
                            KV {
                                readonly property var w: window.snap ? window.snap.wifi : null
                                k: "Access point"; v: w && w.connected ? w.bssid + "  ch" + w.chan + "  " + w.signal + "%" : "—"
                            }
                            KV {
                                readonly property var w: window.snap ? window.snap.wifi : null
                                k: "Open networks"; v: w ? String(w.openCount) : "—"
                                vColor: w && w.openCount > 0 ? ThemeBackend.yellow : ThemeBackend.text
                            }
                            KV {
                                readonly property var d: window.snap ? window.snap.detector : null
                                k: "Rogue-AP detector"
                                v: !d ? "—"
                                    : !d.running ? "off"
                                    : d.mode === "monitor" ? "monitor · " + d.iface + (d.channel ? " · ch" + d.channel : "") + " · " + d.bssidsSeen + " APs"
                                    : "scan only (no ALFA)"
                                vColor: !d || !d.running ? ThemeBackend.yellow
                                      : d.mode === "monitor" ? ThemeBackend.green : ThemeBackend.text
                            }
                            Repeater {
                                model: window.snap ? window.snap.wifi.suspects : []
                                Rectangle {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    implicitHeight: sCol.implicitHeight + window.s(12)
                                    radius: window.s(6)
                                    color: Qt.alpha(ThemeBackend.red, 0.15)
                                    ColumnLayout {
                                        id: sCol
                                        anchors.fill: parent; anchors.margins: window.s(6)
                                        spacing: 0
                                        Txt { text: "󰀦  Possible evil twin: " + modelData.bssid; color: ThemeBackend.red; font.weight: Font.Bold; Layout.fillWidth: true }
                                        Txt { text: "ch" + modelData.chan + " · " + modelData.signal + "% · " + modelData.reason; color: ThemeBackend.subtext0; Layout.fillWidth: true }
                                    }
                                }
                            }
                        }

                        // ---------- VMs
                        Section {
                            title: "Lab VMs"
                            icon: "󰍹"
                            badge: window.snap ? window.snap.vms.length + " running" : ""
                            Txt {
                                visible: !window.snap || window.snap.vms.length === 0
                                text: "No lab VMs running"; color: ThemeBackend.subtext0
                            }
                            Repeater {
                                model: window.snap ? window.snap.vms : []
                                RowLayout {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    spacing: window.s(8)
                                    Rectangle {
                                        width: window.s(8); height: width; radius: width / 2
                                        color: modelData.sshUp === true ? ThemeBackend.green
                                             : modelData.sshUp === false ? ThemeBackend.yellow : ThemeBackend.blue
                                    }
                                    Txt { text: modelData.name; Layout.fillWidth: true }
                                    Txt { text: modelData.hv; color: ThemeBackend.subtext0 }
                                    ClickButton {
                                        visible: !!modelData.ssh
                                        height: window.s(26)
                                        cornerRadius: window.s(6)
                                        horizontalPadding: window.s(8)
                                        buttonIcon: "󰣀"
                                        iconFontSize: window.s(12)
                                        buttonText: ":" + modelData.ssh
                                        textFontSize: window.s(11)
                                        onClicked: Quickshell.execDetached(["kitty", "-e", "ssh", "-p", String(modelData.ssh), (modelData.sshUser ? modelData.sshUser + "@" : "") + "localhost"])
                                    }
                                }
                            }
                        }

                        // ---------- Ports
                        Section {
                            readonly property var p: window.snap ? window.snap.ports : null
                            title: "Listening ports"
                            icon: "󰛳"
                            badge: window.snap ? "ufw " + window.snap.firewall : ""
                            badgeColor: window.snap && window.snap.firewall === "active" ? ThemeBackend.green : ThemeBackend.yellow
                            Repeater {
                                model: window.snap ? window.snap.ports.exposed : []
                                KV {
                                    required property var modelData
                                    k: modelData.addr + ":" + modelData.port
                                    v: (modelData.proc || "") + (modelData.known ? "  known" : "  UNKNOWN")
                                    vColor: modelData.known ? ThemeBackend.subtext0 : ThemeBackend.yellow
                                }
                            }
                            KV {
                                k: "Localhost only"
                                v: window.snap ? window.snap.ports.localCount + " ports" : "—"
                                vColor: ThemeBackend.subtext0
                            }
                        }

                        // ---------- Alerts
                        Section {
                            title: "Alerts (24h)"
                            icon: "󰂚"
                            badge: window.snap ? String(window.snap.alerts.length) : ""
                            badgeColor: window.snap && window.snap.alerts.length ? ThemeBackend.peach : ThemeBackend.subtext0
                            Txt {
                                visible: !window.snap || window.snap.alerts.length === 0
                                text: "Nothing in the last 24 hours"; color: ThemeBackend.subtext0
                            }
                            Repeater {
                                model: window.snap ? window.snap.alerts : []
                                RowLayout {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    spacing: window.s(8)
                                    Txt {
                                        text: modelData.msg; Layout.fillWidth: true
                                        color: modelData.severity === "high" ? ThemeBackend.red : ThemeBackend.peach
                                    }
                                    Txt { text: window.ago(modelData.ts); color: ThemeBackend.subtext0 }
                                }
                            }
                        }
                    }
                }

                Txt {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignRight
                    font.pixelSize: window.s(11)
                    color: ThemeBackend.overlay1
                    text: window.snap ? "updated " + window.ago(window.snap.ts) + " · homelab-status"
                                        + (window.snap.demo ? " · demo mode (names masked)" : "") : ""
                }
            }
        }
    }
}
