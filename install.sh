#!/usr/bin/env bash
# install.sh — portable installer for REHOBOAM (TUI suite + HAL-Octopus widget).
#
# Copies the project into a stable install prefix, patches the machine-specific
# paths baked into the widget QML, installs the plasmoid, wires the exporter
# daemon up (systemd user unit or XDG autostart), creates the config file,
# initializes the SQLite DB, and links the commands into ~/.local/bin.
#
# Usage:
#   ./install.sh                     install with defaults
#   ./install.sh --prefix DIR        custom install prefix (~/.local/share/rehoboam)
#   ./install.sh --no-links          skip ~/.local/bin symlinks
#   ./install.sh --no-autostart      skip exporter autostart setup
#   ./install.sh --no-restart        don't restart plasmashell afterwards
#   ./install.sh --uninstall         remove installed artifacts
#   ./install.sh --uninstall --purge also delete ~/.config/rehoboam, the DB and caches
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local/share/rehoboam}"
PLASMOID_ID="org.rehoboam.hal-octopus"
PLASMOID_DIR="$HOME/.local/share/plasma/plasmoids/$PLASMOID_ID"
CONFIG_DIR="$HOME/.config/rehoboam"
CONFIG_FILE="$CONFIG_DIR/config"
BIN_DIR="$HOME/.local/bin"
CACHE_DIR="$HOME/.cache"

DO_UNINSTALL=0
PURGE=0
DO_LINKS=1
DO_AUTOSTART=1
DO_RESTART=1

usage() {
    sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --prefix=*) PREFIX="${1#*=}"; shift ;;
        --uninstall) DO_UNINSTALL=1; shift ;;
        --purge) PURGE=1; shift ;;
        --no-links) DO_LINKS=0; shift ;;
        --no-autostart) DO_AUTOSTART=0; shift ;;
        --no-restart) DO_RESTART=0; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

PREFIX="$(readlink -f "$PREFIX" 2>/dev/null || echo "$PREFIX")"

check_deps() {
    local missing=0
    for cmd in python3 timew; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "  [MISSING] $cmd is required"
            missing=1
        fi
    done
    command -v gum >/dev/null 2>&1 || echo "  [WARN] gum not found — TUI menus won't work (https://github.com/charmbracelet/gum)"
    command -v qmllint >/dev/null 2>&1 || echo "  [WARN] qmllint not found — skipping QML validation"
    [ "$missing" -eq 1 ] && return 1
    return 0
}

find_old_paths() {
    # The repo's QML has machine-specific paths baked in (python3 <dir>/rehoboam_config.py
    # and <home>/.cache/rehoboam_widget.json). Detect them instead of hardcoding.
    local qml="$SCRIPT_DIR/hal-octopus/contents/ui/main.qml"
    OLD_REPO_DIR="$(grep -oP 'python3 \K/[^ ]*/rehoboam_config\.py' "$qml" 2>/dev/null | head -1 | xargs -r dirname)"
    OLD_REPO_DIR="${OLD_REPO_DIR:-/home/rigel/rehoboam}"
    OLD_CACHE="$(grep -oP '\K/[^<"]*/\.cache/rehoboam_widget\.json' "$SCRIPT_DIR/hal-octopus/contents/config/main.xml" 2>/dev/null | head -1 | xargs -r dirname)"
    OLD_CACHE="${OLD_CACHE:-$OLD_REPO_DIR/.cache}"
    echo "  [INFO] patching references to $OLD_REPO_DIR -> $PREFIX"
    echo "  [INFO] patching references to $OLD_CACHE     -> $CACHE_DIR"
}

copy_project() {
    echo "[2/5] Copying project to $PREFIX"
    rm -rf "$PREFIX"
    mkdir -p "$PREFIX"
    tar -C "$SCRIPT_DIR" -cf - \
        --exclude=.git --exclude=__pycache__ \
        --exclude=install.sh \
        . | tar -C "$PREFIX" -xf -
    chmod +x "$PREFIX"/*.sh "$PREFIX"/*.py 2>/dev/null || true
}

patch_widget() {
    echo "[3/5] Patching widget paths and installing plasmoid"
    local -a targets=(
        "$PREFIX/hal-octopus/contents/ui/main.qml"
        "$PREFIX/hal-octopus/contents/ui/configGeneral.qml"
        "$PREFIX/hal-octopus/contents/ui/configKanban.qml"
        "$PREFIX/hal-octopus/contents/ui/configTimew.qml"
        "$PREFIX/hal-octopus/contents/config/main.xml"
    )
    for f in "${targets[@]}"; do
        sed -i "s|$OLD_REPO_DIR|$PREFIX|g; s|$OLD_CACHE|$CACHE_DIR|g" "$f"
    done
    if command -v qmllint >/dev/null 2>&1; then
        qmllint -I /usr/lib/qt6/qml "$PREFIX/hal-octopus/contents/ui/main.qml" \
            "$PREFIX/hal-octopus/contents/ui/configGeneral.qml" \
            "$PREFIX/hal-octopus/contents/ui/configKanban.qml" \
            "$PREFIX/hal-octopus/contents/ui/configTimew.qml"
    fi
    rm -rf "$PLASMOID_DIR"
    mkdir -p "$(dirname "$PLASMOID_DIR")"
    cp -a "$PREFIX/hal-octopus" "$PLASMOID_DIR"
    echo "  [INFO] plasmoid installed to $PLASMOID_DIR"
}

write_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "[4/5] Creating $CONFIG_FILE"
        mkdir -p "$CONFIG_DIR"
        {
            echo "KANBAN_FILE=$HOME/Obsidian Vault/Computer Science/KANBAN.md"
            echo "DAILY_NOTES_DIR=$HOME/Obsidian Vault/Computer Science/999 Daily Notes"
        } > "$CONFIG_FILE"
    else
        echo "[4/5] Keeping existing $CONFIG_FILE"
    fi
}

init_db() {
    echo "  [INFO] initializing database"
    python3 -c "
import sys
sys.path.insert(0, '$PREFIX')
import rehoboam_db
rehoboam_db.startup_sync()
" >/dev/null 2>&1 || echo "  [WARN] DB init/sync failed (board file missing is fine)"
}

make_links() {
    [ "$DO_LINKS" -eq 0 ] && return 0
    echo "[5/5] Linking commands into $BIN_DIR"
    mkdir -p "$BIN_DIR"
    local -a links=(rehoboam rehoboam.sh kanban kanban.sh timew timew.sh)
    for name in "${links[@]}"; do
        local target="$PREFIX/$name"
        [ -f "$target" ] || continue
        if [ -e "$BIN_DIR/$name" ] && [ ! -L "$BIN_DIR/$name" ]; then
            echo "  [WARN] $BIN_DIR/$name exists and is not ours — skipping"
            continue
        fi
        ln -sfn "$target" "$BIN_DIR/$name"
    done
    ln -sfn "$PREFIX/rehoboam_config.py" "$BIN_DIR/rehoboam-config"
    ln -sfn "$PREFIX/rehoboam_exporter.py" "$BIN_DIR/rehoboam-exporter"
    ln -sfn "$PREFIX/reload-widget.sh" "$BIN_DIR/rehoboam-reload"
    if ! command -v rehoboam >/dev/null 2>&1; then
        echo "  [WARN] $BIN_DIR is not on your PATH — add it:"
        echo '        export PATH="$HOME/.local/bin:$PATH"'
    fi
}

setup_autostart() {
    [ "$DO_AUTOSTART" -eq 0 ] && return 0
    if command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload >/dev/null 2>&1; then
        local unit="$HOME/.config/systemd/user/rehoboam-exporter.service"
        mkdir -p "$(dirname "$unit")"
        cat > "$unit" <<EOF
[Unit]
Description=Rehoboam widget state exporter
After=time-sync.target

[Service]
Type=simple
WorkingDirectory=$PREFIX
ExecStart=$(command -v python3) $PREFIX/rehoboam_exporter.py
Restart=on-failure

[Install]
WantedBy=default.target
EOF
        systemctl --user daemon-reload
        systemctl --user enable --now rehoboam-exporter.service >/dev/null 2>&1 \
            && echo "  [INFO] exporter running via systemd user unit" \
            || echo "  [WARN] systemd enable failed — run: systemctl --user enable --now rehoboam-exporter"
    else
        local desk="$HOME/.config/autostart/rehoboam-exporter.desktop"
        mkdir -p "$(dirname "$desk")"
        cat > "$desk" <<EOF
[Desktop Entry]
Type=Application
Name=Rehoboam Exporter
Exec=$(command -v python3) $PREFIX/rehoboam_exporter.py
X-KDE-autostart-after=panel
EOF
        echo "  [INFO] exporter autostart added ($desk) — starts on next login"
        nohup "$(command -v python3)" "$PREFIX/rehoboam_exporter.py" \
            >> /tmp/rehoboam_exporter.log 2>&1 < /dev/null &
        echo "  [INFO] exporter started now (pid $!)"
    fi
}

verify_statefile() {
    sleep 2
    if [ -f "$CACHE_DIR/rehoboam_widget.json" ]; then
        echo "  [OK] widget state file is being written: $CACHE_DIR/rehoboam_widget.json"
    else
        echo "  [WARN] state file not written yet — check /tmp/rehoboam_exporter.log"
    fi
}

restart_plasmashell() {
    [ "$DO_RESTART" -eq 0 ] && return 0
    pgrep -x plasmashell >/dev/null 2>&1 || { echo "  [INFO] plasmashell not running — skipping restart"; return 0; }
    echo "  [INFO] restarting plasmashell"
    rm -rf "$CACHE_DIR/plasma" "$CACHE_DIR/qmlcache" "$CACHE_DIR/plasma_theme_"* 2>/dev/null || true
    pkill -x plasmashell || true
    sleep 1
    nohup plasmashell --replace >/dev/null 2>&1 < /dev/null &
    sleep 4
    pgrep -x plasmashell >/dev/null 2>&1 || echo "  [WARN] plasmashell did not come back up"
}

uninstall() {
    echo "Uninstalling REHOBOAM..."
    systemctl --user disable --now rehoboam-exporter.service >/dev/null 2>&1 || true
    rm -f "$HOME/.config/systemd/user/rehoboam-exporter.service"
    rm -f "$HOME/.config/autostart/rehoboam-exporter.desktop"
    rm -f "$BIN_DIR/rehoboam" "$BIN_DIR/rehoboam.sh" "$BIN_DIR/kanban" "$BIN_DIR/kanban.sh" \
          "$BIN_DIR/timew" "$BIN_DIR/timew.sh" "$BIN_DIR/rehoboam-config" \
          "$BIN_DIR/rehoboam-exporter" "$BIN_DIR/rehoboam-reload"
    rm -rf "$PLASMOID_DIR"
    rm -rf "$PREFIX"
    if [ "$PURGE" -eq 1 ]; then
        rm -rf "$CONFIG_DIR" "$CACHE_DIR/rehoboam_widget.json" \
               "$CACHE_DIR/rehoboam_widget.lock" "$CACHE_DIR/rehoboam_widget.json.tmp"
        echo "Data purged (config, DB, caches)."
    else
        echo "Kept $CONFIG_DIR and timew data. Use --purge to remove them too."
    fi
    restart_plasmashell
    echo "Done."
}

main() {
    if [ "$DO_UNINSTALL" -eq 1 ]; then
        uninstall
        exit 0
    fi
    echo "[1/5] Checking dependencies"
    check_deps || { echo "Install aborted — install missing packages first." >&2; exit 1; }
    find_old_paths
    copy_project
    patch_widget
    write_config
    init_db
    make_links
    setup_autostart
    verify_statefile
    restart_plasmashell
    echo
    echo "Done. Add the HAL-Octopus widget to a panel, or run 'rehoboam' for the TUI."
    echo "Uninstall with: $0 --uninstall"
}

main
