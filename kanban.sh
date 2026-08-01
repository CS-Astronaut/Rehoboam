#!/usr/bin/env bash
# kanban.sh — gum-powered front end for SQLite backend & Obsidian KANBAN.md sync

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
ensure_kanban_file

# ---------------------------------------------------------------------------
# Show tasks — pick an open task to mark done
# ---------------------------------------------------------------------------
show_tasks() {
  while true; do
    print_header "KANBAN"

    mapfile -t entries < <(get_task_entries | awk -F'\t' '$3 !~ /\[[xX]\]/')

    if [ "${#entries[@]}" -eq 0 ]; then
      show_warning "No open tasks. Nice and clear! ✨"
      return
    fi

    local -a display=() id_map=()
    local last_group=""
    for entry in "${entries[@]}"; do
      IFS=$'\t' read -r tid grp line <<<"$entry"
      if [ "$grp" != "$last_group" ]; then
        display+=("── ${grp} ──")
        id_map+=("-1")
        last_group="$grp"
      fi
      display+=("   ${line#- \[ \] }")
      id_map+=("$tid")
    done
    display+=("⬅  Back")
    id_map+=("-1")

    sel=$(printf '%s\n' "${display[@]}" | gum choose --cursor "▶ " --header "Select a task to mark done")
    [ -z "$sel" ] && return
    [ "$sel" = "⬅  Back" ] && return
    if [[ "$sel" == "── "* ]]; then
      show_error "That's a group heading — pick a task inside it."
      continue
    fi

    local target_id=""
    for i in "${!display[@]}"; do
      if [ "${display[$i]}" = "$sel" ]; then
        target_id="${id_map[$i]}"
        break
      fi
    done

    mark_task_done "$target_id"
    show_success "Marked done & synced to Daily Note!"
  done
}

# ---------------------------------------------------------------------------
# Add task
# ---------------------------------------------------------------------------
add_task() {
  print_header "KANBAN"
  mapfile -t groups < <(get_groups | cut -f2)

  if [ "${#groups[@]}" -eq 0 ]; then
    show_error "No groups yet — create one first."
    return
  fi

  group=$(printf '%s\n' "${groups[@]}" | gum choose --cursor "▶ " --header "Add task to which group?")
  [ -z "$group" ] && return

  text=$(gum input --placeholder "Task description" --header "New task text")
  [ -z "$text" ] && return

  insert_task "$group" "$text"
  show_success "Task added to ${group} & synced to Daily Note"
}

# ---------------------------------------------------------------------------
# Add task group
# ---------------------------------------------------------------------------
add_group() {
  print_header "KANBAN"
  name=$(gum input --placeholder "Group name" --header "New task group name")
  [ -z "$name" ] && return

  if ! add_group_db "$name"; then
    show_error "A group named '${name}' already exists."
    return
  fi

  show_success "Group '${name}' created & synced to Daily Note"
}

# ---------------------------------------------------------------------------
# Edit / delete task
# ---------------------------------------------------------------------------
edit_delete_task() {
  print_header "KANBAN"
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
  display+=("⬅  Cancel")
  id_map+=("-1")

  sel=$(printf '%s\n' "${display[@]}" | gum choose --cursor "▶ " --header "Select a task")
  [ -z "$sel" ] && return
  [ "$sel" = "⬅  Cancel" ] && return

  local target_id=""
  for i in "${!display[@]}"; do
    if [ "${display[$i]}" = "$sel" ]; then
      target_id="${id_map[$i]}"
      break
    fi
  done

  local current_text
  current_text=$(echo "$sel" | sed -E 's/^.+ \[[^]]+\] //')

  action=$(gum choose --cursor "▶ " "✏️  Edit text" "🗑️  Delete" "⬅  Cancel" --header "Action for: ${current_text}")
  case "$action" in
  "✏️  Edit text")
    newtext=$(gum input --value "$current_text" --header "Edit task text")
    [ -z "$newtext" ] && return
    edit_task_text "$target_id" "$newtext"
    show_success "Task updated & synced to Daily Note"
    ;;
  "🗑️  Delete")
    if gum confirm "Delete this task?"; then
      delete_task "$target_id"
      show_error "Task deleted & synced to Daily Note"
    fi
    ;;
  *) return ;;
  esac
}

# ---------------------------------------------------------------------------
# Edit / delete group
# ---------------------------------------------------------------------------
edit_delete_group() {
  print_header "KANBAN"
  mapfile -t glines < <(get_groups)

  if [ "${#glines[@]}" -eq 0 ]; then
    show_warning "No groups yet."
    return
  fi

  local -a display=() id_map=()
  for g in "${glines[@]}"; do
    IFS=$'\t' read -r gid name <<<"$g"
    display+=("$name")
    id_map+=("$gid")
  done
  display+=("⬅  Cancel")
  id_map+=("-1")

  sel=$(printf '%s\n' "${display[@]}" | gum choose --cursor "▶ " --header "Select a group")
  [ -z "$sel" ] && return
  [ "$sel" = "⬅  Cancel" ] && return

  local target_id=""
  for i in "${!display[@]}"; do
    if [ "${display[$i]}" = "$sel" ]; then
      target_id="${id_map[$i]}"
      break
    fi
  done

  action=$(gum choose --cursor "▶ " "✏️  Rename" "🗑️  Delete (with its tasks)" "⬅  Cancel" --header "Action for group: ${sel}")
  case "$action" in
  "✏️  Rename")
    newname=$(gum input --value "$sel" --header "New group name")
    [ -z "$newname" ] && return
    rename_group "$target_id" "$newname"
    show_success "Group renamed & synced to Daily Note"
    ;;
  "🗑️  Delete (with its tasks)")
    if gum confirm "Delete '${sel}' and ALL its tasks? This can't be undone."; then
      delete_group "$target_id"
      show_error "Group deleted & synced to Daily Note"
    fi
    ;;
  *) return ;;
  esac
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
while true; do
  print_header "KANBAN"
  choice=$(gum choose --cursor "▶ " \
    "📋  Show Tasks" \
    "➕  Add Task" \
    "🗃️  Add Task Group" \
    "✏️  Edit / Delete Task" \
    "📁  Edit / Delete Group" \
    "📅  Sync to Daily Note" \
    "⬅  Return to Main Menu" \
    --header "KANBAN — choose an action")

  case "$choice" in
  "📋  Show Tasks") show_tasks ;;
  "➕  Add Task") add_task ;;
  "🗃️  Add Task Group") add_group ;;
  "✏️  Edit / Delete Task") edit_delete_task ;;
  "📁  Edit / Delete Group") edit_delete_group ;;
  "📅  Sync to Daily Note") sync_to_daily_note; show_success "Daily note updated!" ;;
  "⬅  Return to Main Menu" | "") exit 0 ;;
  esac
done
