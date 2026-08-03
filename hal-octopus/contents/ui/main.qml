import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
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

    readonly property color cBg: "#1a1b26"
    readonly property color cFg: "#c0caf5"
    readonly property color cDim: "#565f89"
    readonly property color cRed: "#f7768e"
    readonly property color cNeonRed: "#ff2244"
    readonly property color cOrange: "#e0af68"
    readonly property color cNeonOrange: "#ff9e64"
    readonly property color cGray: "#414868"
    readonly property color cIdlePupil: "#3b4252"
    readonly property color cPanelTop: "#232943"
    readonly property color cPanelBot: "#131622"

    property string stateFile: "/home/rigel/.cache/rehoboam_widget.json"
    property string stateCmd: "cat " + stateFile
    property var taskModel: ListModel {}
    property int activeIndex: -1
    property bool online: false

    property real eyeCx: width / 2
    property real eyeCy: height / 2
    property real eyeR: 36
    property real nodeW: 160
    property real nodeH: 92

    property real pupilAngle: -20
    property bool hasActive: activeIndex >= 0
    property string lastSig: ""

    opacity: root.online ? 1.0 : 0.72
    Behavior on opacity {
        NumberAnimation { duration: 600 }
    }

    Plasma5Support.DataSource {
        id: stateSource
        engine: "executable"
        connectedSources: [root.stateCmd]
        interval: 1
        onNewData: function(source, data) {
            if (data.stdout) {
                try {
                    applyState(JSON.parse(data.stdout));
                    online = true;
                } catch (err) {
                    online = false;
                }
            } else {
                online = false;
            }
        }
    }

    function categoryColor(cat) {
        switch (cat) {
        case "mic": return "#bb9af7";
        case "future": return "#7dcfff";
        case "todo": return "#e0af68";
        default: return "#7aa2f7";
        }
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

    function armGeometry(nodeX, nodeY) {
        const angle = Math.atan2(nodeY, nodeX);
        const len = Math.hypot(nodeX, nodeY);
        const px = -Math.sin(angle);
        const py = Math.cos(angle);
        const sx = Math.cos(angle) * (root.eyeR + 3);
        const sy = Math.sin(angle) * (root.eyeR + 3);
        const endRad = root.nodeH / 2 + 4;
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

    function applyState(state) {
        const tasks = state.tasks ? state.tasks : [];
        const sig = JSON.stringify(tasks.map(t => [t.id, t.description, t.category, t.run_time, t.run_seconds, t.is_active === true]));
        if (sig === root.lastSig) {
            return;
        }
        root.lastSig = sig;

        const n = tasks.length;
        const radius = Math.min(root.width / 2 - root.nodeW / 2, root.height / 2 - root.nodeH / 2) - 34;
        let newActive = -1;

        function build(i) {
            const t = tasks[i];
            const ang = -90 + i * 360 / Math.max(n, 1);
            const rad = radians(ang);
            const nx = Math.cos(rad) * radius;
            const ny = Math.sin(rad) * radius;
            const g = armGeometry(nx, ny);
            if (t.is_active) {
                newActive = i;
            }
            return {
                id: t.id,
                description: t.description,
                category: t.category,
                runTime: t.run_time,
                runSeconds: t.run_seconds,
                isActive: t.is_active === true,
                angle: ang,
                nodeX: nx,
                nodeY: ny,
                sx: g.sx, sy: g.sy, tx: g.tx, ty: g.ty,
                c1x: g.c1x, c1y: g.c1y, c2x: g.c2x, c2y: g.c2y
            };
        }

        if (n !== taskModel.count) {
            taskModel.clear();
            for (let i = 0; i < n; i++) {
                taskModel.append(build(i));
            }
        } else {
            for (let i = 0; i < n; i++) {
                taskModel.set(i, build(i));
            }
        }

        if (newActive !== activeIndex) {
            if (newActive >= 0) {
                idleAnim.stop();
                aimPupil(taskModel.get(newActive).angle);
            } else {
                pupilAnim.stop();
                idleAnim.start();
            }
            activeIndex = newActive;
        }
    }

    function aimPupil(angle) {
        pupilAnim.from = pupilAngle;
        pupilAnim.to = angle;
        pupilAnim.start();
    }

    Repeater {
        id: armRepeater
        z: 0
        model: root.taskModel
        delegate: Item {
            x: root.eyeCx
            y: root.eyeCy
            width: 1
            height: 1
            Shape {
                anchors.fill: parent
                antialiasing: true
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: model.isActive ? "#3ce0af68" : "#1c414868"
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
                    strokeColor: model.isActive ? root.cNeonOrange : "#4a5170"
                    strokeWidth: model.isActive ? 6 : 2
                    strokeStyle: model.isActive ? ShapePath.DashLine : ShapePath.SolidLine
                    capStyle: ShapePath.FlatCap
                    dashPattern: [10, 10]
                    dashOffset: 0
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
                    NumberAnimation on dashOffset {
                        running: model.isActive
                        from: 0
                        to: -20
                        duration: 1000
                        loops: Animation.Infinite
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
            property bool isLocked: root.hasActive
            onIsOnlineChanged: requestPaint()
            onIsLockedChanged: requestPaint()
            onPaint: {
                const ctx = getContext("2d");
                drawRadialGlow(ctx, width, height,
                    isOnline ? (isLocked ? "#5ce0af68" : "#55f7768e") : "#2e3b4252",
                    isOnline ? (isLocked ? "#2ce0af68" : "#26f7768e") : "#1a3b4252",
                    0.55);
            }
            opacity: root.online ? 0.65 : 0.25
            Behavior on opacity {
                NumberAnimation { duration: 500 }
            }
            NumberAnimation on opacity {
                running: root.online
                from: 0.65
                to: 0.88
                duration: 2200
                loops: Animation.Infinite
            }
        }

        Rectangle {
            anchors.centerIn: parent
            width: parent.width + 8
            height: parent.height + 8
            radius: width / 2
            color: "transparent"
            border.color: "#3a4162"
            border.width: 1.5
        }

        Rectangle {
            anchors.fill: parent
            radius: parent.width / 2
            clip: true
            border.color: "#0d0f1a"
            border.width: 1.5
            Canvas {
                anchors.fill: parent
                onPaint: {
                    const ctx = getContext("2d");
                    const g = ctx.createLinearGradient(0, 0, 0, height);
                    g.addColorStop(0, "#333a5c");
                    g.addColorStop(1, "#0e1018");
                    ctx.fillStyle = g;
                    ctx.fillRect(0, 0, width, height);
                }
            }
        }

        Rectangle {
            anchors.fill: parent
            anchors.margins: 4
            radius: parent.width / 2 - 4
            color: "#10131f"
            border.color: "#262b42"
            border.width: 1
        }

        Rectangle {
            anchors.fill: parent
            anchors.margins: 9
            radius: parent.width / 2 - 9
            color: "#0d0f1a"
        }

        Canvas {
            anchors.fill: parent
            anchors.margins: 9
            property bool isOnline: root.online
            onIsOnlineChanged: requestPaint()
            onPaint: {
                const ctx = getContext("2d");
                drawRadialGlow(ctx, width, height,
                    isOnline ? "#ff2244" : "#3b4252",
                    isOnline ? "#8f0f22" : "#232733",
                    0.5);
            }
        }

        Rectangle {
            anchors.fill: parent
            anchors.margins: 8
            radius: parent.width / 2 - 8
            color: "transparent"
            border.width: 1.2
            border.color: root.online ? (root.hasActive ? "#80e0af68" : "#80f7768e") : "#414868"
            Behavior on border.color {
                ColorAnimation { duration: 400 }
            }
        }

        Item {
            id: reticle
            anchors.centerIn: parent
            width: parent.width - 18
            height: parent.height - 18
            NumberAnimation on rotation {
                from: 0
                to: 360
                duration: 120000
                loops: Animation.Infinite
                running: root.online
            }
            Shape {
                anchors.fill: parent
                antialiasing: true
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: root.online ? "#38e0af68" : "#203b4252"
                    strokeWidth: 1.5
                    dashPattern: [2.5, 6.5]
                    startX: reticle.width / 2
                    startY: 0
                    PathArc {
                        x: reticle.width / 2 - 0.01
                        y: 0
                        radiusX: reticle.width / 2
                        radiusY: reticle.width / 2
                        direction: PathArc.Counterclockwise
                    }
                }
            }
            Rectangle {
                x: reticle.width / 2 - 1
                y: 0
                width: 2
                height: 6
                radius: 1
                color: root.online ? "#66e0af68" : "#33414868"
            }
            Rectangle {
                x: reticle.width / 2 - 1
                y: reticle.height - 6
                width: 2
                height: 6
                radius: 1
                color: root.online ? "#66e0af68" : "#33414868"
            }
            Rectangle {
                x: 0
                y: reticle.height / 2 - 1
                width: 6
                height: 2
                radius: 1
                color: root.online ? "#66e0af68" : "#33414868"
            }
            Rectangle {
                x: reticle.width - 6
                y: reticle.height / 2 - 1
                width: 6
                height: 2
                radius: 1
                color: root.online ? "#66e0af68" : "#33414868"
            }
        }

        Item {
            id: pupilRig
            x: 0
            y: 0
            width: 1
            height: 1
            rotation: root.pupilAngle + 90
            Rectangle {
                x: -11
                y: -18
                width: 22
                height: 36
                radius: 11
                color: root.online ? (root.hasActive ? "#55e0af68" : "#55f7768e") : "#333b4252"
            }
            Rectangle {
                x: -6
                y: -9.5
                width: 12
                height: 19
                radius: 6
                color: root.online ? (root.hasActive ? root.cNeonOrange : root.cRed) : root.cIdlePupil
                border.color: "#0d0f1a"
                border.width: 1
                Rectangle {
                    x: 2
                    y: 3
                    width: 3
                    height: 4
                    radius: 2
                    color: "#ffe0e6ff"
                }
            }
        }

        Item {
            anchors.fill: parent
            clip: true
            Canvas {
                width: parent.width * 0.64
                height: parent.height * 0.32
                anchors.horizontalCenter: parent.horizontalCenter
                y: parent.height * 0.08
                rotation: -8
                onPaint: {
                    const ctx = getContext("2d");
                    const g = ctx.createLinearGradient(0, 0, 0, height);
                    g.addColorStop(0, "#2effffff");
                    g.addColorStop(1, "rgba(0,0,0,0)");
                    ctx.fillStyle = g;
                    ctx.fillRect(0, 0, width, height);
                }
            }
            Rectangle {
                width: 7
                height: 7
                radius: 3.5
                color: "#55ffffff"
                x: parent.width * 0.24
                y: parent.height * 0.22
            }
            Canvas {
                width: parent.width * 0.3
                height: parent.height * 0.12
                anchors.horizontalCenter: parent.horizontalCenter
                y: parent.height * 0.82
                onPaint: {
                    const ctx = getContext("2d");
                    const g = ctx.createLinearGradient(0, 0, 0, height);
                    g.addColorStop(0, "#1affffff");
                    g.addColorStop(1, "rgba(0,0,0,0)");
                    ctx.fillStyle = g;
                    ctx.fillRect(0, 0, width, height);
                }
            }
        }
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
            scale: model.isActive ? 1.06 : 1.0
            opacity: model.isActive ? 1.0 : 0.92
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
                property bool isActive: model.isActive
                onIsActiveChanged: requestPaint()
                onPaint: {
                    const ctx = getContext("2d");
                    drawRadialGlow(ctx, width, height,
                        isActive ? "#45e0af68" : "#1f414868",
                        isActive ? "#26e0af68" : "#143b4252",
                        0.5);
                }
                opacity: model.isActive ? 0.9 : 0.4
                Behavior on opacity {
                    NumberAnimation { duration: 400 }
                }
                NumberAnimation on opacity {
                    running: model.isActive
                    from: 0.6
                    to: 0.95
                    duration: 1800
                    loops: Animation.Infinite
                }
            }

            Rectangle {
                z: 1
                anchors.fill: parent
                radius: 14
                clip: true
                border.color: model.isActive ? "#ffb454" : root.cGray
                border.width: model.isActive ? 3 : 1
                Behavior on border.color {
                    ColorAnimation { duration: 320 }
                }
                Canvas {
                    id: panelCanvas
                    anchors.fill: parent
                    property bool isActive: model.isActive
                    onIsActiveChanged: requestPaint()
                    onPaint: {
                        const ctx = getContext("2d");
                        const g = ctx.createLinearGradient(0, 0, 0, height);
                        g.addColorStop(0, isActive ? "#2e3550" : root.cPanelTop);
                        g.addColorStop(1, root.cPanelBot);
                        ctx.fillStyle = g;
                        ctx.fillRect(0, 0, width, height);
                    }
                }
            }

            Rectangle {
                z: 2
                anchors.fill: parent
                radius: 14
                color: "transparent"
                border.color: "#ffb454"
                border.width: 2
                opacity: model.isActive ? 0.55 : 0
                Behavior on opacity {
                    NumberAnimation { duration: 300 }
                }
            }

            Column {
                z: 3
                anchors.fill: parent
                anchors.margins: 12
                spacing: 3

                Row {
                    spacing: 7
                    Item {
                        visible: model.isActive
                        width: 12
                        height: 12
                        anchors.verticalCenter: parent.verticalCenter
                        Rectangle {
                            anchors.centerIn: parent
                            width: 5
                            height: 5
                            radius: 2.5
                            color: root.cNeonOrange
                        }
                        Rectangle {
                            anchors.fill: parent
                            radius: 6
                            color: "transparent"
                            border.color: root.cNeonOrange
                            border.width: 1.2
                            NumberAnimation on scale {
                                running: model.isActive
                                from: 0.6
                                to: 2.1
                                duration: 1400
                                loops: Animation.Infinite
                            }
                            NumberAnimation on opacity {
                                running: model.isActive
                                from: 0.9
                                to: 0
                                duration: 1400
                                loops: Animation.Infinite
                            }
                        }
                    }
                    Text {
                        text: model.runTime
                        color: model.isActive ? root.cNeonOrange : "#d6dcf4"
                        font.pixelSize: 15
                        font.bold: true
                        font.letterSpacing: 1
                    }
                }

                Text {
                    width: parent.width
                    text: model.description
                    color: root.cFg
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    lineHeight: 1.15
                }

                Rectangle {
                    width: pillText.implicitWidth + 14
                    height: 17
                    radius: 8.5
                    color: model.isActive ? "#26e0af68" : "#2a3050"
                    border.color: model.isActive ? "#55e0af68" : "#383f5c"
                    border.width: 1
                    Text {
                        id: pillText
                        anchors.centerIn: parent
                        text: model.category
                        color: root.categoryColor(model.category)
                        opacity: model.isActive ? 1.0 : 0.75
                        font.pixelSize: 10
                        font.letterSpacing: 0.8
                        font.capitalization: Font.SmallCaps
                    }
                }
            }
        }
    }

    NumberAnimation {
        id: pupilAnim
        target: root
        property: "pupilAngle"
        duration: 480
        easing.type: Easing.OutCubic
    }

    SequentialAnimation {
        id: idleAnim
        running: false
        loops: Animation.Infinite
        NumberAnimation {
            target: root
            property: "pupilAngle"
            to: -38
            duration: 2600
            easing.type: Easing.InOutSine
        }
        NumberAnimation {
            target: root
            property: "pupilAngle"
            to: 38
            duration: 2600
            easing.type: Easing.InOutSine
        }
    }
}
