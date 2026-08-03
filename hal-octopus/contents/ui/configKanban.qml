import QtQuick
import QtQuick.Controls as QtControls
import QtQuick.Layouts as QtLayouts
import org.kde.kcmutils as KCM
import org.kde.plasma.plasma5support as Plasma5Support

KCM.SimpleKCM {
    id: kanbanPage

    readonly property string helper: "/home/rigel/rehoboam/rehoboam_config.py"

    property string cfg_stateFile: ""
    property string cfg_stateFileDefault: ""
    property int cfg_pollInterval: 1
    property int cfg_pollIntervalDefault: 1
    property int cfg_hoverDelay: 2000
    property int cfg_hoverDelayDefault: 2000

    function encArg(s) {
        return encodeURIComponent(s).replace(/[!'()*~]/g, c => "%" + c.charCodeAt(0).toString(16).toUpperCase());
    }

    Plasma5Support.DataSource {
        id: execer
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            execer.disconnectSource(source);
            const isGet = source.indexOf(" get ") !== -1;
            if (isGet) {
                const value = (data.stdout ? data.stdout : "").trim();
                if (source.indexOf("KANBAN_FILE") !== -1) {
                    if (value) kanbanFile.text = value;
                } else if (source.indexOf("DAILY_NOTES_DIR") !== -1) {
                    if (value) dailyNotesDir.text = value;
                }
            } else {
                statusLabel.text = data.stderr ? data.stderr.trim() : i18n("Applied");
            }
        }
    }

    function run(cmd) {
        execer.connectSource(cmd);
    }

    function loadValues() {
        run("python3 " + helper + " get KANBAN_FILE");
        run("python3 " + helper + " get DAILY_NOTES_DIR");
    }

    QtLayouts.ColumnLayout {
        spacing: 10
        QtLayouts.Layout.fillWidth: true

        QtControls.Label {
            text: i18n("Kanban board file")
            font.bold: true
        }
        QtControls.Label {
            text: i18n("Obsidian markdown board synced by the rehoboam suite. Takes effect on the next kanban.sh / rehoboam.sh run.")
            wrapMode: Text.Wrap
            opacity: 0.7
        }
        QtControls.TextField {
            id: kanbanFile
            placeholderText: "~/Obsidian Vault/Computer Science/KANBAN.md"
            QtLayouts.Layout.fillWidth: true
            onEditingFinished: run("python3 " + kanbanPage.helper + " set KANBAN_FILE " + encArg(text))
        }

        QtControls.Label {
            text: i18n("Daily notes directory")
            font.bold: true
        }
        QtControls.Label {
            text: i18n("Where completed tasks and tracked time are written each day.")
            wrapMode: Text.Wrap
            opacity: 0.7
        }
        QtControls.TextField {
            id: dailyNotesDir
            placeholderText: "~/Obsidian Vault/Computer Science/999 Daily Notes"
            QtLayouts.Layout.fillWidth: true
            onEditingFinished: run("python3 " + kanbanPage.helper + " set DAILY_NOTES_DIR " + encArg(text))
        }

        QtControls.Label {
            id: statusLabel
            text: ""
            color: "#2a8050"
            opacity: 0.9
        }

        QtControls.Button {
            text: i18n("Reload current values")
            onClicked: loadValues()
        }
    }

    Component.onCompleted: loadValues()
}
