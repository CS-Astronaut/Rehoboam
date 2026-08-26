import QtQuick
import QtQuick.Controls as QtControls
import QtQuick.Layouts as QtLayouts
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support

KCM.SimpleKCM {
    id: generalPage

    property alias cfg_stateFile: stateFile.text
    property alias cfg_pollInterval: pollInterval.value
    property alias cfg_hoverDelay: hoverDelay.value
    property alias cfg_accentColor: accentField.text

    property string cfg_stateFileDefault: ""
    property int cfg_pollIntervalDefault: 1
    property int cfg_hoverDelayDefault: 2000
    property string cfg_accentColorDefault: ""

    readonly property string helper: Qt.resolvedUrl("../../rehoboam_config.py").toString().replace(/^file:\/\/(localhost)?/, "")

    Timer {
        id: postponeSaveDebounce
        interval: 600
        onTriggered: generalPage.saveSetting("POSTPONE_HOURS", postponeHours.value)
    }
    Timer {
        id: lifeStepSaveDebounce
        interval: 600
        onTriggered: generalPage.saveSetting("LIFELINE_MINUTES", lifeStep.value)
    }

    Plasma5Support.DataSource {
        id: execer
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            execer.disconnectSource(source);
            const out = (data.stdout ? data.stdout : "").trim();
            if (source.indexOf(" get POSTPONE_HOURS") !== -1) {
                const v = parseFloat(out);
                postponeHours.value = (!isNaN(v) && v >= 0) ? Math.floor(v) : 24;
            } else if (source.indexOf(" get LIFELINE_MINUTES") !== -1) {
                const m = parseInt(out, 10);
                lifeStep.value = (!isNaN(m) && m >= 1) ? m : 5;
            } else if (data.stderr) {
                settingsStatus.text = data.stderr.trim();
                settingsStatus.color = "#c0392b";
            } else {
                settingsStatus.text = i18n("Saved");
                settingsStatus.color = "#2a8050";
            }
        }
    }

    function run(cmd) {
        execer.connectSource(cmd);
    }

    function saveSetting(key, value) {
        generalPage.run("python3 " + generalPage.helper + " set " + key + " " + value);
    }

    function loadValues() {
        generalPage.run("python3 " + helper + " get POSTPONE_HOURS");
        generalPage.run("python3 " + helper + " get LIFELINE_MINUTES");
    }

    Component.onCompleted: loadValues()

    function parseHex(s) {
        const m = /^#?([0-9a-fA-F]{6})$/.exec((s || "").trim());
        if (!m) {
            return null;
        }
        const v = parseInt(m[1], 16);
        return Qt.rgba(((v >> 16) & 255) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255, 1);
    }
    readonly property color accentPreview: accentField.text.trim() === ""
        ? Kirigami.Theme.highlightColor
        : (parseHex(accentField.text) || Qt.rgba(0, 0, 0, 0))

    QtLayouts.ColumnLayout {
        spacing: 10
        QtLayouts.Layout.fillWidth: true

        QtControls.Label {
            text: i18n("State file")
            font.bold: true
        }
        QtControls.Label {
            text: i18n("JSON snapshot written by rehoboam_exporter.py, polled by the widget.")
            wrapMode: Text.Wrap
            opacity: 0.7
        }
        QtControls.TextField {
            id: stateFile
            placeholderText: i18n("Path to the widget state JSON file")
            QtLayouts.Layout.fillWidth: true
        }

        QtControls.Label {
            text: i18n("Polling interval (seconds)")
            font.bold: true
        }
        QtControls.SpinBox {
            id: pollInterval
            from: 1
            to: 3600
            editable: true
            QtLayouts.Layout.fillWidth: true
        }

        QtControls.Label {
            text: i18n("Task popup hover delay (milliseconds)")
            font.bold: true
        }
        QtControls.SpinBox {
            id: hoverDelay
            from: 250
            to: 10000
            stepSize: 250
            editable: true
            QtLayouts.Layout.fillWidth: true
        }

        QtControls.Label {
            text: i18n("Accent color")
            font.bold: true
        }
        QtControls.Label {
            text: i18n("Empty = follow the system accent color.")
            wrapMode: Text.Wrap
            opacity: 0.7
        }
        QtLayouts.RowLayout {
            QtLayouts.Layout.fillWidth: true
            spacing: 8
            QtControls.TextField {
                id: accentField
                placeholderText: "#RRGGBB"
                QtLayouts.Layout.fillWidth: true
            }
            Rectangle {
                id: accentSwatch
                width: 22
                height: 22
                radius: 4
                color: generalPage.accentPreview
                border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.3)
                border.width: 1
            }
        }

        QtControls.Label {
            text: i18n("Auto-postpone dead-man switch (hours, 0 = off)")
            font.bold: true
        }
        QtControls.Label {
            text: i18n("Open tasks untouched for this long — no tracking, edit or move — are flagged as postponed. Tracking or editing a task restarts the countdown; unpostponing grants a fresh one.")
            wrapMode: Text.Wrap
            opacity: 0.7
        }
        QtControls.SpinBox {
            id: postponeHours
            from: 0
            to: 720
            editable: true
            QtLayouts.Layout.fillWidth: true
            onValueModified: postponeSaveDebounce.restart()
        }

        QtControls.Label {
            text: i18n("Lifeline update interval (minutes)")
            font.bold: true
        }
        QtControls.Label {
            text: i18n("How often the remaining-time line under each card ticks down.")
            wrapMode: Text.Wrap
            opacity: 0.7
        }
        QtControls.SpinBox {
            id: lifeStep
            from: 1
            to: 60
            editable: true
            QtLayouts.Layout.fillWidth: true
            onValueModified: lifeStepSaveDebounce.restart()
        }

        QtControls.Label {
            id: settingsStatus
            text: ""
            color: "#2a8050"
            opacity: 0.9
        }

        QtControls.Button {
            text: i18n("Reload current values")
            onClicked: loadValues()
        }
    }
}
