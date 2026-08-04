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

    property var boardGroups: []
    property var hiddenSet: ({})
    property bool syncingGroups: false

    function encArg(s) {
        return encodeURIComponent(s).replace(/[!'()*~]/g, c => "%" + c.charCodeAt(0).toString(16).toUpperCase());
    }

    Plasma5Support.DataSource {
        id: execer
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            execer.disconnectSource(source);
            const out = (data.stdout ? data.stdout : "").trim();
            if (source.indexOf(" list") !== -1) {
                try {
                    const board = JSON.parse(out);
                    kanbanPage.boardGroups = board.groups ? board.groups : [];
                    groupBox.currentIndex = -1;
                    kanbanPage.syncGroupChecks();
                } catch (e) {
                    statusLabel.text = i18n("Failed to load groups: %1", out);
                }
            } else if (source.indexOf(" get HIDDEN_GROUPS") !== -1) {
                kanbanPage.hiddenSet = {};
                if (out) {
                    for (const g of out.split(",")) {
                        const name = g.trim();
                        if (name) kanbanPage.hiddenSet[name.toLowerCase()] = true;
                    }
                }
                kanbanPage.syncGroupChecks();
            } else if (source.indexOf(" get ") !== -1) {
                if (source.indexOf("KANBAN_FILE") !== -1) {
                    if (out) kanbanFile.text = out;
                } else if (source.indexOf("DAILY_NOTES_DIR") !== -1) {
                    if (out) dailyNotesDir.text = out;
                }
            } else if (source.indexOf("add-task") !== -1) {
                newTaskTitle.text = "";
                statusLabel.text = i18n("Task added");
            } else {
                statusLabel.text = data.stderr ? data.stderr.trim() : i18n("Applied");
            }
        }
    }

    function run(cmd) {
        execer.connectSource(cmd);
    }

    function syncGroupChecks() {
        syncingGroups = true;
        for (let i = 0; i < groupsRepeater.count; i++) {
            groupsRepeater.itemAt(i).checked =
                kanbanPage.hiddenSet[kanbanPage.boardGroups[i].trim().toLowerCase()] === true;
        }
        syncingGroups = false;
    }

    function saveHidden() {
        const names = [];
        for (let i = 0; i < groupsRepeater.count; i++) {
            if (groupsRepeater.itemAt(i).checked) names.push(kanbanPage.boardGroups[i]);
        }
        run("python3 " + kanbanPage.helper + " set HIDDEN_GROUPS " +
            (names.length ? encArg(names.join(",")) : "''"));
    }

    function loadValues() {
        run("python3 " + helper + " get KANBAN_FILE");
        run("python3 " + helper + " get DAILY_NOTES_DIR");
        run("python3 " + helper + " get HIDDEN_GROUPS");
        run("python3 " + helper + " list");
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
            text: i18n("Hidden from the octopus")
            font.bold: true
        }
        QtControls.Label {
            text: i18n("Ticked groups' tasks won't be displayed on the widget eye. Affects the octopus display only; tracking still works.")
            wrapMode: Text.Wrap
            opacity: 0.7
        }
        Repeater {
            id: groupsRepeater
            model: kanbanPage.boardGroups
            QtControls.CheckBox {
                required property string modelData
                text: modelData
                checked: false
                onToggled: if (!kanbanPage.syncingGroups) kanbanPage.saveHidden();
            }
        }

        QtControls.Label {
            text: i18n("Add task")
            font.bold: true
        }
        QtControls.Label {
            text: i18n("Add a new task to the board: pick its group and type a title. Appears on the widget eye within a couple of seconds.")
            wrapMode: Text.Wrap
            opacity: 0.7
        }
        QtLayouts.RowLayout {
            spacing: 6
            QtControls.ComboBox {
                id: groupBox
                model: kanbanPage.boardGroups
                QtLayouts.Layout.fillWidth: true
            }
            QtControls.TextField {
                id: newTaskTitle
                placeholderText: i18n("Task title")
                QtLayouts.Layout.fillWidth: true
            }
            QtControls.Button {
                text: i18n("Add")
                enabled: groupBox.currentText !== "" && newTaskTitle.text.trim() !== ""
                onClicked: {
                    run("python3 " + kanbanPage.helper + " add-task " +
                        encArg(groupBox.currentText) + " " + encArg(newTaskTitle.text.trim()));
                }
            }
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
