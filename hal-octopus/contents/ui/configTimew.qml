import QtQuick
import QtQuick.Controls as QtControls
import QtQuick.Layouts as QtLayouts
import org.kde.kcmutils as KCM
import org.kde.plasma.plasma5support as Plasma5Support

KCM.SimpleKCM {
    id: timewPage

    readonly property string helper: "/home/rigel/rehoboam/rehoboam_config.py"
    property var boardTasks: ({})

    property string cfg_stateFile: ""
    property string cfg_stateFileDefault: ""
    property int cfg_pollInterval: 1
    property int cfg_pollIntervalDefault: 1
    property int cfg_hoverDelay: 2000
    property int cfg_hoverDelayDefault: 2000

    function encArg(s) {
        return encodeURIComponent(s).replace(/[!'()*~]/g, c => "%" + c.charCodeAt(0).toString(16).toUpperCase());
    }

    function tasksFor(group) {
        return timewPage.boardTasks[group] ? timewPage.boardTasks[group] : [];
    }

    Plasma5Support.DataSource {
        id: execer
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            execer.disconnectSource(source);
            const stderr = data.stderr ? data.stderr.trim() : "";
            const stdout = data.stdout ? data.stdout.trim() : "";
            if (stderr) {
                actionStatus.text = stderr;
                actionStatus.color = "#c0392b";
                return;
            }
            actionStatus.color = "#2a8050";
            if (source.endsWith(" list")) {
                try {
                    const board = JSON.parse(stdout);
                    timewPage.boardTasks = board.tasks ? board.tasks : {};
                    groupBox.model = board.groups ? board.groups : [];
                    groupBox.currentIndex = -1;
                    taskBox.model = [];
                    return;
                } catch (err) {
                    actionStatus.text = i18n("Failed to load board");
                    actionStatus.color = "#c0392b";
                    return;
                }
            }
            if (source.indexOf("get-timew") !== -1) {
                if (source.endsWith("maxtracking")) {
                    const v = parseInt(stdout, 10);
                    maxtracking.value = isNaN(v) ? 0 : v;
                } else if (source.endsWith("verbose")) {
                    verbose.currentIndex = stdout === "off" ? 1 : 0;
                } else if (source.endsWith("confirmation")) {
                    confirmation.currentIndex = stdout === "off" ? 1 : 0;
                }
                return;
            }
            if (source === "timew") {
                trackingStatus.text = stdout || i18n("No tracking.");
                return;
            }
            if (source.indexOf("timew config") !== -1) {
                actionStatus.text = i18n("Saved");
                return;
            }
            if (source.indexOf("timew-start") !== -1) {
                actionStatus.text = i18n("Started tracking");
                runStatus();
                return;
            }
            if (source.indexOf("timew stop") !== -1) {
                actionStatus.text = stdout || i18n("Stopped");
                runStatus();
                return;
            }
            if (source.indexOf("timew continue") !== -1) {
                actionStatus.text = i18n("Continued");
                runStatus();
                return;
            }
        }
    }

    function run(cmd) {
        execer.connectSource(cmd);
    }

    function runStatus() {
        run("timew");
    }

    function loadValues() {
        run("python3 " + helper + " list");
        run("python3 " + helper + " get-timew maxtracking");
        run("python3 " + helper + " get-timew verbose");
        run("python3 " + helper + " get-timew confirmation");
        runStatus();
    }

    QtLayouts.ColumnLayout {
        spacing: 10
        QtLayouts.Layout.fillWidth: true

        QtControls.Label {
            text: i18n("Tracking actions")
            font.bold: true
        }

        QtControls.Label {
            id: trackingStatus
            text: i18n("…")
            font.family: "monospace"
        }

        QtLayouts.RowLayout {
            spacing: 6
            QtControls.ComboBox {
                id: groupBox
                QtLayouts.Layout.fillWidth: true
                onActivated: {
                    taskBox.model = timewPage.tasksFor(currentText);
                    taskBox.currentIndex = -1;
                }
            }
            QtControls.ComboBox {
                id: taskBox
                QtLayouts.Layout.fillWidth: true
            }
            QtControls.Button {
                text: i18n("Start")
                enabled: groupBox.currentText !== "" && taskBox.currentText !== ""
                onClicked: {
                    run("python3 " + timewPage.helper + " timew-start " + encArg(groupBox.currentText) + " " + encArg(taskBox.currentText));
                }
            }
        }

        QtLayouts.RowLayout {
            spacing: 6
            QtControls.Button {
                text: i18n("Stop")
                onClicked: run("timew stop")
            }
            QtControls.Button {
                text: i18n("Continue")
                onClicked: run("timew continue")
            }
            QtControls.Button {
                text: i18n("Refresh")
                onClicked: loadValues()
            }
        }

        QtControls.Label {
            text: i18n("Auto-stop idle tracking (minutes, 0 = off)")
            font.bold: true
        }
        QtControls.Label {
            text: i18n("maxtracking: timew stops the running interval after this many idle minutes.")
            wrapMode: Text.Wrap
            opacity: 0.7
        }
        QtControls.SpinBox {
            id: maxtracking
            from: 0
            to: 1440
            stepSize: 15
            editable: true
            QtLayouts.Layout.fillWidth: true
            onValueModified: run("timew config maxtracking " + value)
        }

        QtControls.Label {
            text: i18n("Verbose output")
            font.bold: true
        }
        QtControls.ComboBox {
            id: verbose
            model: ["on", "off"]
            onActivated: run("timew config verbose " + currentText)
        }

        QtControls.Label {
            text: i18n("Confirmation prompts")
            font.bold: true
        }
        QtControls.ComboBox {
            id: confirmation
            model: ["on", "off"]
            onActivated: run("timew config confirmation " + currentText)
        }

        QtControls.Label {
            id: actionStatus
            text: ""
            color: "#2a8050"
        }
    }

    Component.onCompleted: loadValues()
}
