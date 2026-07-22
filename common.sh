#!/usr/bin/env bash
# common.sh — shared config, styling, ASCII banner renderer, and
# KANBAN.md read/write helpers for the REHOBOAM tool suite.
# Sourced by rehoboam.sh, kanban.sh and timew.sh — never run directly.

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
KANBAN_FILE="${KANBAN_FILE:-$HOME/Obsidian Vault/Computer Science/KANBAN.md}"

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

# render_banner WORD — prints a 6-row ASCII block banner for WORD
# (only the letters defined in FONT above are supported; that's every
# letter needed for REHOBOAM, KANBAN and TIMEW)
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

# print_header WORD — clears the screen and shows the boxed ASCII banner.
# Every screen in every script calls this first, so the UI stays consistent.
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
# KANBAN.md helpers
# ---------------------------------------------------------------------------

# Create the vault folder + file with a starter group if they don't exist yet.
ensure_kanban_file() {
  local dir
  dir="$(dirname "$KANBAN_FILE")"
  [ -d "$dir" ] || mkdir -p "$dir"
  [ -f "$KANBAN_FILE" ] || printf '## Inbox\n' >"$KANBAN_FILE"
}

# get_groups FILE — prints "linenum<TAB>group name" for every "## " heading
get_groups() {
  grep -n '^## ' "$1" | sed -E 's/^([0-9]+):## /\1\t/'
}

# get_task_entries FILE — prints "linenum<TAB>group<TAB>full task line"
# for every task line ("- [ ] ..." or "- [x] ...") in the file, done or not.
get_task_entries() {
  awk '
    /^## / { group = substr($0, 4); next }
    /^- \[[ xX]\]/ { print NR "\t" group "\t" $0 }
  ' "$1"
}

# insert_task FILE GROUP TEXT — appends a new "- [ ] TEXT" line at the end
# of GROUP'"'"'s task list (right before the next heading, or EOF).
insert_task() {
  local file="$1" group="$2" text="$3"
  local group_line next_line last_line
  group_line=$(grep -n "^## ${group}\$" "$file" | head -1 | cut -d: -f1)
  next_line=$(awk -v start="$group_line" 'NR>start && /^## /{print NR; exit}' "$file")
  if [ -z "$next_line" ]; then
    last_line=$(awk -v start="$group_line" 'NR>start && NF>0{last=NR} END{print last?last:start}' "$file")
  else
    last_line=$(awk -v start="$group_line" -v end="$next_line" \
      'NR>start && NR<end && NF>0{last=NR} END{print last?last:start}' "$file")
  fi
  awk -v n="$last_line" -v txt="- [ ] ${text}" \
    'NR==n{print; print txt; next}{print}' "$file" >"${file}.tmp" && mv "${file}.tmp" "$file"
}

# mark_task_done FILE LINE — flips "- [ ]" to "- [x]" on LINE
mark_task_done() {
  local file="$1" line="$2"
  awk -v n="$line" 'NR==n{sub(/- \[ \]/,"- [x]")}{print}' "$file" >"${file}.tmp" && mv "${file}.tmp" "$file"
}

# edit_task_text FILE LINE NEWTEXT — replaces task text on LINE, keeping
# its current done/undone checkbox state.
edit_task_text() {
  local file="$1" line="$2" newtext="$3"
  awk -v n="$line" -v txt="$newtext" '
    NR==n {
      state = ($0 ~ /- \[[xX]\]/) ? "x" : " ";
      print "- [" state "] " txt;
      next
    }
    { print }
  ' "$file" >"${file}.tmp" && mv "${file}.tmp" "$file"
}

# rename_group FILE LINE NEWNAME — renames the "## " heading on LINE
rename_group() {
  local file="$1" line="$2" newname="$3"
  awk -v n="$line" -v name="$newname" 'NR==n{print "## " name; next}{print}' \
    "$file" >"${file}.tmp" && mv "${file}.tmp" "$file"
}

# delete_line FILE LINE — removes a single line
delete_line() {
  local file="$1" line="$2"
  awk -v n="$line" 'NR!=n{print}' "$file" >"${file}.tmp" && mv "${file}.tmp" "$file"
}

# delete_range FILE START END — removes lines START..END inclusive
delete_range() {
  local file="$1" start="$2" end="$3"
  awk -v s="$start" -v e="$end" 'NR<s || NR>e{print}' "$file" >"${file}.tmp" && mv "${file}.tmp" "$file"
}

# group_end_line FILE HEADING_LINE — last line belonging to that group
# (the line before the next "## " heading, or EOF if it's the last group)
group_end_line() {
  local file="$1" heading_line="$2" next_line
  next_line=$(awk -v start="$heading_line" 'NR>start && /^## /{print NR; exit}' "$file")
  if [ -z "$next_line" ]; then
    wc -l <"$file"
  else
    echo $((next_line - 1))
  fi
}
