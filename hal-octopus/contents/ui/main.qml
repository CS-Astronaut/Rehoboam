import QtQuick
import QtQuick.Controls as QtControls
import QtQuick.Layouts
import QtQuick.Shapes
import org.kde.kirigami as Kirigami
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as Plasma5Support

PlasmoidItem {
    id: root

    width: 620
    height: 420
    Layout.minimumWidth: 480
    Layout.minimumHeight: 320
    Layout.preferredWidth: 620
    Layout.preferredHeight: 420

    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground

    readonly property color cFg: Kirigami.Theme.textColor
    readonly property color cDim: Kirigami.Theme.disabledTextColor
    readonly property color cRed: Kirigami.Theme.negativeTextColor
    readonly property color cOrange: "#e0af68"
    readonly property color cGray: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.3)
    readonly property color cPanelTop: Kirigami.Theme.backgroundColor
    readonly property color cPanelBot: Qt.darker(Kirigami.Theme.backgroundColor, 1.15)
    readonly property bool isLightTheme: Kirigami.Theme.textColor.r + Kirigami.Theme.textColor.g + Kirigami.Theme.textColor.b < 1.2
    readonly property color cAccent: {
        const m = /^#?([0-9a-fA-F]{6})$/.exec((plasmoid.configuration.accentColor || "").trim());
        return m
            ? Qt.rgba(parseInt(m[1].substring(0, 2), 16) / 255,
                      parseInt(m[1].substring(2, 4), 16) / 255,
                      parseInt(m[1].substring(4, 6), 16) / 255, 1)
            : Kirigami.Theme.highlightColor;
    }

    readonly property string helper: Qt.resolvedUrl("../../rehoboam_config.py").toString().replace(/^file:\/\/(localhost)?/, "")
    property string stateFile: plasmoid.configuration.stateFile
    property string stateCmd: "cat " + JSON.stringify(plasmoid.configuration.stateFile)

    function encArg(s) {
        return encodeURIComponent(s).replace(/[!'()*~]/g, c => "%" + c.charCodeAt(0).toString(16).toUpperCase());
    }
    property var taskModel: ListModel {}
    property int activeIndex: -1
    property bool tracking: false
    property bool online: false
    property string actionError: ""
    property var boardGroups: []
    property string popupMode: "add"
    property var popupTask: null
    property var pendingTrack: null
    property int optimisticActive: -1
    property double optimisticUntil: 0
    property int prevActiveIndex: -1
    property string pendingTrackAction: ""
    property int actionActive: 0
    property var prevRows: []
    property int pendingAddId: 0
    property int offlineStreak: 0
    property double pendingSince: 0
    property real postponeHours: 0

    property real eyeCx: width / 2
    property real eyeCy: height / 2
    property real eyeR: 36
    property real nodeW: 160
    property real nodeH: 92

    property real pupilAngle: 0
    property bool hasActive: activeIndex >= 0
    property string layoutKey: ""

    opacity: root.online ? 1.0 : 0.72
    Behavior on opacity {
        NumberAnimation { duration: 600 }
    }

    Plasma5Support.DataSource {
        id: stateSource
        engine: "executable"
        connectedSources: [root.stateCmd]
        interval: Math.max(1000, plasmoid.configuration.pollInterval * 1000)
        onNewData: function(source, data) {
            if (root.actionActive > 0) {
                return;
            }
            if (data.stdout) {
                try {
                    const st = JSON.parse(data.stdout);
                    applyState(st);
                    root.offlineStreak = 0;
                    online = true;
                    if (st.error) {
                        root.actionError = st.error;
                        errorTimer.restart();
                    }
                } catch (err) {
                    root.offlineStreak++;
                    if (root.offlineStreak >= 2) {
                        online = false;
                    }
                }
            } else {
                root.offlineStreak++;
                if (root.offlineStreak >= 2) {
                    online = false;
                }
            }
        }
    }

    Plasma5Support.DataSource {
        id: actionSource
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            actionSource.disconnectSource(source);
            const out = (data.stdout ? data.stdout : "").trim();
            if (source.indexOf(" list") !== -1) {
                try {
                    const board = JSON.parse(out);
                    root.boardGroups = board.groups ? board.groups : [];
                    groupCombo.model = root.boardGroups;
                    groupCombo.currentIndex = -1;
                    if (root.popupMode === "edit" && root.popupTask) {
                        groupCombo.editText = root.popupTask.group;
                    } else {
                        groupCombo.editText = "";
                    }
                } catch (e) {
                    root.actionError = "Failed to load groups: " + out;
                    errorTimer.restart();
                }
                return;
            }
            if (source.indexOf("cat ") === 0) {
                try {
                    applyState(JSON.parse(out));
                } catch (e) {
                    console.warn("rehoboam reconcile failed:", e);
                }
                return;
            }
            if (data.stderr) {
                root.actionError = data.stderr.trim();
                errorTimer.restart();
                console.warn("rehoboam action failed:", data.stderr.trim());
                if (root.pendingTrackAction !== "") {
                    root.pendingTrackAction = "";
                    root.optimisticActive = -1;
                    root.optimisticUntil = 0;
                    root.activeIndex = root.prevActiveIndex;
                    if (root.prevActiveIndex >= 0) {
                        aimPupil(taskModel.get(root.prevActiveIndex).angle);
                    } else {
                        pupilAnim.stop();
                    }
                }
                if (root.actionActive > 0) {
                    root.actionActive = 0;
                    root.pendingAddId = 0;
                    root.pendingSince = 0;
                    root.restoreModel(root.prevRows);
                    root.prevRows = [];
                    root.reconcileNow();
                }
            } else {
                root.actionError = "";
                if (root.pendingTrackAction !== "") {
                    root.pendingTrackAction = "";
                }
                if (root.actionActive > 0) {
                    root.actionActive--;
                    if (source.indexOf("add-task") !== -1 && root.pendingAddId !== 0) {
                        const firstLine = out.split("\n")[0].trim();
                        const parsed = parseInt(firstLine, 10);
                        if (!isNaN(parsed) && parsed > 0) {
                            root.patchRowId(root.pendingAddId, parsed);
                            root.pendingAddId = 0;
                        }
                    }
                    if (root.actionActive === 0) {
                        root.prevRows = [];
                    }
                } else {
                    root.reconcileNow();
                }
            }
        }
    }

    function runAction(cmd) {
        actionSource.connectSource(cmd);
    }

    function reconcileNow() {
        actionSource.connectSource(root.stateCmd);
    }

    function rowSnapshot(i) {
        const r = taskModel.get(i);
        return {
            id: r.id,
            description: r.description,
            group: r.group,
            category: r.category,
            runTime: r.runTime,
            runSeconds: r.runSeconds,
            isActive: r.isActive,
            lifeRatio: r.lifeRatio,
            lifeTime: r.lifeTime,
            angle: r.angle,
            nodeX: r.nodeX,
            nodeY: r.nodeY,
            pathLen: r.pathLen,
            sx: r.sx, sy: r.sy, tx: r.tx, ty: r.ty,
            c1x: r.c1x, c1y: r.c1y, c2x: r.c2x, c2y: r.c2y
        };
    }

    function captureModel() {
        const copy = [];
        for (let i = 0; i < taskModel.count; i++) {
            copy.push(root.rowSnapshot(i));
        }
        return copy;
    }

    function restoreModel(rows) {
        root.hidePopup();
        taskModel.clear();
        for (let i = 0; i < rows.length; i++) {
            taskModel.append(rows[i]);
        }
    }

    function nextProvisionalId() {
        return -(Date.now() % 2147483600);
    }

    function patchRowId(tempId, realId) {
        for (let i = 0; i < taskModel.count; i++) {
            if (taskModel.get(i).id === tempId) {
                taskModel.setProperty(i, "id", realId);
                return;
            }
        }
    }

    function runMutation(cmd, taskId) {
        root.hidePopup();
        root.pendingSince = Date.now();
        root.prevRows = root.captureModel();
        root.actionActive++;
        if (taskId !== null && taskId !== undefined) {
            for (let i = 0; i < taskModel.count; i++) {
                if (taskModel.get(i).id === taskId) {
                    taskModel.remove(i);
                    break;
                }
            }
        }
        runAction("python3 " + root.helper + " " + cmd);
    }

    function openAddTask() {
        root.hidePopup();
        root.popupMode = "add";
        root.popupTask = null;
        addTaskPopup.visible = true;
        addTaskPopup.opacity = 1;
        newTaskTitle.text = "";
        runAction("python3 " + root.helper + " list");
        newTaskTitle.forceActiveFocus();
    }

    function openEditTask() {
        root.hidePopup();
        root.popupMode = "edit";
        root.popupTask = contextMenu.target;
        addTaskPopup.visible = true;
        addTaskPopup.opacity = 1;
        newTaskTitle.text = contextMenu.target.description;
        runAction("python3 " + root.helper + " list");
        newTaskTitle.forceActiveFocus();
    }

    function closeAddTask() {
        addTaskPopup.visible = false;
        addTaskPopup.opacity = 0;
    }

    function submitAddTask() {
        const group = groupCombo.editText.trim();
        const title = newTaskTitle.text.trim();
        if (!group || !title) {
            return;
        }
        root.pendingSince = Date.now();
        if (root.popupMode === "edit" && root.popupTask) {
            const task = root.popupTask;
            const groupChanged = group !== task.group;
            const titleChanged = title !== task.description;
            if (groupChanged || titleChanged) {
                root.prevRows = root.captureModel();
                root.actionActive += (groupChanged ? 1 : 0) + (titleChanged ? 1 : 0);
                if (groupChanged) {
                    runAction("python3 " + root.helper + " task-move " +
                              task.id + " " + encArg(group));
                }
                if (titleChanged) {
                    runAction("python3 " + root.helper + " task-rename " +
                              task.id + " " + encArg(title));
                }
                for (let i = 0; i < taskModel.count; i++) {
                    if (taskModel.get(i).id === task.id) {
                        taskModel.setProperty(i, "description", title);
                        taskModel.setProperty(i, "group", group);
                        taskModel.setProperty(i, "category", "@" + group);
                        break;
                    }
                }
            }
        } else {
            root.prevRows = root.captureModel();
            root.actionActive++;
            const t = {
                id: root.nextProvisionalId(),
                description: title,
                group: group,
                category: "@" + group,
                run_time: "0 min",
                run_seconds: 0,
                is_active: false,
                life_ratio: 1,
                life_time: ""
            };
            taskModel.append(root.makeTaskRow(t, taskModel.count, taskModel.count + 1));
            root.pendingAddId = taskModel.get(taskModel.count - 1).id;
            runAction("python3 " + root.helper + " add-task " +
                      encArg(group) + " " + encArg(title));
        }
        root.closeAddTask();
    }

    function toggleTracking(entry, index) {
        root.hidePopup();
        if (entry.isActive) {
            root.pendingTrack = { action: "stop" };
            confirmTrackTitle.text = i18n("Stop tracking");
            confirmTrackSub.visible = false;
            confirmTrackButton.text = i18n("Stop");
            confirmPopup.visible = true;
            confirmPopup.opacity = 1;
            confirmPopup.forceActiveFocus();
            return;
        }
        const isSwitch = root.hasActive || root.tracking;
        root.pendingTrack = {
            action: isSwitch ? "switch" : "start",
            group: entry.group,
            description: entry.description,
            index: index
        };
        confirmTrackTitle.text = isSwitch ? i18n("Switch tracking") : i18n("Start tracking");
        confirmTrackSub.text = i18n("This will stop the previous timer!");
        confirmTrackSub.visible = isSwitch;
        confirmTrackButton.text = isSwitch ? i18n("Switch") : i18n("Start");
        confirmPopup.visible = true;
        confirmPopup.opacity = 1;
        confirmPopup.forceActiveFocus();
    }

    function confirmTrack() {
        const p = root.pendingTrack;
        if (!p) {
            return;
        }
        root.cancelTrack();
        root.pendingSince = Date.now();
        root.prevActiveIndex = root.activeIndex;
        root.optimisticUntil = Date.now() + 4000;
        if (p.action === "stop") {
            root.pendingTrackAction = "stop";
            root.optimisticActive = -1;
            pupilAnim.stop();
            root.activeIndex = -1;
            runAction("timew stop");
        } else if (p.action === "switch") {
            root.pendingTrackAction = "switch";
            root.optimisticActive = p.index;
            root.activeIndex = p.index;
            aimPupil(taskModel.get(p.index).angle);
            runAction("python3 " + root.helper + " timew-switch " +
                      encArg(p.group) + " " + encArg(p.description));
        } else {
            root.pendingTrackAction = "start";
            root.optimisticActive = p.index;
            root.activeIndex = p.index;
            aimPupil(taskModel.get(p.index).angle);
            runAction("python3 " + root.helper + " timew-start " +
                      encArg(p.group) + " " + encArg(p.description));
        }
    }

    function cancelTrack() {
        root.pendingTrack = null;
        confirmPopup.visible = false;
        confirmPopup.opacity = 0;
    }

    function categoryColor(cat) {
        let c = "#7aa2f7";
        switch (cat) {
        case "mic": c = "#bb9af7"; break;
        case "future": c = "#7dcfff"; break;
        case "todo": c = "#e0af68"; break;
        }
        return root.isLightTheme ? Qt.darker(c, 1.7) : c;
    }

    function radians(deg) {
        return deg * Math.PI / 180;
    }

    function drawRadialGlow(ctx, w, h, center, mid, midPos) {
        ctx.clearRect(0, 0, w, h);
        const cx = w / 2;
        const cy = h / 2;
        const r = Math.max(cx, cy);
        const g = ctx.createRadialGradient(cx, cy, 0, cx, cy, r);
        g.addColorStop(0, center);
        g.addColorStop(midPos, mid);
        g.addColorStop(1, "rgba(0,0,0,0)");
        ctx.fillStyle = g;
        ctx.fillRect(0, 0, w, h);
    }

    function cubicLen(x0, y0, c1x, c1y, c2x, c2y, x1, y1) {
        const steps = 24;
        let len = 0;
        let px = x0;
        let py = y0;
        for (let i = 1; i <= steps; i++) {
            const t = i / steps;
            const mt = 1 - t;
            const x = mt * mt * mt * x0 + 3 * mt * mt * t * c1x + 3 * mt * t * t * c2x + t * t * t * x1;
            const y = mt * mt * mt * y0 + 3 * mt * mt * t * c1y + 3 * mt * t * t * c2y + t * t * t * y1;
            len += Math.hypot(x - px, y - py);
            px = x;
            py = y;
        }
        return len;
    }

    function armGeometry(nodeX, nodeY) {
        const angle = Math.atan2(nodeY, nodeX);
        const len = Math.hypot(nodeX, nodeY);
        const px = -Math.sin(angle);
        const py = Math.cos(angle);
        const sx = Math.cos(angle) * (root.eyeR - 8);
        const sy = Math.sin(angle) * (root.eyeR - 8);
        const endRad = root.nodeH / 2 - 8;
        const tx = nodeX - Math.cos(angle) * endRad;
        const ty = nodeY - Math.sin(angle) * endRad;
        const bulge = len * 0.24;
        return {
            sx: sx, sy: sy, tx: tx, ty: ty,
            c1x: sx + (tx - sx) * 0.4 + px * bulge,
            c1y: sy + (ty - sy) * 0.4 + py * bulge,
            c2x: sx + (tx - sx) * 0.6 - px * bulge * 0.85,
            c2y: sy + (ty - sy) * 0.6 - py * bulge * 0.85
        };
    }

    function layoutGeometry(i, n) {
        const radius = Math.min(root.width / 2 - root.nodeW / 2, root.height / 2 - root.nodeH / 2) - 34;
        const ang = -90 + i * 360 / Math.max(n, 1);
        const rad = radians(ang);
        const nx = Math.cos(rad) * radius;
        const ny = Math.sin(rad) * radius;
        const g = armGeometry(nx, ny);
        return {
            angle: ang, nodeX: nx, nodeY: ny,
            pathLen: cubicLen(g.sx, g.sy, g.c1x, g.c1y, g.c2x, g.c2y, g.tx, g.ty),
            sx: g.sx, sy: g.sy, tx: g.tx, ty: g.ty,
            c1x: g.c1x, c1y: g.c1y, c2x: g.c2x, c2y: g.c2y
        };
    }

    function makeTaskRow(t, i, n) {
        const g = root.layoutGeometry(i, n);
        return {
            id: t.id,
            description: t.description,
            group: t.group,
            category: t.category !== undefined ? t.category : "@" + t.group,
            runTime: t.run_time !== undefined ? t.run_time : "0 min",
            runSeconds: t.run_seconds !== undefined ? t.run_seconds : 0,
            isActive: t.is_active === true,
            lifeRatio: t.life_ratio !== undefined ? t.life_ratio : -1,
            lifeTime: t.life_time !== undefined ? t.life_time : "",
            angle: g.angle, nodeX: g.nodeX, nodeY: g.nodeY, pathLen: g.pathLen,
            sx: g.sx, sy: g.sy, tx: g.tx, ty: g.ty,
            c1x: g.c1x, c1y: g.c1y, c2x: g.c2x, c2y: g.c2y
        };
    }

    function syncRow(i, row, t) {
        const active = t.is_active === true;
        if (row.description !== t.description || row.group !== t.group) {
            taskModel.setProperty(i, "description", t.description);
            taskModel.setProperty(i, "group", t.group);
            taskModel.setProperty(i, "category", t.category);
        }
        if (row.runSeconds !== t.run_seconds) {
            taskModel.setProperty(i, "runTime", t.run_time);
            taskModel.setProperty(i, "runSeconds", t.run_seconds);
        }
        if (row.isActive !== active) {
            taskModel.setProperty(i, "isActive", active);
        }
        const lifeR = t.life_ratio !== undefined ? t.life_ratio : -1;
        const lifeT = t.life_time !== undefined ? t.life_time : "";
        if (row.lifeRatio === undefined || Math.abs(row.lifeRatio - lifeR) > 0.0005
                || row.lifeTime !== lifeT) {
            taskModel.setProperty(i, "lifeRatio", lifeR);
            taskModel.setProperty(i, "lifeTime", lifeT);
        }
    }

    function relayout(n) {
        for (let i = 0; i < taskModel.count; i++) {
            const g = root.layoutGeometry(i, n);
            taskModel.setProperty(i, "angle", g.angle);
            taskModel.setProperty(i, "nodeX", g.nodeX);
            taskModel.setProperty(i, "nodeY", g.nodeY);
            taskModel.setProperty(i, "pathLen", g.pathLen);
            taskModel.setProperty(i, "sx", g.sx);
            taskModel.setProperty(i, "sy", g.sy);
            taskModel.setProperty(i, "tx", g.tx);
            taskModel.setProperty(i, "ty", g.ty);
            taskModel.setProperty(i, "c1x", g.c1x);
            taskModel.setProperty(i, "c1y", g.c1y);
            taskModel.setProperty(i, "c2x", g.c2x);
            taskModel.setProperty(i, "c2y", g.c2y);
        }
    }

    function syncStructure(tasks, n, out) {
        const keep = {};
        for (let i = 0; i < n; i++) {
            keep[tasks[i].id] = true;
        }
        for (let i = taskModel.count - 1; i >= 0; i--) {
            if (!keep[taskModel.get(i).id]) {
                taskModel.remove(i);
            }
        }
        const byId = {};
        const found = {};
        for (let i = 0; i < n; i++) {
            byId[tasks[i].id] = tasks[i];
        }
        for (let i = 0; i < taskModel.count; i++) {
            const row = taskModel.get(i);
            const t = byId[row.id];
            if (!t) {
                continue;
            }
            found[row.id] = true;
            if (t.is_active) {
                out.active = i;
            }
            root.syncRow(i, row, t);
        }
        for (let i = 0; i < n; i++) {
            if (!found[tasks[i].id]) {
                if (tasks[i].is_active) {
                    out.active = taskModel.count;
                }
                taskModel.append(root.makeTaskRow(tasks[i], taskModel.count, n));
            }
        }
        root.relayout(n);
    }

    function applyState(state) {
        const parsedTs = Date.parse(state.timestamp);
        if (root.pendingSince > 0 && !isNaN(parsedTs) && parsedTs < root.pendingSince) {
            return;
        }
        root.pendingSince = 0;
        const tasks = state.tasks ? state.tasks : [];
        const n = tasks.length;
        let newActive = -1;
        root.tracking = state.tracking === true;
        root.postponeHours = typeof state.postpone_hours === "number" ? state.postpone_hours : 0;

        const key = n + "|" + Math.round(root.width) + "|" + Math.round(root.height);
        if (key !== root.layoutKey || taskModel.count !== n) {
            root.layoutKey = key;
            root.hidePopup();
            const out = { active: -1 };
            root.syncStructure(tasks, n, out);
            newActive = out.active;
        } else {
            const byId = {};
            for (let i = 0; i < n; i++) {
                byId[tasks[i].id] = tasks[i];
                if (tasks[i].is_active) {
                    newActive = i;
                }
            }
            for (let i = 0; i < taskModel.count; i++) {
                const t = byId[taskModel.get(i).id];
                if (t) {
                    root.syncRow(i, taskModel.get(i), t);
                }
            }
        }

        if (newActive !== activeIndex) {
            const withinGrace = Date.now() < root.optimisticUntil;
            const matchesOptimistic = newActive === root.optimisticActive;
            if (!withinGrace || matchesOptimistic) {
                if (newActive >= 0) {
                    aimPupil(taskModel.get(newActive).angle);
                } else {
                    pupilAnim.stop();
                }
                activeIndex = newActive;
                root.optimisticActive = -1;
                root.optimisticUntil = 0;
            }
        }
    }

    function aimPupil(angle) {
        pupilAnim.from = pupilAngle;
        pupilAnim.to = angle;
        pupilAnim.start();
    }

    function isNodeActive(index, snapshotActive) {
        if (Date.now() < root.optimisticUntil) {
            return index === root.optimisticActive;
        }
        return snapshotActive === true;
    }

    function showPopup(node, description, category, runTime, taskId, lifeTime) {
        hoverPopup.anchorNode = node;
        popupPillText.text = category;
        popupPillText.color = categoryColor(category);
        popupTime.text = runTime;
        popupId.text = "#" + taskId;
        popupDesc.text = description;
        const hasLife = root.postponeHours > 0 && typeof lifeTime === "string" && lifeTime !== "";
        popupLife.visible = hasLife;
        if (hasLife) {
            popupLife.text = i18n("Postpones in %1", lifeTime);
        }
        hoverPopup.visible = true;
        hoverPopup.opacity = 1;
    }

    function hidePopup() {
        hoverPopup.visible = false;
        hoverPopup.opacity = 0;
        hoverPopup.anchorNode = null;
    }

    Repeater {
        id: armRepeater
        z: 0
        model: root.taskModel
        delegate: Item {
            id: arm
            x: root.eyeCx
            y: root.eyeCy
            width: 1
            height: 1
            property bool isActive: root.isNodeActive(index, model.isActive)
            property real cascadeProgress: isActive ? 1 : 0

            onIsActiveChanged: {
                if (isActive) {
                    cascadeIn.start();
                } else {
                    cascadeOut.start();
                }
            }

            NumberAnimation {
                id: cascadeIn
                target: arm
                property: "cascadeProgress"
                to: 1
                duration: 1250
                easing.type: Easing.InOutCubic
            }
            NumberAnimation {
                id: cascadeOut
                target: arm
                property: "cascadeProgress"
                to: 0
                duration: 950
                easing.type: Easing.InOutCubic
            }

            Shape {
                anchors.fill: parent
                antialiasing: true
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: isActive ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.24) : "#1c414868"
                    strokeWidth: 15
                    startX: model.sx
                    startY: model.sy
                    PathCubic {
                        x: model.tx
                        y: model.ty
                        control1X: model.c1x
                        control1Y: model.c1y
                        control2X: model.c2x
                        control2Y: model.c2y
                    }
                }
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 1.0)
                    strokeWidth: 6
                    strokeStyle: ShapePath.DashLine
                    capStyle: ShapePath.FlatCap
                    dashPattern: [model.pathLen, model.pathLen]
                    dashOffset: model.pathLen * (1 - cascadeProgress)
                    startX: model.sx
                    startY: model.sy
                    PathCubic {
                        x: model.tx
                        y: model.ty
                        control1X: model.c1x
                        control1Y: model.c1y
                        control2X: model.c2x
                        control2Y: model.c2y
                    }
                }
            }

            Shape {
                anchors.fill: parent
                antialiasing: true
                opacity: isActive ? 1 - cascadeProgress : 0
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: Qt.tint(root.cAccent, "#66ffffff")
                    strokeWidth: 4.5
                    strokeStyle: ShapePath.DashLine
                    capStyle: ShapePath.FlatCap
                    dashPattern: [24, 24]
                    dashOffset: model.pathLen * (1 - cascadeProgress) + 10
                    startX: model.sx
                    startY: model.sy
                    PathCubic {
                        x: model.tx
                        y: model.ty
                        control1X: model.c1x
                        control1Y: model.c1y
                        control2X: model.c2x
                        control2Y: model.c2y
                    }
                }
            }
        }
    }

    Item {
        id: eyeAssembly
        z: 1
        x: root.eyeCx - root.eyeR
        y: root.eyeCy - root.eyeR
        width: root.eyeR * 2
        height: root.eyeR * 2

        Canvas {
            id: halo
            anchors.centerIn: parent
            width: parent.width * 1.9
            height: parent.height * 1.9
            property bool isOnline: root.online
            property color accent: root.cAccent
            onIsOnlineChanged: requestPaint()
            onAccentChanged: requestPaint()
            onPaint: {
                const ctx = getContext("2d");
                const a = root.cAccent;
                drawRadialGlow(ctx, width, height,
                    root.online ? Qt.rgba(a.r, a.g, a.b, 0.55) : "#2e3b4252",
                    root.online ? Qt.rgba(a.r, a.g, a.b, 0.28) : "#1a3b4252",
                    0.55);
            }
            opacity: root.hasActive ? 0.85 : (root.online ? 0 : 0.25)
            Behavior on opacity {
                NumberAnimation { duration: 500 }
            }
        }

        Canvas {
            id: chassis
            anchors.fill: parent
            property color ring: root.online
                ? (root.hasActive ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.8) : root.cGray)
                : "#414868"
            Behavior on ring {
                ColorAnimation { duration: 400 }
            }
            onRingChanged: requestPaint()
            onPaint: {
                const ctx = getContext("2d");
                const w = width;
                const h = height;
                const cx = w / 2;
                const cy = h / 2;
                const R = Math.min(cx, cy);
                function ringPath(r) {
                    ctx.beginPath();
                    ctx.arc(cx, cy, r, 0, Math.PI * 2);
                }
                ringPath(R);
                ctx.fillStyle = "#10131f";
                ctx.fill();
                ringPath(R - 1);
                ctx.strokeStyle = "#4a5170";
                ctx.lineWidth = 1;
                ctx.stroke();
                ringPath(R - 2);
                ctx.strokeStyle = "#0a0c13";
                ctx.lineWidth = 1.5;
                ctx.stroke();
                const midG = ctx.createLinearGradient(0, 0, 0, h);
                midG.addColorStop(0, "#333a5c");
                midG.addColorStop(0.55, "#1d2236");
                midG.addColorStop(1, "#0e1018");
                ringPath(R - 4);
                ctx.fillStyle = midG;
                ctx.fill();
                ringPath(R - 5);
                ctx.strokeStyle = "#565f89";
                ctx.lineWidth = 0.8;
                ctx.stroke();
                const wellR = R - 9;
                const wellG = ctx.createRadialGradient(cx, cy - wellR * 0.25, wellR * 0.1, cx, cy, wellR);
                wellG.addColorStop(0, "#1a1f33");
                wellG.addColorStop(0.8, "#0c0e17");
                wellG.addColorStop(1, "#07080f");
                ringPath(wellR);
                ctx.fillStyle = wellG;
                ctx.fill();
                ctx.strokeStyle = "rgba(86, 95, 137, 0.22)";
                ctx.lineWidth = 0.7;
                ringPath(R - 5.5);
                ctx.stroke();
                ringPath(wellR + 0.8);
                ctx.stroke();
                ctx.strokeStyle = "rgba(0,0,0,0.5)";
                ringPath(wellR - 0.8);
                ctx.stroke();
                ctx.strokeStyle = ring;
                ctx.lineWidth = 1.4;
                ringPath(wellR - 1.5);
                ctx.stroke();
            }
        }
        Canvas {
                // Perfect 28x28 pupil circle, centered in the eye
                width: 28
                height: 28
                anchors.centerIn: parent
                property bool isOnline: root.online
                property bool isLocked: root.hasActive
                onIsOnlineChanged: requestPaint()
                onIsLockedChanged: requestPaint()
                onPaint: {
                    const ctx = getContext("2d");
                    const w = width;
                    const h = height;
                    const cx = w / 2;
                    const cy = h / 2;
                    const r = cx; // Perfect circle radius

                    ctx.clearRect(0, 0, w, h);

                    // HAL 9000 Radial Gradient
                    const body = ctx.createRadialGradient(cx, cy, 0, cx, cy, r);
                    if (isOnline) {
                        if (isLocked) {
                            // Active task: Pure hot red core
                            body.addColorStop(0.0, "#ff3b30");
                            body.addColorStop(0.25, "#e01b1b");
                            body.addColorStop(0.7, "#7a0404");
                            body.addColorStop(1.0, "#0e0000");
                        } else {
                            // Idle: Dark glassy lens
                            body.addColorStop(0.0, "#2c3550");
                            body.addColorStop(0.45, "#161b2c");
                            body.addColorStop(0.8, "#0a0c14");
                            body.addColorStop(1.0, "#05060a");
                        }
                    } else {
                        // Offline state
                        body.addColorStop(0, "#565f89");
                        body.addColorStop(0.5, "#333b4f");
                        body.addColorStop(1, "#14161f");
                    }

                    ctx.fillStyle = body;
                    ctx.beginPath();
                    ctx.arc(cx, cy, r, 0, Math.PI * 2); // Using arc instead of ellipse
                    ctx.fill();
                }
            }

        Item {
            id: pupilRig
            x: parent.width / 2
            y: parent.height / 2
            width: 1
            height: 1
            rotation: root.pupilAngle + 90
            Canvas {
                x: -11
                y: -18
                width: 22
                height: 36
                property bool isOnline: root.online
                property color accent: root.cAccent
                onIsOnlineChanged: requestPaint()
                onAccentChanged: requestPaint()
                opacity: root.hasActive ? 1 : 0
                Behavior on opacity {
                    NumberAnimation { duration: 400 }
                }
                onPaint: {
                    const ctx = getContext("2d");
                    const w = width;
                    const h = height;
                    ctx.clearRect(0, 0, w, h);
                    const c = isOnline
                        ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.33)
                        : "#333b4252";
                    const g = ctx.createRadialGradient(w / 2, h / 2, 0, w / 2, h / 2, w / 2);
                    g.addColorStop(0, "#00ffffff");
                    g.addColorStop(0.7, c);
                    g.addColorStop(1, "#00ffffff");
                    ctx.fillStyle = g;
                    ctx.beginPath();
                    ctx.ellipse(w / 2, h / 2, w / 2, h / 2, 0, 0, Math.PI * 2);
                    ctx.fill();
                }
            }
        }

        Item {
            anchors.fill: parent
            clip: true
            Canvas {
                anchors.fill: parent
                onPaint: {
                    const ctx = getContext("2d");
                    const w = width;
                    const h = height;
                    const cx = w / 2;
                    const cy = h / 2;
                    const R = Math.min(cx, cy) - 3;
                    const sheen = ctx.createLinearGradient(0, 0, 0, h * 0.5);
                    sheen.addColorStop(0, "rgba(255,255,255,0.18)");
                    sheen.addColorStop(1, "rgba(255,255,255,0)");
                    ctx.strokeStyle = sheen;
                    ctx.lineWidth = R * 0.28;
                    ctx.lineCap = "round";
                    ctx.beginPath();
                    ctx.arc(cx, cy, R * 0.72, Math.PI * 0.98, Math.PI * 1.52);
                    ctx.stroke();
                }
            }
            Canvas {
                anchors.fill: parent
                onPaint: {
                    const ctx = getContext("2d");
                    const w = width;
                    const h = height;
                    const cx = w / 2;
                    const cy = h / 2;
                    const R = Math.min(cx, cy) - 3;
                    const bounce = ctx.createLinearGradient(0, h * 0.55, 0, h);
                    bounce.addColorStop(0, "rgba(255,255,255,0)");
                    bounce.addColorStop(1, "rgba(255,255,255,0.05)");
                    ctx.strokeStyle = bounce;
                    ctx.lineWidth = R * 0.3;
                    ctx.lineCap = "round";
                    ctx.beginPath();
                    ctx.arc(cx, cy, R * 0.82, Math.PI * 1.2, Math.PI * 1.8);
                    ctx.stroke();
                }
            }
            Canvas {
                x: parent.width * 0.22
                y: parent.height * 0.16
                width: 22
                height: 22
                onPaint: {
                    const ctx = getContext("2d");
                    const w = width;
                    const h = height;
                    ctx.clearRect(0, 0, w, h);
                    const g = ctx.createRadialGradient(w / 2, h / 2, 0, w / 2, h / 2, w / 2);
                    g.addColorStop(0, "rgba(255,255,255,0.42)");
                    g.addColorStop(0.4, "rgba(255,255,255,0.1)");
                    g.addColorStop(1, "rgba(255,255,255,0)");
                    ctx.fillStyle = g;
                    ctx.fillRect(0, 0, w, h);
                }
            }
        }
    }

    MouseArea {
        z: 2
        x: root.eyeCx - root.eyeR
        y: root.eyeCy - root.eyeR
        width: root.eyeR * 2
        height: root.eyeR * 2
        cursorShape: Qt.PointingHandCursor
        onClicked: root.openAddTask()
    }

    Text {
        text: "OFFLINE"
        visible: !root.online
        color: root.cDim
        font.pixelSize: 9
        font.letterSpacing: 2.5
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.eyeCy + root.eyeR + 16
    }

    Text {
        text: root.actionError
        visible: root.actionError !== ""
        color: root.cRed
        font.pixelSize: 9
        width: parent.width - 60
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        anchors.horizontalCenter: parent.horizontalCenter
        y: root.eyeCy + root.eyeR + 28
    }

    Timer {
        id: errorTimer
        interval: 5000
        onTriggered: root.actionError = ""
    }

    Repeater {
        id: nodeRepeater
        z: 2
        model: root.taskModel
        delegate: Item {
            id: node
            z: 3
            width: root.nodeW
            height: root.nodeH
            x: root.eyeCx + model.nodeX - width / 2
            y: root.eyeCy + model.nodeY - height / 2
            property bool isActive: root.isNodeActive(index, model.isActive)
            property real glowAmount: isActive ? 0.85 : 0

            onIsActiveChanged: {
                if (isActive) {
                    glowUp.start();
                } else {
                    glowDown.start();
                }
            }

            SequentialAnimation {
                id: glowUp
                running: false
                PauseAnimation { duration: 700 }
                NumberAnimation {
                    target: node
                    property: "glowAmount"
                    to: 0.85
                    duration: 480
                    easing.type: Easing.OutQuad
                }
            }
            NumberAnimation {
                id: glowDown
                target: node
                property: "glowAmount"
                to: 0
                duration: 420
                easing.type: Easing.InQuad
            }

            scale: isActive ? 1.06 : 1.0
            opacity: isActive ? 1.0 : 0.92
            Behavior on scale {
                NumberAnimation { duration: 280; easing.type: Easing.OutCubic }
            }
            Behavior on opacity {
                NumberAnimation { duration: 300 }
            }

            Canvas {
                id: nodeGlow
                z: 0
                anchors.fill: parent
                anchors.margins: -10
                property bool isActive: node.isActive
                property color accent: root.cAccent
                onIsActiveChanged: requestPaint()
                onAccentChanged: requestPaint()
                onPaint: {
                    const ctx = getContext("2d");
                    drawRadialGlow(ctx, width, height,
                        isActive ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.45) : "#1f414868",
                        isActive ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.26) : "#143b4252",
                        0.5);
                }
                opacity: node.glowAmount
            }


            Rectangle {
                        z: 1
                        anchors.fill: parent
                        radius: 14
                        
                        border.color: isActive ? root.cAccent : root.cGray
                        border.width: isActive ? 3 : 1
                        
                        Behavior on border.color {
                            ColorAnimation { duration: 320 }
                        }

                        // Replaces the Canvas with a native gradient that respects the radius
                        gradient: Gradient {
                            GradientStop {
                                position: 0.0
                                color: root.cPanelTop
                            }
                            GradientStop {
                                position: 1.0
                                color: root.cPanelBot
                            }
                        }
                    }


            Rectangle {
                z: 2
                anchors.fill: parent
                radius: 14
                color: "transparent"
                border.color: root.cAccent
                border.width: 2
                opacity: isActive ? 0.55 : 0
                Behavior on opacity {
                    NumberAnimation { duration: 300 }
                }
            }

            MouseArea {
                z: 5
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                Timer {
                    id: hoverTimer
                    interval: Math.max(250, plasmoid.configuration.hoverDelay)
                    onTriggered: root.showPopup(node, model.description, model.category, model.runTime, model.id, model.lifeTime)
                }
                onEntered: hoverTimer.start()
                onExited: {
                    hoverTimer.stop();
                    root.hidePopup();
                }
                onClicked: function(mouse) {
                    if (mouse.button === Qt.RightButton) {
                        hoverTimer.stop();
                        root.hidePopup();
                        contextMenu.target = model;
                        contextMenu.popup();
                    } else {
                        root.toggleTracking(model, index);
                    }
                }
            }

            ColumnLayout {
                z: 3
                anchors.fill: parent
                anchors.margins: 12
                spacing: 4

                RowLayout {
                    spacing: 7
                    Layout.fillWidth: true

                    Text {
                        text: model.runTime
                        color: isActive ? root.cAccent : root.cFg
                        font.pixelSize: 13
                        font.bold: true
                        font.letterSpacing: 1
                    }

                    Item {
                        Layout.fillWidth: true
                    }

                    Rectangle {
                        height: 17
                        width: pillText.implicitWidth + 14
                        radius: 8.5
                        Layout.alignment: Qt.AlignVCenter
                        color: isActive
                            ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.15)
                            : Qt.rgba(root.cFg.r, root.cFg.g, root.cFg.b, 0.06)
                        border.color: isActive
                            ? Qt.rgba(root.cAccent.r, root.cAccent.g, root.cAccent.b, 0.33)
                            : Qt.rgba(root.cFg.r, root.cFg.g, root.cFg.b, 0.18)
                        border.width: 1
                        Text {
                            id: pillText
                            anchors.centerIn: parent
                            text: model.category
                            color: root.categoryColor(model.category)
                            opacity: isActive ? 1.0 : 0.75
                            font.pixelSize: 10
                            font.letterSpacing: 0.8
                            font.capitalization: Font.SmallCaps
                        }
                    }
                }

                Text {
                    text: model.description
                    color: root.cFg
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                    lineHeight: 1.15
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                }
            }

            Item {
                id: lifeline
                z: 4
                visible: root.postponeHours > 0 && model.lifeRatio >= 0
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                anchors.bottomMargin: 8
                height: 3

                Rectangle {
                    anchors.fill: parent
                    radius: 1.5
                    color: Qt.rgba(root.cFg.r, root.cFg.g, root.cFg.b, 0.10)
                }
                Rectangle {
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    radius: 1.5
                    color: root.cAccent
                    width: parent.width * Math.max(0, Math.min(1, model.lifeRatio))
                    Behavior on width {
                        NumberAnimation { duration: 600; easing.type: Easing.OutQuad }
                    }
                }
            }
        }
    }

    Rectangle {
        id: hoverShadow
        z: 9
        visible: hoverPopup.visible
        x: hoverPopup.x + 3
        y: hoverPopup.y + 5
        width: hoverPopup.width
        height: hoverPopup.height
        radius: hoverPopup.radius
        color: "#000000"
        opacity: 0.5
    }


    Rectangle {
        id: hoverPopup
        z: 10
        visible: false
        width: Math.min(360, root.width - 24)
        
        // 1. Dynamically calculate height based on the Column's contents plus margins
        height: popupLayout.implicitHeight + 28 

        radius: 12
        color: root.cPanelTop
        border.color: root.cAccent
        border.width: 2
        opacity: 0
        scale: 0.96
        
        Behavior on opacity {
            NumberAnimation { duration: 140 }
        }
        Behavior on scale {
            NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
        }

        property Item anchorNode: null
        readonly property var anchorPoint: anchorNode ? anchorNode.mapToItem(root, anchorNode.width / 2, 0) : null
        x: anchorNode ? Math.max(4, Math.min(anchorPoint.x - width / 2, root.width - width - 4)) : 0
        y: anchorNode ? Math.max(4, Math.min(anchorPoint.y - height - 12 < 4 ? anchorPoint.y + anchorNode.height + 12 : anchorPoint.y - height - 12, root.height - height - 4)) : 0

        Column {
            id: popupLayout // 2. Give the column an ID
            
            // 3. Remove anchors.fill and anchor to the top/sides instead
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 14
            spacing: 8

            RowLayout {
                width: parent.width
                spacing: 8
                Rectangle {
                    Layout.preferredHeight: 18
                    Layout.preferredWidth: popupPillText.implicitWidth + 14
                    radius: 9
                    color: Qt.rgba(root.cFg.r, root.cFg.g, root.cFg.b, 0.06)
                    border.color: Qt.rgba(root.cFg.r, root.cFg.g, root.cFg.b, 0.18)
                    border.width: 1
                    Text {
                        id: popupPillText
                        anchors.centerIn: parent
                        font.pixelSize: 10
                        font.letterSpacing: 0.8
                        font.capitalization: Font.SmallCaps
                    }
                }
                Text {
                    id: popupTime
                    Layout.alignment: Qt.AlignVCenter
                    color: root.cAccent
                    font.pixelSize: 12
                    font.bold: true
                }
                Item {
                    Layout.fillWidth: true
                }
                Text {
                    id: popupId
                    Layout.alignment: Qt.AlignVCenter
                    color: root.cDim
                    font.pixelSize: 10
                }
            }

            Text {
                id: popupDesc
                width: parent.width
                color: root.cFg
                font.pixelSize: 12
                wrapMode: Text.Wrap
                lineHeight: 1.25
            }

            Text {
                id: popupLife
                width: parent.width
                visible: false
                color: root.cDim
                font.pixelSize: 11
            }
        }
    }

    MouseArea {
        id: addTaskDismiss
        z: 9
        anchors.fill: parent
        visible: addTaskPopup.visible
        onClicked: root.closeAddTask()
    }

    Rectangle {
        id: addTaskPopup
        z: 10
        visible: false
        width: Math.min(360, root.width - 24)
        height: addTaskLayout.implicitHeight + 32
        anchors.centerIn: parent
        radius: 12
        color: root.cPanelTop
        border.color: root.cAccent
        border.width: 2
        opacity: 0
        focus: true
        Keys.onEscapePressed: root.closeAddTask()

        ColumnLayout {
            id: addTaskLayout
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 16
            spacing: 10

            Text {
                text: root.popupMode === "edit" ? i18n("Edit task") : i18n("Add task")
                color: root.cFg
                font.pixelSize: 14
                font.bold: true
            }

            Text {
                text: i18n("Group (pick or type new)")
                color: root.cDim
                font.pixelSize: 10
            }

            QtControls.ComboBox {
                id: groupCombo
                editable: true
                Layout.fillWidth: true
            }

            QtControls.TextField {
                id: newTaskTitle
                placeholderText: i18n("Task title")
                Layout.fillWidth: true
                onAccepted: root.submitAddTask()
            }

            RowLayout {
                width: parent.width
                spacing: 8
                Item {
                    Layout.fillWidth: true
                }
                QtControls.Button {
                    text: i18n("Cancel")
                    onClicked: root.closeAddTask()
                }
                QtControls.Button {
                    text: root.popupMode === "edit" ? i18n("Save") : i18n("Add task")
                    enabled: groupCombo.editText.trim() !== "" && newTaskTitle.text.trim() !== ""
                    onClicked: root.submitAddTask()
                }
            }
        }
    }

    MouseArea {
        id: confirmTrackDismiss
        z: 9
        anchors.fill: parent
        visible: confirmPopup.visible
        onClicked: root.cancelTrack()
    }

    Rectangle {
        id: confirmPopup
        z: 10
        visible: false
        width: Math.min(340, root.width - 24)
        height: confirmTrackLayout.implicitHeight + 32
        anchors.centerIn: parent
        radius: 12
        color: root.cPanelTop
        border.color: root.cAccent
        border.width: 2
        opacity: 0
        focus: true
        Keys.onEscapePressed: root.cancelTrack()

        ColumnLayout {
            id: confirmTrackLayout
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 16
            spacing: 10

            Text {
                id: confirmTrackTitle
                color: root.cFg
                font.pixelSize: 14
                font.bold: true
            }

            Text {
                id: confirmTrackSub
                width: parent.width
                height: paintedHeight
                color: root.cOrange
                font.pixelSize: 11
                wrapMode: Text.WrapAnywhere
                lineHeight: 1.25
            }

            RowLayout {
                width: parent.width
                spacing: 8
                Item {
                    Layout.fillWidth: true
                }
                QtControls.Button {
                    text: i18n("Cancel")
                    onClicked: root.cancelTrack()
                }
                QtControls.Button {
                    id: confirmTrackButton
                    onClicked: root.confirmTrack()
                }
            }
        }
    }

    QtControls.Menu {
        id: contextMenu
        property var target: null
        QtControls.MenuItem {
            text: i18n("Edit…")
            onTriggered: root.openEditTask()
        }
        QtControls.MenuItem {
            text: i18n("Mark done")
            onTriggered: root.runMutation("task-done " + contextMenu.target.id, contextMenu.target.id)
        }
        QtControls.MenuItem {
            text: i18n("Postpone")
            onTriggered: root.runMutation("task-move " + contextMenu.target.id + " " + encArg("future"), contextMenu.target.id)
        }
        QtControls.MenuItem {
            text: i18n("Delete")
            onTriggered: root.runMutation("task-delete " + contextMenu.target.id, contextMenu.target.id)
        }
    }

    NumberAnimation {
        id: pupilAnim
        target: root
        property: "pupilAngle"
        duration: 480
        easing.type: Easing.OutCubic
    }
}
