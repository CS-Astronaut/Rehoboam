#!/usr/bin/env bash
# timew.sh — simple gum front end for the `timew` CLI.
# Tasks/groups shown in "Start" are read live from KANBAN.md; nothing here
# writes to that file (only Kanban does that) — this script only calls timew.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
ensure_kanban_file

pause() { sleep "${1:-1}"; }

result_box() {
  local border="$1" body="$2"
  gum style --border rounded --border-foreground "$border" \
    --foreground "$C_FG" --padding "0 2" --margin "1 0" "$body"
}

# ---------------------------------------------------------------------------
# Start — pick a task (groups shown but not selectable), timew start + annotate
# ---------------------------------------------------------------------------
timew_start() {
  print_header "TIMEW"
  mapfile -t entries < <(get_task_entries "$KANBAN_FILE" | awk -F'\t' '$3 !~ /\[[xX]\]/')

  if [ "${#entries[@]}" -eq 0 ]; then
    gum style --foreground "$C_YELLOW" "No open tasks in KANBAN.md"
    pause 1
    return
  fi

  while true; do
    local -a display=() group_map=()
    local last_group=""
    for entry in "${entries[@]}"; do
      IFS=$'\t' read -r ln grp line <<<"$entry"
      if [ "$grp" != "$last_group" ]; then
        display+=("── ${grp} ──")
        group_map+=("")
        last_group="$grp"
      fi
      display+=("   ${line#- \[ \] }")
      group_map+=("$grp")
    done

    sel=$(printf '%s\n' "${display[@]}" | gum choose --header "Start tracking which task?")
    [ -z "$sel" ] && return

    if [[ "$sel" == "── "* ]]; then
      gum style --foreground "$C_RED" "That's a group — choose a task inside it."
      pause 1
      continue
    fi

    local group=""
    for i in "${!display[@]}"; do
      if [ "${display[$i]}" = "$sel" ]; then
        group="${group_map[$i]}"
        break
      fi
    done
    local task="${sel#   }"

    timew start "$group" >/tmp/rehoboam_timew.log 2>&1
    timew annotate @1 "$task" >>/tmp/rehoboam_timew.log 2>&1

    result_box "$C_GREEN" "▶ Started: ${group}
  ↳ ${task}"
    pause 1
    return
  done
}

timew_stop() {
  print_header "TIMEW"
  out=$(timew stop 2>&1)
  result_box "$C_RED" "■ ${out}"
  pause 1.2
}

timew_continue() {
  print_header "TIMEW"
  out=$(timew continue 2>&1)
  result_box "$C_CYAN" "↻ ${out}"
  pause 1.2
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
while true; do
  print_header "TIMEW"
  choice=$(gum choose \
    "▶  Start" \
    "■  Stop" \
    "↻  Continue" \
    "⬅  Return to Main Menu" \
    --cursor "▶ " --header "TIMEW — TimeWarrior front end")

  case "$choice" in
  "▶  Start") timew_start ;;
  "■  Stop") timew_stop ;;
  "↻  Continue") timew_continue ;;
  "⬅  Return to Main Menu" | "") exit 0 ;;
  esac
done
