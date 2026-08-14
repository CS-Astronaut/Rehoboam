#!/usr/bin/env bash
# Reload the HAL-Octopus widget: lint, sync, clear caches, restart plasmashell.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIDGET="$DIR/hal-octopus"
TARGET="$HOME/.local/share/plasma/plasmoids/org.rehoboam.hal-octopus"
QML="$WIDGET/contents/ui/main.qml"

echo "[1/4] Linting $QML"
if command -v qmllint >/dev/null 2>&1; then
    qmllint -I /usr/lib/qt6/qml "$QML"
    echo "      lint OK"
else
    echo "      qmllint not found, skipping"
fi

echo "[2/4] Syncing widget to $TARGET"
rsync -a --delete "$WIDGET/" "$TARGET/"
ln -sf "$HOME/.local/share/rehoboam/rehoboam_config.py" "$TARGET/rehoboam_config.py"
echo "      synced"

echo "[3/4] Cleaning QML caches"
rm -rf "$HOME/.cache/plasma" "$HOME/.cache/qmlcache" "$HOME/.cache/plasma_theme_*"
echo "      caches cleared"

echo "[4/4] Restarting plasmashell"
pkill -x plasmashell || true
sleep 1
nohup plasmashell --replace >/dev/null 2>&1 < /dev/null &
sleep 4
if pgrep -x plasmashell >/dev/null; then
    echo "      plasmashell restarted"
else
    echo "      WARNING: plasmashell not running"
    exit 1
fi

echo "Done. Widget reloaded."
