// Lab Security desktop widget for serpantinum.
// Durable source — installed into serpantinum's tree by
// ~/.local/bin/homelab-widget-install (re-run automatically after updates).
// Data: ~/.local/bin/homelab-status (JSON), polled every 5s; wifi rescan every 2 min.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../../reusables"
import "../../../"

Item {
    id: root
    anchors.fill: parent
    clip: true

    property bool previewMode: false
    property real minWidth: Scaler.s(280)
    property real minHeight: Scaler.s(180)
    property real maxWidth: Scaler.s(640)
    property real maxHeight: Scaler.s(520)
    property real minAspect: 0.8
    property real maxAspect: 3.0
    property bool isRound: false

    property var snap: null
    readonly property string level: snap ? snap.level : "…"
    readonly property color levelColor: level === "alert" ? ThemeBackend.red
                                      : level === "warn"  ? ThemeBackend.yellow
                                      : level === "ok"    ? ThemeBackend.green
                                      : ThemeBackend.subtext0
    readonly property real fs: Math.max(Scaler.s(10), Math.min(Scaler.s(14), root.height * 0.055, root.width * 0.034))
    readonly property string statusCmd: Quickshell.env("HOME") + "/.local/bin/homelab-status"

    function apply(txt) {
        try { root.snap = JSON.parse(txt); } catch (e) { }
    }

    Process {
        id: poll
        command: [root.statusCmd]
        stdout: StdioCollector { id: pollOut; onStreamFinished: root.apply(pollOut.text) }
    }
    Process {
        id: rescan
        command: [root.statusCmd, "--rescan"]
        stdout: StdioCollector { id: rescanOut; onStreamFinished: root.apply(rescanOut.text) }
    }
    Timer {
        interval: 5000; repeat: true; triggeredOnStart: true
        running: root.visible && !root.previewMode
        onTriggered: if (!poll.running && !rescan.running) poll.running = true
    }
    Timer {
        interval: 120000; repeat: true
        running: root.visible && !root.previewMode
        onTriggered: if (!rescan.running) rescan.running = true
    }

    // ---- small building blocks
    component Label: Text {
        font.family: ThemeBackend.fontFamily
        font.pixelSize: root.fs
        color: ThemeBackend.text
        elide: Text.ElideRight
        Layout.fillWidth: true
    }
    component Icon: Text {
        font.family: ThemeBackend.iconFont
        font.pixelSize: root.fs * 1.25
        color: ThemeBackend.subtext0
        Layout.preferredWidth: root.fs * 1.7
        horizontalAlignment: Text.AlignHCenter
    }
    component Dot: Rectangle {
        width: root.fs * 0.55; height: width; radius: width / 2
        Layout.alignment: Qt.AlignVCenter
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.alpha(ThemeBackend.surface0, ThemeBackend.elementOpacity)
        radius: ThemeBackend.borderRadius
        border.width: root.level === "alert" ? Scaler.s(2) : 0
        border.color: root.levelColor
        clip: true

        WallpaperBlur { z: -1; anchors.fill: parent; radius: parent.radius }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Scaler.s(14)
            spacing: root.fs * 0.55

            // header
            RowLayout {
                spacing: Scaler.s(8)
                Text {
                    font.family: ThemeBackend.iconFont
                    font.pixelSize: root.fs * 2
                    color: root.levelColor
                    text: root.level === "alert" ? String.fromCodePoint(0xF0565)   // shield-alert
                        : String.fromCodePoint(0xF0565)
                }
                ColumnLayout {
                    spacing: 0
                    Label { text: "Lab Security"; font.weight: Font.Black; font.pixelSize: root.fs * 1.2 }
                    Label {
                        color: root.levelColor; font.weight: Font.Bold
                        text: !root.snap ? "loading…"
                            : root.level === "alert" ? "ALERT"
                            : root.level === "warn" ? "Needs attention" : "All clear"
                    }
                }
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: Qt.alpha(ThemeBackend.overlay0, 0.4) }

            // wifi
            RowLayout {
                spacing: Scaler.s(6)
                Icon { text: String.fromCodePoint(0xF05A9) }   // wifi
                Label {
                    readonly property var w: root.snap ? root.snap.wifi : null
                    text: !w ? "—" : !w.connected ? "Not connected" : w.ssid + "  " + w.signal + "%"
                }
                Label {
                    Layout.fillWidth: false
                    color: ThemeBackend.subtext0
                    text: root.snap ? "ch" + root.snap.wifi.chan + " · " + root.snap.wifi.apCount + " APs" : ""
                }
            }
            Repeater {
                model: root.snap ? root.snap.wifi.suspects : []
                RowLayout {
                    required property var modelData
                    spacing: Scaler.s(6)
                    Icon { text: String.fromCodePoint(0xF0026); color: ThemeBackend.red }   // alert
                    Label {
                        color: ThemeBackend.red
                        text: "Twin? " + modelData.bssid + " ch" + modelData.chan + " — " + modelData.reason
                    }
                }
            }

            // VMs
            RowLayout {
                spacing: Scaler.s(6)
                Layout.alignment: Qt.AlignTop
                Icon { text: String.fromCodePoint(0xF0379); Layout.alignment: Qt.AlignTop }   // monitor
                ColumnLayout {
                    spacing: Scaler.s(2)
                    Layout.fillWidth: true
                    Label {
                        visible: !root.snap || root.snap.vms.length === 0
                        color: ThemeBackend.subtext0
                        text: "No lab VMs running"
                    }
                    Repeater {
                        model: root.snap ? root.snap.vms : []
                        RowLayout {
                            required property var modelData
                            spacing: Scaler.s(6)
                            Dot {
                                color: modelData.sshUp === true ? ThemeBackend.green
                                     : modelData.sshUp === false ? ThemeBackend.yellow
                                     : ThemeBackend.blue
                            }
                            Label {
                                text: modelData.name
                                    + (modelData.ssh ? "  ·  ssh :" + modelData.ssh + (modelData.sshUp ? "" : " (down)") : "")
                            }
                            Label {
                                Layout.fillWidth: false
                                color: ThemeBackend.subtext0
                                text: modelData.hv
                            }
                        }
                    }
                }
            }

            // ports / firewall
            RowLayout {
                spacing: Scaler.s(6)
                Icon { text: String.fromCodePoint(0xF0318) }   // lan
                Label {
                    readonly property var p: root.snap ? root.snap.ports : null
                    textFormat: Text.StyledText
                    text: !p ? "—"
                        : "Open " + p.exposed.map(e => e.known ? String(e.port)
                              : "<font color='" + ThemeBackend.yellow + "'>" + e.port + (e.proc ? "/" + e.proc : "") + "</font>").join(" ")
                          + "  <font color='" + ThemeBackend.subtext0 + "'>+" + p.localCount + " local</font>"
                }
                Label {
                    Layout.fillWidth: false
                    readonly property string fw: root.snap ? root.snap.firewall : ""
                    color: fw === "active" ? ThemeBackend.green : ThemeBackend.yellow
                    text: fw ? "ufw " + fw : ""
                }
            }

            // alerts
            RowLayout {
                spacing: Scaler.s(6)
                Icon { text: String.fromCodePoint(0xF009A) }   // bell
                Label {
                    readonly property var a: root.snap ? root.snap.alerts : []
                    color: a.length ? ThemeBackend.peach : ThemeBackend.subtext0
                    text: a.length ? a[0].msg + (a.length > 1 ? "  (+" + (a.length - 1) + ")" : "")
                                   : "No alerts (24h)"
                }
            }

            Item { Layout.fillHeight: true }
        }
    }
}
