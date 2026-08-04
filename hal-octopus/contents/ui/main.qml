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

    property string stateFile: plasmoid.configuration.stateFile
    property string stateCmd: "python3 /home/rigel/rehoboam/rehoboam_config.py cat " + encArg(stateFile)

    function encArg(s) {
        return encodeURIComponent(s).replace(/[!'()*~]/g, c => "%" + c.charCodeAt(0).toString(16).toUpperCase());
    }
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
    property real haloOpacity: 0.65
    property real reticleStep: 1
    property real nodePulse: 0.775
    property real armFlash: 1

    opacity: root.online ? 1.0 : 0.72
    Behavior on opacity {
        NumberAnimation { duration: 600 }
    }

    Timer {
        id: tick
        interval: 300
        repeat: true
        running: root.online
        property real phase: 0
        property int snapCount: 0
        onTriggered: {
            reticle.rotation = (reticle.rotation + root.reticleStep) % 360;
            phase = phase + 0.18;
            root.haloOpacity = 0.765 + 0.115 * Math.sin(phase);
            root.nodePulse = 0.6 + 0.35 * (0.5 + 0.5 * Math.sin(phase));
            root.armFlash = 0.5 + 0.5 * Math.sin(phase * 3);
            if (++snapCount >= 10) {
                snapCount = 0;
                if (!root.hasActive)
                    pupilAngle = -38 + Math.random() * 76;
            }
        }
    }

    Plasma5Support.DataSource {
        id: stateSource
        engine: "executable"
        connectedSources: [root.stateCmd]
        interval: Math.max(1000, plasmoid.configuration.pollInterval * 1000)
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

    Plasma5Support.DataSource {
        id: actionSource
        engine: "executable"
        connectedSources: []
        onNewData: function(source, data) {
            actionSource.disconnectSource(source);
            if (data.stderr) {
                console.warn("rehoboam action failed:", data.stderr.trim());
            }
        }
    }

    function runAction(cmd) {
        actionSource.connectSource(cmd);
    }

    function toggleTracking(entry) {
        root.hidePopup();
        if (entry.isActive) {
            runAction("timew stop");
        } else if (root.hasActive) {
            runAction("python3 /home/rigel/rehoboam/rehoboam_config.py timew-switch " +
                      encArg(entry.group) + " " + encArg(entry.description));
        } else {
            runAction("python3 /home/rigel/rehoboam/rehoboam_config.py timew-start " +
                      encArg(entry.group) + " " + encArg(entry.description));
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
                group: t.group,
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
            root.hidePopup();
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
                aimPupil(taskModel.get(newActive).angle);
            } else {
                pupilAnim.stop();
            }
            activeIndex = newActive;
        }
    }

    function aimPupil(angle) {
        pupilAnim.from = pupilAngle;
        pupilAnim.to = angle;
        pupilAnim.start();
    }

    function showPopup(node, description, category, runTime, taskId) {
        hoverPopup.anchorNode = node;
        popupPillText.text = category;
        popupPillText.color = categoryColor(category);
        popupTime.text = runTime;
        popupId.text = "#" + taskId;
        popupDesc.text = description;
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
                    strokeColor: model.isActive ? Qt.rgba(1.0, 0.62, 0.39, 0.35 + 0.65 * root.armFlash) : "#4a5170"
                    strokeWidth: model.isActive ? 6 : 2
                    strokeStyle: ShapePath.SolidLine
                    capStyle: ShapePath.FlatCap
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
            property bool isLocked: root.hasActive
            onIsOnlineChanged: requestPaint()
            onIsLockedChanged: requestPaint()
            onPaint: {
                const ctx = getContext("2d");
                drawRadialGlow(ctx, width, height,
                    isOnline ? (isLocked ? "#55ff2244" : "#5ce0af68") : "#2e3b4252",
                    isOnline ? (isLocked ? "#26ff2244" : "#2ce0af68") : "#1a3b4252",
                    0.55);
            }
            opacity: root.online ? root.haloOpacity : 0.25
        }

        Canvas {
            id: chassis
            anchors.fill: parent
                property color ring: root.online ? (root.hasActive ? "#80ff2244" : "#80e0af68") : "#414868" 
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
                            // Active task: Classic HAL Hot Core
                            body.addColorStop(0.0, "#ffeb3b");  // Hot yellow core
                            body.addColorStop(0.15, "#ff2244"); // Intense neon red
                            body.addColorStop(0.6, "#880011");  // Deep dark red
                            body.addColorStop(1.0, "#0a0000");  // Almost black at the edge
                        } else {
                            // Idle: Dimmer orange/amber version
                            body.addColorStop(0.0, "#ffb454");
                            body.addColorStop(0.2, "#e07a28");
                            body.addColorStop(0.7, "#4d2605");
                            body.addColorStop(1.0, "#0a0000");
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

                    // HAL Glass Lens Reflection (Cool blue/white tint at the top)
                    ctx.strokeStyle = "rgba(150, 200, 255, 0.25)"; 
                    ctx.lineWidth = 3;
                    ctx.lineCap = "round";
                    ctx.beginPath();
                    ctx.arc(cx, cy, r * 0.75, Math.PI * 1.1, Math.PI * 1.8);
                    ctx.stroke();

                    // Inner bright highlight
                    ctx.strokeStyle = "rgba(255, 255, 255, 0.4)";
                    ctx.lineWidth = 1;
                    ctx.beginPath();
                    ctx.arc(cx, cy, r * 0.65, Math.PI * 1.2, Math.PI * 1.7);
                    ctx.stroke();
                }
            }

        Item {
            id: reticle
            anchors.centerIn: parent
            width: parent.width - 18
            height: parent.height - 18
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
            Shape {
                anchors.fill: parent
                antialiasing: true
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: root.online ? "#99e0af68" : "#33414868"
                    strokeWidth: 1
                    capStyle: ShapePath.FlatCap
                    startX: reticle.width / 2
                    startY: -2
                    PathLine { x: reticle.width / 2; y: 6 }
                }
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: root.online ? "#99e0af68" : "#33414868"
                    strokeWidth: 1
                    capStyle: ShapePath.FlatCap
                    startX: reticle.width / 2
                    startY: reticle.height - 6
                    PathLine { x: reticle.width / 2; y: reticle.height + 2 }
                }
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: root.online ? "#99e0af68" : "#33414868"
                    strokeWidth: 1
                    capStyle: ShapePath.FlatCap
                    startX: -2
                    startY: reticle.height / 2
                    PathLine { x: 6; y: reticle.height / 2 }
                }
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: root.online ? "#99e0af68" : "#33414868"
                    strokeWidth: 1
                    capStyle: ShapePath.FlatCap
                    startX: reticle.width - 6
                    startY: reticle.height / 2
                    PathLine { x: reticle.width + 2; y: reticle.height / 2 }
                }
            }
            Shape {
                id: diagShape
                anchors.fill: parent
                antialiasing: true
                property real q: reticle.width * 0.3536
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: root.online ? "#26e0af68" : "#1c414868"
                    strokeWidth: 1
                    capStyle: ShapePath.FlatCap
                    startX: reticle.width / 2 - diagShape.q - 2.5
                    startY: reticle.height / 2 - diagShape.q - 2.5
                    PathLine {
                        x: reticle.width / 2 - diagShape.q + 0.5
                        y: reticle.height / 2 - diagShape.q + 0.5
                    }
                }
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: root.online ? "#26e0af68" : "#1c414868"
                    strokeWidth: 1
                    capStyle: ShapePath.FlatCap
                    startX: reticle.width / 2 + diagShape.q - 0.5
                    startY: reticle.height / 2 - diagShape.q - 2.5
                    PathLine {
                        x: reticle.width / 2 + diagShape.q + 2.5
                        y: reticle.height / 2 - diagShape.q + 0.5
                    }
                }
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: root.online ? "#26e0af68" : "#1c414868"
                    strokeWidth: 1
                    capStyle: ShapePath.FlatCap
                    startX: reticle.width / 2 - diagShape.q - 2.5
                    startY: reticle.height / 2 + diagShape.q - 0.5
                    PathLine {
                        x: reticle.width / 2 - diagShape.q + 0.5
                        y: reticle.height / 2 + diagShape.q + 2.5
                    }
                }
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: root.online ? "#26e0af68" : "#1c414868"
                    strokeWidth: 1
                    capStyle: ShapePath.FlatCap
                    startX: reticle.width / 2 + diagShape.q - 0.5
                    startY: reticle.height / 2 + diagShape.q - 0.5
                    PathLine {
                        x: reticle.width / 2 + diagShape.q + 2.5
                        y: reticle.height / 2 + diagShape.q + 2.5
                    }
                }
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
                property bool isLocked: root.hasActive
                onIsOnlineChanged: requestPaint()
                onIsLockedChanged: requestPaint()
                onPaint: {
                    const ctx = getContext("2d");
                    const w = width;
                    const h = height;
                    ctx.clearRect(0, 0, w, h);
                    const c = isOnline ? (isLocked ? "#55e0af68" : "#55f7768e") : "#333b4252";
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
                    sheen.addColorStop(0, "rgba(255,255,255,0.14)");
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
                    g.addColorStop(0, "rgba(255,255,255,0.38)");
                    g.addColorStop(0.4, "rgba(255,255,255,0.1)");
                    g.addColorStop(1, "rgba(255,255,255,0)");
                    ctx.fillStyle = g;
                    ctx.fillRect(0, 0, w, h);
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
                opacity: model.isActive ? root.nodePulse : 0.4
            }


            Rectangle {
                        z: 1
                        anchors.fill: parent
                        radius: 14
                        
                        border.color: model.isActive ? "#ffb454" : root.cGray
                        border.width: model.isActive ? 3 : 1
                        
                        Behavior on border.color {
                            ColorAnimation { duration: 320 }
                        }

                        // Replaces the Canvas with a native gradient that respects the radius
                        gradient: Gradient {
                            GradientStop {
                                position: 0.0
                                color: model.isActive ? "#2e3550" : root.cPanelTop
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
                border.color: "#ffb454"
                border.width: 2
                opacity: model.isActive ? 0.55 : 0
                Behavior on opacity {
                    NumberAnimation { duration: 300 }
                }
            }

            MouseArea {
                z: 5
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                Timer {
                    id: hoverTimer
                    interval: Math.max(250, plasmoid.configuration.hoverDelay)
                    onTriggered: root.showPopup(node, model.description, model.category, model.runTime, model.id)
                }
                onEntered: hoverTimer.start()
                onExited: {
                    hoverTimer.stop();
                    root.hidePopup();
                }
                onClicked: root.toggleTracking(model)
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
        color: "#2e3550"
        border.color: "#7aa2f7"
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
                    color: "#2a3050"
                    border.color: "#383f5c"
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
                    color: root.cNeonOrange
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
