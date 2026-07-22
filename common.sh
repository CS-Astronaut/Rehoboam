#!/usr/bin/env bash
# common.sh — shared config, styling, ASCII banner renderer, and
# KANBAN.md read/write helpers for the REHOBOAM tool suite.
# Sourced by rehoboam.sh, kanban.sh and timew.sh — never run directly.

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

# get_groups FILE — prints "linenum<TAB>group name" for every "## " heading, skipping "done" (case-insensitive)
get_groups() {
  grep -n '^## ' "$1" | awk -F: '$2 !~ /^## [dD][oO][nN][eE][[:space:]]*$/ { print $1 "\t" substr($2, 4) }'
}

# get_task_entries FILE — prints "linenum<TAB>group<TAB>full task line"
# for every task line ("- [ ] ..." or "- [x] ...") in the file, done or not,
# excluding tasks under the "done" group (case-insensitive).
get_task_entries() {
  awk '
    /^## / { group = substr($0, 4); next }
    tolower(group) == "done" { next }
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

  # Auto-sync to daily notes
  sync_daily_notes
}

# mark_task_done FILE LINE — moves the task on LINE to the "done" section
# instead of ticking [x]. If no "## done" heading exists, it is created.
mark_task_done() {
  local file="$1" line="$2"
  
  # Extract the line content
  local task_line
  task_line=$(awk -v n="$line" 'NR==n{print}' "$file")
  [ -z "$task_line" ] && return 1

  # Delete original line
  delete_line "$file" "$line"

  # Ensure "## done" section exists or locate it (case-insensitive)
  local done_line
  done_line=$(grep -n -i '^## done[[:space:]]*$' "$file" | head -1 | cut -d: -f1)

  if [ -z "$done_line" ]; then
    # Add ## done section if missing
    # Check if file ends with newline or content
    if [ -s "$file" ]; then
      printf '\n## done\n%s\n' "$task_line" >>"$file"
    else
      printf '## done\n%s\n' "$task_line" >>"$file"
    fi
  else
    # Append task under the existing "## done" heading
    local next_line last_line
    next_line=$(awk -v start="$done_line" 'NR>start && /^## /{print NR; exit}' "$file")
    if [ -z "$next_line" ]; then
      last_line=$(awk -v start="$done_line" 'NR>start && NF>0{last=NR} END{print last?last:start}' "$file")
    else
      last_line=$(awk -v start="$done_line" -v end="$next_line" \
        'NR>start && NR<end && NF>0{last=NR} END{print last?last:start}' "$file")
    fi
    awk -v n="$last_line" -v txt="$task_line" \
      'NR==n{print; print txt; next}{print}' "$file" >"${file}.tmp" && mv "${file}.tmp" "$file"
  fi

  # Auto-sync to daily notes
  sync_daily_notes
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

  # Auto-sync to daily notes
  sync_daily_notes
}

# rename_group FILE LINE NEWNAME — renames the "## " heading on LINE
rename_group() {
  local file="$1" line="$2" newname="$3"
  awk -v n="$line" -v name="$newname" 'NR==n{print "## " name; next}{print}' \
    "$file" >"${file}.tmp" && mv "${file}.tmp" "$file"

  # Auto-sync to daily notes
  sync_daily_notes
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

# group_end_line FILE STARTLINE — returns the last line of the group that starts at STARTLINE
# The group ends right before the next ## heading, or at EOF.
group_end_line() {
  local file="$1" start="$2"
  local next_Heading
  next_Heading=$(awk -v start="$start" 'NR>start && /^## /{print NR; exit}' "$file")
  if [ -z "$next_Heading" ]; then
    awk 'END{print NR}' "$file"
  else
    echo $((next_Heading - 1))
  fi
}

# sync_to_daily_note — updates/replaces the "### To-Do" section in current day's daily note
# with current KANBAN.md groups/tasks + time tracked from `timew summary :day`.
sync_to_daily_note() {
  ensure_kanban_file
  local today daily_note timew_raw
  today="$(date +%Y-%m-%d)"
  daily_note="${DAILY_NOTES_DIR}/${today}.md"

  # Ensure daily notes directory exists
  mkdir -p "$DAILY_NOTES_DIR"

  timew_raw=$(timew export :day 2>/dev/null || echo "[]")

  awk -v timew_json="$timew_raw" -v kanban_file="$KANBAN_FILE" -v daily_note="$daily_note" -v today="$today" '
  BEGIN {
    # --- Step A: Parse TIMEW_JSON ---
    gsub(/\} *, *\{/, "}\n{", timew_json)
    n_tw = split(timew_json, tw_lines, "\n")
    for (i = 1; i <= n_tw; i++) {
      line = tw_lines[i]
      match(line, /"start":"([^"]+)"/, m_start)
      match(line, /"end":"([^"]+)"/, m_end)
      start_str = m_start[1]
      end_str = m_end[1]
      
      if (start_str != "" && end_str != "") {
        sh=substr(start_str,10,2); smin=substr(start_str,12,2); ss=substr(start_str,14,2)
        eh=substr(end_str,10,2); emin=substr(end_str,12,2); es=substr(end_str,14,2)
        dur = (eh*3600 + emin*60 + es) - (sh*3600 + smin*60 + ss)
        if (dur < 0) dur += 86400

        match(line, /"annotation":"([^"]*)"/, m_ann)
        ann_str = m_ann[1]

        ann_clean = tolower(ann_str)
        gsub(/^[ \t]+|[ \t]+$/, "", ann_clean)
        if (ann_clean != "") tw_durations[ann_clean] += dur
      }
    }

    # --- Step B: Parse KANBAN_FILE ---
    group_count = 0
    current_grp = ""
    while ((getline line < kanban_file) > 0) {
      gsub(/\r/, "", line)
      if (line ~ /^## /) {
        grp = substr(line, 4)
        gsub(/^[ \t]+|[ \t]+$/, "", grp)
        if (tolower(grp) == "done") {
          current_grp = ""
        } else {
          current_grp = grp
          if (!(current_grp in grp_seen)) {
            grp_seen[current_grp] = 1
            group_count++
            groups[group_count] = current_grp
            task_count[current_grp] = 0
          }
        }
      } else if (current_grp != "" && line ~ /^- \[[ xX]\]/) {
        tc = task_count[current_grp] + 1
        task_count[current_grp] = tc
        tasks[current_grp, tc] = line
      }
    }
    close(kanban_file)

    # --- Step C: Build To-Do section ---
    todo_text = "### To-Do\n"
    for (i = 1; i <= group_count; i++) {
      grp = groups[i]
      tc = task_count[grp]
      if (tc > 0) {
        todo_text = todo_text "- " grp "\n"
        for (j = 1; j <= tc; j++) {
          tline = tasks[grp, j]
          match(tline, /^- \[(.)\] (.*)$/, m_task)
          chk = m_task[1]
          desc = m_task[2]
          desc_lower = tolower(desc)
          sub(/[ \t]*\{[^}]*\}\s*$/, "", desc_lower)
          gsub(/^[ \t]+|[ \t]+$/, "", desc_lower)

          # Sum time for all annotations matching this task (partial match on either side)
          best_dur = 0
          for (ann_key in tw_durations) {
            if (ann_key != "" && (index(ann_key, desc_lower) > 0 || index(desc_lower, ann_key) > 0)) {
              best_dur += tw_durations[ann_key]
            }
          }

          if (best_dur > 0) {
            m = int(best_dur / 60)
            h = int(m / 60)
            m = m % 60
            if (h > 0) {
              time_spent = (m > 0) ? h "h " m "m" : h "h"
            } else {
              time_spent = m "m"
            }
            todo_text = todo_text "\t- [" chk "] " desc " {" time_spent "}\n"
          } else {
            todo_text = todo_text "\t- [" chk "] " desc "\n"
          }
        }
      }
    }

    # --- Step D: Read existing Daily Note or create default ---
    dn_content = ""
    while ((getline line < daily_note) > 0) {
      dn_content = dn_content line "\n"
    }
    close(daily_note)

    if (dn_content == "") {
      dn_content = "---\naliases: []\ntags:\n  - daily\ndate: " today "\nfocus: \"\"\nproductivity: 0\n---\n\n" todo_text "\n### Note 📝\n- [ ] \n\n---\n### 🧠 Journal\n- Thoughts:\n"
    } else {
      # Replace existing ### To-Do or ### To Do section
      if (dn_content ~ /###[ \t]+To-?[dD]o/) {
        idx = match(dn_content, /###[ \t]+To-?[dD]o[^\n]*/)
        before = substr(dn_content, 1, idx - 1)
        rest = substr(dn_content, idx)
        
        idx_next = match(substr(rest, 10), /\n###[ \t]+/)
        if (idx_next > 0) {
          after = substr(rest, idx_next + 9)
          dn_content = before todo_text "\n" after
        } else {
          dn_content = before todo_text
        }
      } else {
        if (index(dn_content, "### Note") > 0) {
          sub(/### Note/, todo_text "\n### Note", dn_content)
        } else if (index(dn_content, "### 🧠 Journal") > 0) {
          sub(/### 🧠 Journal/, todo_text "\n### 🧠 Journal", dn_content)
        } else {
          dn_content = dn_content "\n\n" todo_text
        }
      }
    }

    printf "%s", dn_content > daily_note
    close(daily_note)
  }
  '
}

# Alias sync_daily_notes to sync_to_daily_note for backward compatibility
sync_daily_notes() {
  sync_to_daily_note "$@"
}
