import QtQuick
import QtQuick.Controls as QtControls
import QtQuick.Layouts as QtLayouts
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: generalPage

    property alias cfg_stateFile: stateFile.text
    property alias cfg_pollInterval: pollInterval.value
    property alias cfg_hoverDelay: hoverDelay.value

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
            placeholderText: "/home/rigel/.cache/rehoboam_widget.json"
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
    }
}
