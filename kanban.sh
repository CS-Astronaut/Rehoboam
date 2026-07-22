#!/usr/bin/env bash
# kanban.sh — gum-powered front end for KANBAN.md
# All actions below mutate the markdown file directly; nothing is cached.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
ensure_kanban_file

pause() { sleep "${1:-0.8}"; }

# ---------------------------------------------------------------------------
# Show tasks — pick an open task to mark done
# ---------------------------------------------------------------------------
show_tasks() {
  while true; do
    print_header "KANBAN"

    mapfile -t entries < <(get_task_entries "$KANBAN_FILE" | awk -F'\t' '$3 !~ /\[[xX]\]/')

    if [ "${#entries[@]}" -eq 0 ]; then
      gum style --foreground "$C_YELLOW" "No open tasks. Nice and clear! ✨"
      gum input --placeholder "Press enter to go back" >/dev/null
      return
    fi

    local -a display=() lineno_map=()
    local last_group=""
    for entry in "${entries[@]}"; do
      IFS=$'\t' read -r ln grp line <<<"$entry"
      if [ "$grp" != "$last_group" ]; then
        display+=("── ${grp} ──")
        lineno_map+=("-1")
        last_group="$grp"
      fi
      display+=("   ${line#- \[ \] }")
      lineno_map+=("$ln")
    done
    display+=("⬅  Back")
    lineno_map+=("-1")

    sel=$(printf '%s\n' "${display[@]}" | gum choose --header "Select a task to mark done")
    [ -z "$sel" ] && return
    [ "$sel" = "⬅  Back" ] && return
    if [[ "$sel" == "── "* ]]; then
      gum style --foreground "$C_RED" "That's a group heading — pick a task inside it."
      pause 1
      continue
    fi

    local target_line=""
    for i in "${!display[@]}"; do
      if [ "${display[$i]}" = "$sel" ]; then
        target_line="${lineno_map[$i]}"
        break
      fi
    done

    mark_task_done "$KANBAN_FILE" "$target_line"
    gum style --foreground "$C_GREEN" "✔ Marked done!"
    pause 0.6
  done
}

# ---------------------------------------------------------------------------
# Add task
# ---------------------------------------------------------------------------
add_task() {
  print_header "KANBAN"
  mapfile -t groups < <(get_groups "$KANBAN_FILE" | cut -f2)

  if [ "${#groups[@]}" -eq 0 ]; then
    gum style --foreground "$C_RED" "No groups yet — create one first."
    pause 1.2
    return
  fi

  group=$(printf '%s\n' "${groups[@]}" | gum choose --header "Add task to which group?")
  [ -z "$group" ] && return

  text=$(gum input --placeholder "Task description" --header "New task text")
  [ -z "$text" ] && return

  insert_task "$KANBAN_FILE" "$group" "$text"
  gum style --foreground "$C_GREEN" "✔ Task added to ${group}"
  pause 0.8
}

# ---------------------------------------------------------------------------
# Add task group
# ---------------------------------------------------------------------------
add_group() {
  print_header "KANBAN"
  name=$(gum input --placeholder "Group name" --header "New task group name")
  [ -z "$name" ] && return

  if grep -qF "## ${name}" "$KANBAN_FILE"; then
    gum style --foreground "$C_RED" "A group named '${name}' already exists."
    pause 1.2
    return
  fi

  printf '\n## %s\n' "$name" >>"$KANBAN_FILE"
  gum style --foreground "$C_GREEN" "✔ Group '${name}' created"
  pause 0.8
}

# ---------------------------------------------------------------------------
# Edit / delete task
# ---------------------------------------------------------------------------
edit_delete_task() {
  print_header "KANBAN"
  mapfile -t entries < <(get_task_entries "$KANBAN_FILE")

  if [ "${#entries[@]}" -eq 0 ]; then
    gum style --foreground "$C_YELLOW" "No tasks yet."
    pause 1
    return
  fi

  local -a display=() lineno_map=()
  for entry in "${entries[@]}"; do
    IFS=$'\t' read -r ln grp line <<<"$entry"
    local mark="⬜"
    [[ "$line" == *"[x]"* || "$line" == *"[X]"* ]] && mark="✅"
    display+=("${mark} [${grp}] ${line#- \[?\] }")
    lineno_map+=("$ln")
  done
  display+=("⬅  Cancel")
  lineno_map+=("-1")

  sel=$(printf '%s\n' "${display[@]}" | gum choose --header "Select a task")
  [ -z "$sel" ] && return
  [ "$sel" = "⬅  Cancel" ] && return

  local target_line=""
  for i in "${!display[@]}"; do
    if [ "${display[$i]}" = "$sel" ]; then
      target_line="${lineno_map[$i]}"
      break
    fi
  done

  local current_text
  current_text=$(sed -n "${target_line}p" "$KANBAN_FILE" | sed -E 's/^- \[[ xX]\] //')

  action=$(gum choose "✏️  Edit text" "🗑️  Delete" "⬅  Cancel" --header "Action for: ${current_text}")
  case "$action" in
  "✏️  Edit text")
    newtext=$(gum input --value "$current_text" --header "Edit task text")
    [ -z "$newtext" ] && return
    edit_task_text "$KANBAN_FILE" "$target_line" "$newtext"
    gum style --foreground "$C_GREEN" "✔ Task updated"
    ;;
  "🗑️  Delete")
    if gum confirm "Delete this task?"; then
      delete_line "$KANBAN_FILE" "$target_line"
      gum style --foreground "$C_RED" "🗑 Task deleted"
    fi
    ;;
  *) return ;;
  esac
  pause 0.8
}

# ---------------------------------------------------------------------------
# Edit / delete group
# ---------------------------------------------------------------------------
edit_delete_group() {
  print_header "KANBAN"
  mapfile -t glines < <(get_groups "$KANBAN_FILE")

  if [ "${#glines[@]}" -eq 0 ]; then
    gum style --foreground "$C_YELLOW" "No groups yet."
    pause 1
    return
  fi

  local -a display=() lineno_map=()
  for g in "${glines[@]}"; do
    IFS=$'\t' read -r ln name <<<"$g"
    display+=("$name")
    lineno_map+=("$ln")
  done
  display+=("⬅  Cancel")
  lineno_map+=("-1")

  sel=$(printf '%s\n' "${display[@]}" | gum choose --header "Select a group")
  [ -z "$sel" ] && return
  [ "$sel" = "⬅  Cancel" ] && return

  local target_line=""
  for i in "${!display[@]}"; do
    if [ "${display[$i]}" = "$sel" ]; then
      target_line="${lineno_map[$i]}"
      break
    fi
  done

  action=$(gum choose "✏️  Rename" "🗑️  Delete (with its tasks)" "⬅  Cancel" --header "Action for group: ${sel}")
  case "$action" in
  "✏️  Rename")
    newname=$(gum input --value "$sel" --header "New group name")
    [ -z "$newname" ] && return
    rename_group "$KANBAN_FILE" "$target_line" "$newname"
    gum style --foreground "$C_GREEN" "✔ Group renamed"
    ;;
  "🗑️  Delete (with its tasks)")
    if gum confirm "Delete '${sel}' and ALL its tasks? This can't be undone."; then
      end_line=$(group_end_line "$KANBAN_FILE" "$target_line")
      delete_range "$KANBAN_FILE" "$target_line" "$end_line"
      gum style --foreground "$C_RED" "🗑 Group deleted"
    fi
    ;;
  *) return ;;
  esac
  pause 0.8
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
while true; do
  print_header "KANBAN"
  choice=$(gum choose \
    "📋  Show Tasks" \
    "➕  Add Task" \
    "🗃️   Add Task Group" \
    "✏️   Edit / Delete Task" \
    "📁  Edit / Delete Group" \
    "⬅  Return to Main Menu" \
    --cursor "▶ " --header "KANBAN — choose an action")

  case "$choice" in
  "📋  Show Tasks") show_tasks ;;
  "➕  Add Task") add_task ;;
  "🗃️   Add Task Group") add_group ;;
  "✏️   Edit / Delete Task") edit_delete_task ;;
  "📁  Edit / Delete Group") edit_delete_group ;;
  "⬅  Return to Main Menu" | "") exit 0 ;;
  esac
done
