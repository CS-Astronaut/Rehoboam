#!/usr/bin/env bash
# common.sh — shared config, styling, ASCII banner renderer, and
# SQLite + Python database helpers for the REHOBOAM tool suite.
# Sourced by rehoboam.sh, kanban.sh and timew.sh — never run directly.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_EXEC="python3"
DB_CLI="$SCRIPT_DIR/rehoboam_db.py"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
KANBAN_FILE="${KANBAN_FILE:-$HOME/Obsidian Vault/Computer Science/KANBAN.md}"
DAILY_NOTES_DIR="${DAILY_NOTES_DIR:-$HOME/Obsidian Vault/Computer Science/999 Daily Notes}"

# Tokyo Night palette
C_BG="#1a1b26"
C_BLUE="#7aa2f7"
C_PURPLE="#bb9af7"
C_CYAN="#7dcfff"
C_GREEN="#9ece6a"
C_RED="#f7768e"
C_YELLOW="#e0af68"
C_FG="#c0caf5"
C_DIM="#565f89"

# ---------------------------------------------------------------------------
# ASCII banner font (5x6 block glyphs) — covers REHOBOAM / KANBAN / TIMEW
# ---------------------------------------------------------------------------
declare -A FONT
FONT[A]=" ███ 
█   █
█████
█   █
█   █
█   █"
FONT[B]="████ 
█   █
████ 
█   █
█   █
████ "
FONT[E]="█████
█    
████ 
█    
█    
█████"
FONT[H]="█   █
█   █
█████
█   █
█   █
█   █"
FONT[I]="█████
  █  
  █  
  █  
  █  
█████"
FONT[K]="█   █
█  █ 
███  
█  █ 
█   █
█   █"
FONT[M]="█   █
██ ██
█ █ █
█   █
█   █
█   █"
FONT[N]="█   █
██  █
█ █ █
█  ██
█   █
█   █"
FONT[O]=" ███ 
█   █
█   █
█   █
█   █
 ███ "
FONT[R]="████ 
█   █
████ 
█ █  
█  █ 
█   █"
FONT[T]="█████
  █  
  █  
  █  
  █  
  █  "
FONT[W]="█   █
█   █
█   █
█ █ █
██ ██
█   █"

render_banner() {
  local word="$1" rows=6
  local -a out
  for ((r = 0; r < rows; r++)); do out[r]=""; done
  for ((i = 0; i < ${#word}; i++)); do
    local ch="${word:$i:1}"
    local glyph="${FONT[$ch]}"
    local r=0
    while IFS= read -r line; do
      out[$r]+="${line} "
      ((r++))
    done <<<"$glyph"
  done
  for ((r = 0; r < rows; r++)); do
    printf '%s\n' "${out[$r]}"
  done
}

print_header() {
  clear
  local banner
  banner="$(render_banner "$1")"
  gum style \
    --border rounded --border-foreground "$C_PURPLE" \
    --foreground "$C_BLUE" --align center \
    --padding "1 4" --margin "1 0 1 0" \
    "$banner"
}

# ---------------------------------------------------------------------------
# Result UI — every message is a rounded box with a dim "press enter" footer.
# Nothing auto-dismisses; the user presses Enter to continue.
# ---------------------------------------------------------------------------

show_box() {
  local border="$1" body="$2"
  gum style \
    --border rounded --border-foreground "$border" \
    --foreground "$C_FG" --padding "0 2" --margin "1 0" \
    "$(printf '%s\n\n  \033[2m↩ Press enter to continue\033[0m' "$body")"
}

show_result() {
  show_box "$1" "$2"
  read -r
}

show_success() { show_result "$C_GREEN" "$1"; }
show_error()   { show_result "$C_RED" "$1"; }
show_warning() { show_result "$C_YELLOW" "$1"; }
show_info()    { show_result "$C_CYAN" "$1"; }
show_dim()     { show_result "$C_DIM" "$1"; }

# ---------------------------------------------------------------------------
# Python / SQLite Helpers
# ---------------------------------------------------------------------------

ensure_kanban_file() {
  "$PYTHON_EXEC" -c "
import rehoboam_db
rehoboam_db.init_db()
rehoboam_db.sync_kanban_file_to_db()
"
}

startup_sync() {
  "$PYTHON_EXEC" -c "
import rehoboam_db
rehoboam_db.startup_sync()
"
}

get_groups() {
  "$PYTHON_EXEC" -c "
import rehoboam_db
for g in rehoboam_db.get_groups():
    print(f\"{g['id']}\t{g['name']}\")
"
}

get_task_entries() {
  "$PYTHON_EXEC" -c "
import rehoboam_db
for t in rehoboam_db.get_all_tasks():
    chk = '[x]' if t['is_done'] else '[ ]'
    print(f\"{t['id']}\t{t['group_name']}\t- {chk} {t['description']}\")
"
}

insert_task() {
  local group_name="$1" text="$2"
  "$PYTHON_EXEC" -c "
import sys, rehoboam_db
rehoboam_db.add_task(sys.argv[1], sys.argv[2])
" "$group_name" "$text"
}

mark_task_done() {
  local task_id="$1"
  "$PYTHON_EXEC" -c "
import sys, rehoboam_db
rehoboam_db.mark_task_done(int(sys.argv[1]))
" "$task_id"
}

edit_task_text() {
  local task_id="$1" newtext="$2"
  "$PYTHON_EXEC" -c "
import sys, rehoboam_db
rehoboam_db.edit_task_text(int(sys.argv[1]), sys.argv[2])
" "$task_id" "$newtext"
}

delete_task() {
  local task_id="$1"
  "$PYTHON_EXEC" -c "
import sys, rehoboam_db
rehoboam_db.delete_task(int(sys.argv[1]))
" "$task_id"
}

rename_group() {
  local group_id="$1" newname="$2"
  "$PYTHON_EXEC" -c "
import sys, rehoboam_db
rehoboam_db.rename_group(int(sys.argv[1]), sys.argv[2])
" "$group_id" "$newname"
}

delete_group() {
  local group_id="$1"
  "$PYTHON_EXEC" -c "
import sys, rehoboam_db
rehoboam_db.delete_group(int(sys.argv[1]))
" "$group_id"
}

add_group_db() {
  local group_name="$1"
  "$PYTHON_EXEC" -c "
import sys, rehoboam_db
res = rehoboam_db.add_group(sys.argv[1])
sys.exit(0 if res else 1)
" "$group_name"
}

sync_to_daily_note() {
  "$PYTHON_EXEC" -c "
import rehoboam_db
rehoboam_db.sync_to_daily_note()
"
}

sync_daily_notes() {
  sync_to_daily_note "$@"
}

get_timew_status() {
  "$PYTHON_EXEC" -c "
import rehoboam_db
print(rehoboam_db.get_timew_status())
"
}

get_timew_current() {
  "$PYTHON_EXEC" -c "
import rehoboam_db
print(rehoboam_db.get_timew_current_description())
"
}

get_timew_last() {
  "$PYTHON_EXEC" -c "
import rehoboam_db
print(rehoboam_db.get_timew_last_description())
"
}

get_today_summary() {
  "$PYTHON_EXEC" -c "
import rehoboam_db
print(rehoboam_db.get_day_summary())
"
}

get_week_summary() {
  "$PYTHON_EXEC" -c "
import rehoboam_db
print(rehoboam_db.get_week_summary())
"
}

get_task_totals() {
  local task_id="$1"
  "$PYTHON_EXEC" -c "
import sys, rehoboam_db
print(rehoboam_db.format_task_totals(int(sys.argv[1])))
" "$task_id"
}

add_time_manually() {
  local group_name="$1" text="$2" duration="$3"
  timew track "$duration" "$group_name" >/tmp/rehoboam_timew.log 2>&1 || return 1
  timew annotate @1 "$text" >>/tmp/rehoboam_timew.log 2>&1
  sync_to_daily_note
}
