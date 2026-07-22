#!/usr/bin/env bash
# rehoboam.sh — main dashboard / entry point.
# Run this one. It shows the REHOBOAM banner and hands off to kanban.sh
# or timew.sh, both of which live next to this script.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

if ! command -v gum >/dev/null 2>&1; then
  echo "REHOBOAM needs 'gum' (charmbracelet/gum) installed and on your PATH." >&2
  echo "See: https://github.com/charmbracelet/gum#installation" >&2
  exit 1
fi

while true; do
  print_header "REHOBOAM"
  choice=$(gum choose \
    "🗂️   Kanban" \
    "⏱️   TimeW" \
    "📅  Sync to Daily Note" \
    "✖   Quit" \
    --cursor "▶ " --header "your tasks, tracked — pick a module")

  case "$choice" in
  "🗂️   Kanban") bash "$SCRIPT_DIR/kanban.sh" ;;
  "⏱️   TimeW") bash "$SCRIPT_DIR/timew.sh" ;;
  "📅  Sync to Daily Note") sync_to_daily_note; gum style --foreground "$C_GREEN" "✔ Daily note updated!"; sleep 1 ;;
  "✖   Quit" | "") clear; exit 0 ;;
  esac
done
