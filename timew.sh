#!/usr/bin/env bash
# timew.sh — gum front end for the `timew` CLI, with DB-backed reports.
# Tasks/groups shown in "Start" are read live from KANBAN.md; nothing here
# writes to that file (only Kanban does that) — this script only calls timew
# and syncs tracked time into the rehoboam DB / daily note.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
startup_sync

is_tracking() {
  timew 2>/dev/null | grep -q "Tracking"
}

# ---------------------------------------------------------------------------
# Pick an open task — prints "group<TAB>task" on success, nothing on cancel.
# ---------------------------------------------------------------------------
pick_open_task() {
  mapfile -t entries < <(get_task_entries | awk -F'\t' '$3 !~ /\[[xX]\]/')

  if [ "${#entries[@]}" -eq 0 ]; then
    show_warning "No open tasks in KANBAN.md"
    return 1
  fi

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

  local sel=""
  while true; do
    sel=$(printf '%s\n' "${display[@]}" | gum choose --cursor "▶ " --header "Which task?")
    [ -z "$sel" ] && return 1
    if [[ "$sel" == "── "* ]]; then
      show_error "That's a group — pick a task inside it."
      continue
    fi
    break
  done

  local group="" task=""
  for i in "${!display[@]}"; do
    if [ "${display[$i]}" = "$sel" ]; then
      group="${group_map[$i]}"
      task="${sel#   }"
      break
    fi
  done
  printf '%s\t%s\n' "$group" "$task"
}

# ---------------------------------------------------------------------------
# Start — pick a task, timew start + annotate
# ---------------------------------------------------------------------------
timew_start() {
  print_header "TIMEW"
  local pick group task
  pick="$(pick_open_task)" || return
  [ -z "$pick" ] && return
  IFS=$'\t' read -r group task <<<"$pick"

  timew start "$group" >/tmp/rehoboam_timew.log 2>&1
  timew annotate @1 "$task" >>/tmp/rehoboam_timew.log 2>&1

  show_success "▶ Started: ${group}
  ↳ ${task}"
}

# ---------------------------------------------------------------------------
# Stop
# ---------------------------------------------------------------------------
timew_stop() {
  print_header "TIMEW"
  local cur
  cur=$(get_timew_current)
  out=$(timew stop 2>&1)
  sync_to_daily_note
  show_error "■ Stopped: ${cur}"
}

# ---------------------------------------------------------------------------
# Continue
# ---------------------------------------------------------------------------
timew_continue() {
  print_header "TIMEW"
  out=$(timew continue 2>&1)
  show_info "↻ Continued: $(get_timew_last)"
}

# ---------------------------------------------------------------------------
# Switch — stop current (if any), start a new task in one pick
# ---------------------------------------------------------------------------
switch_task() {
  print_header "TIMEW"
  local pick group task
  pick="$(pick_open_task)" || return
  [ -z "$pick" ] && return
  IFS=$'\t' read -r group task <<<"$pick"

  if is_tracking; then
    timew stop >/tmp/rehoboam_timew.log 2>&1
  fi
  timew start "$group" >/tmp/rehoboam_timew.log 2>&1
  timew annotate @1 "$task" >>/tmp/rehoboam_timew.log 2>&1

  show_success "⏭ Switched: ${group}
  ↳ ${task}"
}

# ---------------------------------------------------------------------------
# Cancel — discard the current interval without saving
# ---------------------------------------------------------------------------
cancel_current() {
  print_header "TIMEW"
  if ! is_tracking; then
    show_warning "Nothing is tracking — nothing to cancel."
    return
  fi

  local cur
  cur=$(get_timew_current)
  if gum confirm "Cancel this interval? ${cur}"; then
    out=$(timew cancel 2>&1)
    sync_to_daily_note
    show_error "🚫 Cancelled: ${cur}"
  else
    show_dim "Kept tracking."
  fi
}

# ---------------------------------------------------------------------------
# Status — what's running, live elapsed time
# ---------------------------------------------------------------------------
timew_status() {
  print_header "TIMEW"
  if is_tracking; then
    show_info "⏱  $(get_timew_status)"
  else
    show_dim "Nothing tracking."
  fi
}

# ---------------------------------------------------------------------------
# Reports — DB-backed
# ---------------------------------------------------------------------------
show_today_summary() {
  print_header "TIMEW"
  show_info "$(get_today_summary)"
}

show_week_summary() {
  print_header "TIMEW"
  show_info "$(get_week_summary)"
}

show_task_totals() {
  print_header "TIMEW"
  mapfile -t entries < <(get_task_entries)

  if [ "${#entries[@]}" -eq 0 ]; then
    show_warning "No tasks yet."
    return
  fi

  local -a display=() id_map=()
  for entry in "${entries[@]}"; do
    IFS=$'\t' read -r tid grp line <<<"$entry"
    local mark="⬜"
    [[ "$line" == *"[x]"* || "$line" == *"[X]"* ]] && mark="✅"
    display+=("${mark} [${grp}] ${line#- \[?\] }")
    id_map+=("$tid")
  done

  sel=$(printf '%s\n' "${display[@]}" | gum choose --cursor "▶ " --header "Totals for which task?")
  [ -z "$sel" ] && return

  local target_id=""
  for i in "${!display[@]}"; do
    if [ "${display[$i]}" = "$sel" ]; then
      target_id="${id_map[$i]}"
      break
    fi
  done

  show_info "$(get_task_totals "$target_id")"
}

# ---------------------------------------------------------------------------
# Add time manually — record time without live tracking
# ---------------------------------------------------------------------------
add_time() {
  print_header "TIMEW"
  local pick group task
  pick="$(pick_open_task)" || return
  [ -z "$pick" ] && return
  IFS=$'\t' read -r group task <<<"$pick"

  local duration=""
  duration=$(gum input --placeholder "e.g. 30min / 1h 15min" --header "Time to add for: ${task}")
  [ -z "$duration" ] && return

  if add_time_manually "$group" "$task" "$duration"; then
    show_success "➕ Added ${duration}: ${group}
  ↳ ${task}"
  else
    show_error "$(cat /tmp/rehoboam_timew.log)"
  fi
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
    "⏭  Switch Task" \
    "🚫  Cancel Current" \
    "⏱  Status" \
    "📊  Today Summary" \
    "🗓  Week Summary" \
    "🏷  Task Totals" \
    "➕  Add Time Manually" \
    "⬅  Return to Main Menu" \
    --cursor "▶ " --header "TIMEW — choose an action")

  case "$choice" in
  "▶  Start") timew_start ;;
  "■  Stop") timew_stop ;;
  "↻  Continue") timew_continue ;;
  "⏭  Switch Task") switch_task ;;
  "🚫  Cancel Current") cancel_current ;;
  "⏱  Status") timew_status ;;
  "📊  Today Summary") show_today_summary ;;
  "🗓  Week Summary") show_week_summary ;;
  "🏷  Task Totals") show_task_totals ;;
  "➕  Add Time Manually") add_time ;;
  "⬅  Return to Main Menu" | "") exit 0 ;;
  esac
done
