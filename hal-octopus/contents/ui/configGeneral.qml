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
    property alias cfg_postponeHours: postponeHours.value
    property alias cfg_lifeStep: lifeStep.value
    property string cfg_hiddenGroups: ""
    property alias cfg_maxtracking: maxtracking.value

    readonly property string helperPath: Qt.resolvedUrl("../../rehoboam_config.py")
        .toString().replace(/^file:\/\/(localhost)?/, "")
    property var groupEntries: []

    function parseHidden(str) {
        return (str || "").split(",").map(s => s.trim()).filter(s => s !== "");
    }

    function syncCheckboxes() {
        const values = parseHidden(cfg_hiddenGroups);
        const hidden = values.map(s => s.toLowerCase());
        const known = [];
        const entries = [];
        for (let i = 0; i < groupSource.groups.length; i++) {
            const g = groupSource.groups[i];
            known.push(g.toLowerCase());
            entries.push({ name: g, checked: hidden.indexOf(g.toLowerCase()) !== -1, stale: false });
        }
        for (let j = 0; j < hidden.length; j++) {
            if (known.indexOf(hidden[j]) === -1) {
                entries.push({ name: values[j], checked: true, stale: true });
            }
        }
        generalPage.groupEntries = entries;
    }

    function commitHidden() {
        const sel = [];
        for (let i = 0; i < groupEntries.length; i++) {
            if (groupEntries[i].checked) sel.push(groupEntries[i].name);
        }
        cfg_hiddenGroups = sel.join(", ");
    }

    Plasma5Support.DataSource {
        id: groupSource
        engine: "executable"
        connectedSources: []
        property var groups: []
        property bool failed: false
        onNewData: function(source, data) {
            disconnectSource(source);
            try {
                const board = JSON.parse(data.stdout);
                groups = board.groups ? board.groups : [];
                failed = false;
            } catch (err) {
                groups = [];
                failed = true;
            }
            generalPage.syncCheckboxes();
        }
    }

    Component.onCompleted: {
        groupSource.connectSource("python3 " + generalPage.helperPath + " list");
    }

    onCfg_hiddenGroupsChanged: generalPage.syncCheckboxes()

    function parseHex(s) {
        const m = /^#?([0-9a-fA-F]{6})$/.exec((s || "").trim());
        if (!m) return null;
        const v = parseInt(m[1], 16);
        return Qt.rgba(((v >> 16) & 255) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255, 1);
    }
    
    readonly property color accentPreview: accentField.text.trim() === ""
        ? Kirigami.Theme.highlightColor
        : (parseHex(accentField.text) || Qt.rgba(0, 0, 0, 0))

    Kirigami.FormLayout {
        QtLayouts.Layout.fillWidth: true

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Behavior")
        }

        QtControls.SpinBox {
            id: postponeHours
            Kirigami.FormData.label: i18n("Auto-postpone dead-man switch:")
            from: 0
            to: 720
            editable: true
            QtLayouts.Layout.fillWidth: true
        }
        QtControls.Label {
            Kirigami.FormData.label: ""
            text: i18n("Open tasks untouched for this long (hours) are flagged as postponed. 0 to disable.")
            wrapMode: Text.Wrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
        }

        QtControls.SpinBox {
            id: lifeStep
            Kirigami.FormData.label: i18n("Lifeline update interval:")
            from: 1
            to: 60
            editable: true
            QtLayouts.Layout.fillWidth: true
        }
        QtControls.Label {
            Kirigami.FormData.label: ""
            text: i18n("How often (minutes) the remaining-time line under each card ticks down.")
            wrapMode: Text.Wrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
        }

        QtLayouts.ColumnLayout {
            id: hiddenGroupsBox
            Kirigami.FormData.label: i18n("Hidden groups:")
            spacing: 0

            Component.onCompleted: generalPage.syncCheckboxes()

            Repeater {
                model: generalPage.groupEntries
                delegate: QtControls.CheckBox {
                    required property var modelData
                    required property int index
                    text: modelData.stale
                          ? i18n("%1 (not on the board anymore)", modelData.name)
                          : modelData.name
                    checked: modelData.checked
                    onToggled: {
                        generalPage.groupEntries[index].checked = checked;
                        generalPage.commitHidden();
                    }
                }
            }

            QtControls.Label {
                visible: groupSource.groups.length === 0 && groupSource.failed
                text: i18n("Could not load groups — is the exporter installed?")
                wrapMode: Text.Wrap
                opacity: 0.7
                font: Kirigami.Theme.smallFont
            }
        }
        QtControls.Label {
            Kirigami.FormData.label: ""
            text: i18n("Tick groups to hide their tasks from the widget eye (tracking still works). Untick to bring them back.")
            wrapMode: Text.Wrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
        }

        QtControls.SpinBox {
            id: maxtracking
            Kirigami.FormData.label: i18n("Auto-stop idle tracking:")
            from: 0
            to: 1440
            stepSize: 15
            editable: true
            QtLayouts.Layout.fillWidth: true
        }
        QtControls.Label {
            Kirigami.FormData.label: ""
            text: i18n("timew stops the running interval after this many idle minutes. 0 to disable.")
            wrapMode: Text.Wrap
            opacity: 0.7
            font: Kirigami.Theme.smallFont
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Widget Engine")
        }

        QtControls.TextField {
            id: stateFile
            Kirigami.FormData.label: i18n("State file:")
            placeholderText: i18n("Path to the widget state JSON file")
            QtLayouts.Layout.fillWidth: true
        }

        QtControls.SpinBox {
            id: pollInterval
            Kirigami.FormData.label: i18n("Polling interval (seconds):")
            from: 1
            to: 3600
            editable: true
            QtLayouts.Layout.fillWidth: true
        }

        QtControls.SpinBox {
            id: hoverDelay
            Kirigami.FormData.label: i18n("Popup hover delay (ms):")
            from: 250
            to: 10000
            stepSize: 250
            editable: true
            QtLayouts.Layout.fillWidth: true
        }

        QtLayouts.RowLayout {
            Kirigami.FormData.label: i18n("Accent color:")
            spacing: 8
            QtControls.TextField {
                id: accentField
                placeholderText: i18n("#RRGGBB (empty = system accent)")
                QtLayouts.Layout.fillWidth: true
            }
            Rectangle {
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
