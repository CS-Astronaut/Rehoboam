import QtQuick
import QtQuick.Controls as QtControls
import QtQuick.Layouts as QtLayouts
import org.kde.kcmutils as KCM
import org.kde.kirigami as Kirigami

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
    }
}
