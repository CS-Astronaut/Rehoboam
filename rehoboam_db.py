"""
rehoboam_db.py — SQLite Database Layer & Obsidian Kanban Sync Engine for REHOBOAM.

Manages SQLite database storage (~/.config/rehoboam/rehoboam.db) for tasks and groups,
with bidirectional synchronization to Obsidian's KANBAN.md file and daily note update capabilities.
"""

import os
import re
import sqlite3
import subprocess
from datetime import datetime, timedelta, timezone
from typing import List, Dict, Tuple, Optional

def load_env_config() -> None:
    """Loads KEY=VALUE entries from ~/.config/rehoboam/config into os.environ
    (only for keys not already set by the caller's environment). The file is
    written shell-quoted by rehoboam_config.py, so quotes are stripped here."""
    path = os.path.expanduser("~/.config/rehoboam/config")
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                key = key.strip()
                value = value.strip()
                if len(value) >= 2 and value[0] in "'\"" and value[-1] == value[0]:
                    value = value[1:-1]
                if key and key not in os.environ:
                    os.environ[key] = value
    except OSError:
        pass


load_env_config()

DB_PATH = os.getenv("REHOBOAM_DB_PATH", os.path.expanduser("~/.config/rehoboam/rehoboam.db"))
KANBAN_FILE = os.getenv(
    "KANBAN_FILE",
    os.path.expanduser("~/Obsidian Vault/Computer Science/KANBAN.md")
)
DAILY_NOTES_DIR = os.getenv(
    "DAILY_NOTES_DIR",
    os.path.expanduser("~/Obsidian Vault/Computer Science/999 Daily Notes")
)


def get_db_connection() -> sqlite3.Connection:
    """Returns a SQLite connection with PRAGMA foreign_keys = ON and Row factory."""
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON;")
    return conn


def init_db():
    """Initializes SQLite schema if tables do not exist."""
    with get_db_connection() as conn:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS groups (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT UNIQUE NOT NULL,
                position INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS tasks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                group_id INTEGER NOT NULL,
                description TEXT NOT NULL,
                is_done INTEGER NOT NULL DEFAULT 0,
                position INTEGER NOT NULL DEFAULT 0,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (group_id) REFERENCES groups(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS time_entries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id INTEGER,
                timew_id TEXT,
                start TIMESTAMP NOT NULL,
                end TIMESTAMP NOT NULL,
                duration_seconds INTEGER NOT NULL,
                UNIQUE (start, end),
                FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE SET NULL
            );
        """)

        # Migrate: older schema used timew_id (positional, unstable) as the unique key,
        # which duplicates rows when timew renumbers ids. Derived data — safe to rebuild.
        existing = conn.execute(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'time_entries'"
        ).fetchone()
        if existing and "timew_id TEXT UNIQUE NOT NULL" in existing[0]:
            conn.execute("DROP TABLE time_entries")
            conn.execute("""
                CREATE TABLE time_entries (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    task_id INTEGER,
                    timew_id TEXT,
                    start TIMESTAMP NOT NULL,
                    end TIMESTAMP NOT NULL,
                    duration_seconds INTEGER NOT NULL,
                    UNIQUE (start, end),
                    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE SET NULL
                )
            """)


# ===========================================================================
# Obsidian Markdown <-> SQLite Parsing & Syncing
# ===========================================================================

def parse_kanban_markdown(filepath: str) -> Tuple[List[str], List[Dict]]:
    """
    Parses Obsidian KANBAN.md while preserving header/YAML frontmatter and settings.
    Returns (groups_in_order, list_of_task_dicts).
    """
    if not os.path.exists(filepath):
        return [], []

    with open(filepath, "r", encoding="utf-8") as f:
        lines = f.readlines()

    in_yaml = False
    current_group = None
    groups = []
    tasks = []

    for idx, line in enumerate(lines):
        line_str = line.rstrip("\r\n")

        if idx == 0 and line_str == "---":
            in_yaml = True
            continue
        if in_yaml:
            if line_str == "---":
                in_yaml = False
            continue

        if line_str.startswith("%%"):
            current_group = None
            continue

        if line_str.startswith("## "):
            current_group = line_str[3:].strip()
            if current_group not in groups:
                groups.append(current_group)
            continue

        m = re.match(r"^- \[(.)\] (.*)$", line_str)
        if m and current_group:
            chk, desc = m.groups()
            is_done = 1 if chk.lower() == "x" else 0
            tasks.append({
                "group_name": current_group,
                "description": desc,
                "is_done": is_done
            })

    return groups, tasks


def export_db_to_kanban_markdown(filepath: str):
    """
    Generates updated KANBAN.md content from SQLite database while preserving
    YAML frontmatter and %% kanban:settings footer if present in original file.
    """
    os.makedirs(os.path.dirname(filepath), exist_ok=True)

    yaml_header = "---\n\nkanban-plugin: board\n\n---\n"
    settings_footer = ""

    if os.path.exists(filepath):
        with open(filepath, "r", encoding="utf-8") as f:
            content = f.read()

        yaml_match = re.match(r"^(---\n.*?\n---\n)", content, re.DOTALL)
        if yaml_match:
            yaml_header = yaml_match.group(1)

        settings_match = re.search(r"(%% kanban:settings.*)$", content, re.DOTALL)
        if settings_match:
            settings_footer = settings_match.group(1)

    with get_db_connection() as conn:
        groups = conn.execute("SELECT * FROM groups ORDER BY position ASC, id ASC").fetchall()
        tasks_by_group = {}
        for g in groups:
            tasks = conn.execute(
                "SELECT * FROM tasks WHERE group_id = ? ORDER BY position ASC, id ASC",
                (g["id"],)
            ).fetchall()
            tasks_by_group[g["name"]] = tasks

    out = [yaml_header.strip("\n")]

    for g in groups:
        g_name = g["name"]
        out.append(f"\n## {g_name}\n")
        g_tasks = tasks_by_group.get(g_name, [])
        for t in g_tasks:
            chk = "x" if t["is_done"] else " "
            out.append(f"- [{chk}] {t['description']}")

    out.append("")
    if settings_footer:
        out.append(settings_footer.strip("\n"))
        out.append("")

    new_content = "\n".join(out)
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(new_content)


def sync_kanban_file_to_db(filepath: str = KANBAN_FILE):
    """
    Imports/syncs state from KANBAN.md into SQLite DB.
    If DB is empty, loads file. If both exist, keeps DB schema up to date.
    """
    init_db()
    if not os.path.exists(filepath):
        return

    parsed_groups, parsed_tasks = parse_kanban_markdown(filepath)

    with get_db_connection() as conn:
        db_groups_cnt = conn.execute("SELECT COUNT(*) FROM groups").fetchone()[0]

        if db_groups_cnt == 0:
            for pos, gname in enumerate(parsed_groups):
                cursor = conn.execute(
                    "INSERT INTO groups (name, position) VALUES (?, ?)",
                    (gname, pos)
                )
                gid = cursor.lastrowid
                gtasks = [t for t in parsed_tasks if t["group_name"] == gname]
                for tpos, t in enumerate(gtasks):
                    conn.execute(
                        "INSERT INTO tasks (group_id, description, is_done, position) VALUES (?, ?, ?, ?)",
                        (gid, t["description"], t["is_done"], tpos)
                    )
            conn.commit()


# ===========================================================================
# CRUD Operations (Database + Sync Trigger)
# ===========================================================================

def get_groups() -> List[sqlite3.Row]:
    """Returns all non-'done' groups for menu displays, ordered by position."""
    sync_kanban_file_to_db()
    with get_db_connection() as conn:
        return conn.execute(
            "SELECT * FROM groups WHERE LOWER(name) != 'done' ORDER BY position ASC, id ASC"
        ).fetchall()


def get_all_groups() -> List[sqlite3.Row]:
    """Returns all groups including 'done'."""
    sync_kanban_file_to_db()
    with get_db_connection() as conn:
        return conn.execute("SELECT * FROM groups ORDER BY position ASC, id ASC").fetchall()


def get_open_tasks() -> List[sqlite3.Row]:
    """
    Returns open (is_done=0) tasks from non-'done' groups with group names attached.
    """
    sync_kanban_file_to_db()
    with get_db_connection() as conn:
        return conn.execute("""
            SELECT t.*, g.name as group_name
            FROM tasks t
            JOIN groups g ON t.group_id = g.id
            WHERE t.is_done = 0 AND LOWER(g.name) != 'done'
            ORDER BY g.position ASC, t.position ASC, t.id ASC
        """).fetchall()


def get_all_tasks() -> List[sqlite3.Row]:
    """
    Returns all tasks from non-'done' groups with group names attached.
    """
    sync_kanban_file_to_db()
    with get_db_connection() as conn:
        return conn.execute("""
            SELECT t.*, g.name as group_name
            FROM tasks t
            JOIN groups g ON t.group_id = g.id
            WHERE LOWER(g.name) != 'done'
            ORDER BY g.position ASC, t.position ASC, t.id ASC
        """).fetchall()


def add_task(group_name: str, description: str):
    """Adds a task to the specified group, saves in DB, exports KANBAN.md, syncs Daily Note."""
    with get_db_connection() as conn:
        g = conn.execute("SELECT id FROM groups WHERE name = ?", (group_name,)).fetchone()
        if not g:
            cursor = conn.execute("INSERT INTO groups (name) VALUES (?)", (group_name,))
            group_id = cursor.lastrowid
        else:
            group_id = g["id"]

        max_pos_row = conn.execute(
            "SELECT MAX(position) FROM tasks WHERE group_id = ?", (group_id,)
        ).fetchone()
        next_pos = (max_pos_row[0] + 1) if max_pos_row[0] is not None else 0

        conn.execute(
            "INSERT INTO tasks (group_id, description, is_done, position) VALUES (?, ?, 0, ?)",
            (group_id, description, next_pos)
        )
        conn.commit()

    export_db_to_kanban_markdown(KANBAN_FILE)
    sync_to_daily_note()


def mark_task_done(task_id: int):
    """
    Moves a task to the 'done' group in SQLite DB (creating 'done' group if needed),
    exports KANBAN.md, and syncs Daily Note.
    """
    with get_db_connection() as conn:
        done_group = conn.execute(
            "SELECT id FROM groups WHERE LOWER(name) = 'done'"
        ).fetchone()
        if not done_group:
            cursor = conn.execute("INSERT INTO groups (name, position) VALUES ('done', 9999)")
            done_group_id = cursor.lastrowid
        else:
            done_group_id = done_group["id"]

        conn.execute(
            "UPDATE tasks SET group_id = ?, is_done = 1, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
            (done_group_id, task_id)
        )
        conn.commit()

    export_db_to_kanban_markdown(KANBAN_FILE)
    sync_to_daily_note()


def add_group(group_name: str) -> bool:
    """Creates a new group in DB if not already existing."""
    with get_db_connection() as conn:
        existing = conn.execute("SELECT id FROM groups WHERE name = ?", (group_name,)).fetchone()
        if existing:
            return False

        max_pos = conn.execute("SELECT MAX(position) FROM groups").fetchone()[0]
        next_pos = (max_pos + 1) if max_pos is not None else 0

        conn.execute("INSERT INTO groups (name, position) VALUES (?, ?)", (group_name, next_pos))
        conn.commit()

    export_db_to_kanban_markdown(KANBAN_FILE)
    sync_to_daily_note()
    return True


def edit_task_text(task_id: int, new_text: str):
    """Updates task description in DB."""
    with get_db_connection() as conn:
        conn.execute(
            "UPDATE tasks SET description = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
            (new_text, task_id)
        )
        conn.commit()

    export_db_to_kanban_markdown(KANBAN_FILE)
    sync_to_daily_note()


def move_task(task_id: int, new_group_name: str):
    """Moves a task to the specified group (creating the group if needed)."""
    with get_db_connection() as conn:
        g = conn.execute("SELECT id FROM groups WHERE name = ?", (new_group_name,)).fetchone()
        if not g:
            cursor = conn.execute("INSERT INTO groups (name) VALUES (?)", (new_group_name,))
            new_group_id = cursor.lastrowid
        else:
            new_group_id = g["id"]

        conn.execute(
            "UPDATE tasks SET group_id = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
            (new_group_id, task_id)
        )
        conn.commit()

    export_db_to_kanban_markdown(KANBAN_FILE)
    sync_to_daily_note()


def delete_task(task_id: int):
    """Deletes task from DB."""
    with get_db_connection() as conn:
        conn.execute("DELETE FROM tasks WHERE id = ?", (task_id,))
        conn.commit()

    export_db_to_kanban_markdown(KANBAN_FILE)
    sync_to_daily_note()


def rename_group(group_id: int, new_name: str):
    """Renames group in DB."""
    with get_db_connection() as conn:
        conn.execute("UPDATE groups SET name = ? WHERE id = ?", (new_name, group_id))
        conn.commit()

    export_db_to_kanban_markdown(KANBAN_FILE)
    sync_to_daily_note()


def delete_group(group_id: int):
    """Deletes group and its tasks from DB."""
    with get_db_connection() as conn:
        conn.execute("DELETE FROM groups WHERE id = ?", (group_id,))
        conn.commit()

    export_db_to_kanban_markdown(KANBAN_FILE)
    sync_to_daily_note()


# ===========================================================================
# Daily Note Syncing (TimeWarrior + Database Tasks)
# ===========================================================================

def _parse_timew_ts(ts_str: str) -> Optional[str]:
    """Converts TimeWarrior UTC timestamps (YYYYMMDDTHHMMSSZ) to local 'YYYY-MM-DD HH:MM:SS'."""
    try:
        ts = datetime.strptime(ts_str, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
        return ts.astimezone().strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        return None


def match_task_id(conn: sqlite3.Connection, annotation: str) -> Optional[int]:
    """Finds the single best task for a timew annotation; returns None if no match."""
    ann = re.sub(r"\s*\{[^}]*\}\s*$", "", annotation).strip().lower()
    if not ann:
        return None
    rows = conn.execute("SELECT id, LOWER(description) AS descr FROM tasks").fetchall()
    exact = [r for r in rows if r["descr"] == ann]
    if exact:
        return exact[0]["id"]
    partial = [r for r in rows if r["descr"] and (ann in r["descr"] or r["descr"] in ann)]
    if partial:
        return max(partial, key=lambda r: len(r["descr"]))["id"]
    return None


def import_timew_entries(range_arg: str = ":day") -> int:
    """
    Imports TimeWarrior intervals into time_entries (idempotent via timew_id).
    Intervals whose annotation matches no task are stored with task_id NULL.
    Ongoing intervals (no end) are skipped until stopped. Returns rows inserted.
    """
    init_db()
    try:
        res = subprocess.run(
            ["timew", "export", range_arg],
            capture_output=True, text=True, check=True
        )
        import json
        data = json.loads(res.stdout) if res.stdout.strip() else []
    except Exception:
        return 0

    inserted = 0
    with get_db_connection() as conn:
        for entry in data:
            start_str = entry.get("start")
            end_str = entry.get("end")
            ann = entry.get("annotation", "").strip()
            if not (start_str and end_str and ann):
                continue
            start = _parse_timew_ts(start_str)
            end = _parse_timew_ts(end_str)
            if not (start and end):
                continue
            try:
                dur = int((datetime.strptime(end, "%Y-%m-%d %H:%M:%S")
                           - datetime.strptime(start, "%Y-%m-%d %H:%M:%S")).total_seconds())
            except Exception:
                continue
            if dur <= 0:
                continue
            task_id = match_task_id(conn, ann)
            cur = conn.execute(
                "INSERT OR IGNORE INTO time_entries (task_id, timew_id, start, end, duration_seconds) "
                "VALUES (?, ?, ?, ?, ?)",
                (task_id, str(entry.get("id")), start, end, dur)
            )
            if cur.rowcount > 0:
                inserted += 1
    return inserted


def _get_durations_where(where: str, params: tuple) -> Dict[Optional[int], int]:
    """Aggregates time_entries by task_id for a WHERE clause; unmatched entries keyed None."""
    init_db()
    with get_db_connection() as conn:
        rows = conn.execute(
            f"SELECT task_id, SUM(duration_seconds) AS total FROM time_entries WHERE {where} GROUP BY task_id",
            params
        ).fetchall()
    return {r["task_id"]: int(r["total"]) for r in rows}


def get_durations_for_date(date_str: str) -> Dict[int, int]:
    """Returns {task_id: seconds} aggregated from time_entries for the given date (YYYY-MM-DD)."""
    d = _get_durations_where("date(start) = ?", (date_str,))
    return {k: v for k, v in d.items() if k is not None}


def get_task_total_seconds(task_id: int) -> int:
    """Returns cumulative tracked seconds for a task."""
    init_db()
    with get_db_connection() as conn:
        row = conn.execute(
            "SELECT COALESCE(SUM(duration_seconds), 0) AS total FROM time_entries WHERE task_id = ?",
            (task_id,)
        ).fetchone()
    return int(row["total"])


def format_duration(seconds: int) -> str:
    """'3630' -> '1h 0m', '1500' -> '25m'."""
    seconds = max(int(seconds), 0)
    m = seconds // 60
    h = m // 60
    m = m % 60
    return f"{h}h {m}m" if h > 0 else f"{m}m"


def _build_summary(title: str, durations: Dict[Optional[int], int]) -> str:
    """Builds a human-readable report from {task_id: seconds} (None key = unmatched intervals)."""
    lines = [title]
    if not durations:
        return title + "\n  (no tracked time)"
    total = sum(durations.values())
    matched = {k: v for k, v in durations.items() if k is not None}
    unmatched = durations.get(None, 0)
    if matched:
        with get_db_connection() as conn:
            rows = conn.execute(
                "SELECT t.id, t.description, g.name AS group_name FROM tasks t "
                "JOIN groups g ON t.group_id = g.id "
                "ORDER BY g.position ASC, t.position ASC"
            ).fetchall()
        by_group: Dict[str, List[Tuple[str, int]]] = {}
        for r in rows:
            if r["id"] in matched:
                by_group.setdefault(r["group_name"], []).append((r["description"], matched[r["id"]]))
        for gname, items in by_group.items():
            lines.append(gname)
            for desc, secs in items:
                lines.append(f"  {desc} — {format_duration(secs)}")
    if unmatched:
        lines.append(f"(unmatched intervals) — {format_duration(unmatched)}")
    lines.append(f"Total: {format_duration(total)}")
    return "\n".join(lines)


def get_day_summary(date_str: Optional[str] = None) -> str:
    """Returns a report of tracked time for a date (defaults to today)."""
    date_str = date_str or datetime.now().strftime("%Y-%m-%d")
    import_timew_entries()
    return _build_summary(f"Today — {date_str}", get_durations_for_date(date_str))


def get_week_summary() -> str:
    """Returns a report of tracked time for the last 7 days (including today)."""
    import_timew_entries("7days ago")
    start = (datetime.now() - timedelta(days=6)).strftime("%Y-%m-%d")
    durs = _get_durations_where("date(start) >= ?", (start,))
    return _build_summary(f"Last 7 days (since {start})", durs)


def format_task_totals(task_id: int) -> str:
    """Returns '[group] description — today X — total Y' for a task."""
    init_db()
    with get_db_connection() as conn:
        row = conn.execute(
            "SELECT t.description, g.name AS group_name FROM tasks t "
            "JOIN groups g ON t.group_id = g.id WHERE t.id = ?",
            (task_id,)
        ).fetchone()
    if not row:
        return "(task not found)"
    total = get_task_total_seconds(task_id)
    today = get_durations_for_date(datetime.now().strftime("%Y-%m-%d")).get(task_id, 0)
    parts = [f"[{row['group_name']}] {row['description']}"]
    if today:
        parts.append(f"today {format_duration(today)}")
    parts.append(f"total {format_duration(total)}")
    return " — ".join(parts)


def _describe_interval(entry: dict) -> str:
    """'<tag> — <annotation>' for a TimeWarrior interval (annotation omitted if absent)."""
    tag = (entry.get("tags") or ["?"])[0]
    ann = entry.get("annotation", "").strip()
    return f"{tag} — {ann}" if ann else tag


def get_timew_current_description() -> str:
    """Returns '<tag> — <annotation>' for the running interval, or '' if nothing is tracking."""
    try:
        res = subprocess.run(
            ["timew", "export", ":day"],
            capture_output=True, text=True, check=True
        )
        import json
        data = json.loads(res.stdout) if res.stdout.strip() else []
    except Exception:
        return ""
    for entry in data:
        if not entry.get("end"):
            return _describe_interval(entry)
    return ""


def get_timew_last_description() -> str:
    """Returns '<tag> — <annotation>' for the most recent interval (what `continue` resumes)."""
    try:
        res = subprocess.run(
            ["timew", "export"],
            capture_output=True, text=True, check=True
        )
        import json
        data = json.loads(res.stdout) if res.stdout.strip() else []
    except Exception:
        return ""
    if not data:
        return ""
    latest = sorted(data, key=lambda e: e.get("start", ""))[-1]
    return _describe_interval(latest)


def get_timew_status() -> str:
    """
    Returns a status line for the currently running TimeWarrior interval:
    'Tracking <tag> — <annotation>' plus start time and elapsed duration.
    Returns '' when nothing is tracking.
    """
    try:
        res = subprocess.run(
            ["timew", "export", ":day"],
            capture_output=True, text=True, check=True
        )
        import json
        data = json.loads(res.stdout) if res.stdout.strip() else []
    except Exception:
        return ""
    for entry in data:
        if entry.get("end"):
            continue
        head = f"Tracking {_describe_interval(entry)}"
        start = _parse_timew_ts(entry.get("start", "")) or "?"
        elapsed = 0
        try:
            elapsed = int((datetime.now() - datetime.strptime(start, "%Y-%m-%d %H:%M:%S")).total_seconds())
        except Exception:
            pass
        return f"{head}\n  Started {start}\n  Elapsed {format_duration(elapsed)}"
    return ""


def get_timew_durations_today() -> Dict[int, int]:
    """Imports today's TimeWarrior intervals into the DB and returns {task_id: seconds}."""
    import_timew_entries()
    today = datetime.now().strftime("%Y-%m-%d")
    return get_durations_for_date(today)


def sync_to_daily_note():
    """
    Reads tasks from SQLite DB, checks TimeWarrior annotations, and writes the
    ### To-Do section into current day's daily note in Obsidian.
    """
    import_timew_entries()
    today = datetime.now().strftime("%Y-%m-%d")
    daily_note_path = os.path.join(DAILY_NOTES_DIR, f"{today}.md")
    os.makedirs(DAILY_NOTES_DIR, exist_ok=True)

    tw_durations = get_durations_for_date(today)

    with get_db_connection() as conn:
        groups = conn.execute(
            "SELECT * FROM groups WHERE LOWER(name) NOT IN ('done', 'future') "
            "ORDER BY position ASC, id ASC"
        ).fetchall()
        tasks_by_group = {}
        for g in groups:
            ts = conn.execute(
                "SELECT * FROM tasks WHERE group_id = ? ORDER BY position ASC, id ASC",
                (g["id"],)
            ).fetchall()
            if ts:
                tasks_by_group[g["name"]] = ts

    todo_lines = ["### To-Do"]
    for gname, ts in tasks_by_group.items():
        todo_lines.append(f"- {gname}")
        for t in ts:
            chk = "x" if t["is_done"] else " "
            desc = t["description"]

            best_dur = tw_durations.get(t["id"], 0)

            if best_dur > 0:
                todo_lines.append(f"\t- [{chk}] {desc} {{{format_duration(best_dur)}}}")
            else:
                todo_lines.append(f"\t- [{chk}] {desc}")

    todo_text = "\n".join(todo_lines) + "\n"

    dn_content = ""
    if os.path.exists(daily_note_path):
        with open(daily_note_path, "r", encoding="utf-8") as f:
            dn_content = f.read()

    if not dn_content.strip():
        dn_content = (
            f"---\naliases: []\ntags:\n  - daily\ndate: {today}\nfocus: \"\"\n"
            f"productivity: 0\n---\n\n{todo_text}\n### Note 📝\n- [ ] \n\n---\n"
            f"### 🧠 Journal\n- Thoughts:\n"
        )
    else:
        if re.search(r"###\s+To-?[dD]o", dn_content):
            pattern = r"(###\s+To-?[dD]o.*?\n)(?=\n###|\Z)"
            dn_content = re.sub(pattern, todo_text, dn_content, flags=re.DOTALL)
        else:
            if "### Note" in dn_content:
                dn_content = dn_content.replace("### Note", f"{todo_text}\n### Note")
            elif "### 🧠 Journal" in dn_content:
                dn_content = dn_content.replace("### 🧠 Journal", f"{todo_text}\n### 🧠 Journal")
            else:
                dn_content += f"\n\n{todo_text}"

    with open(daily_note_path, "w", encoding="utf-8") as f:
        f.write(dn_content)


def startup_sync():
    """One-shot sync at startup: KANBAN.md → DB, timew → time_entries, DB → daily note."""
    init_db()
    sync_kanban_file_to_db()
    import_timew_entries()
    sync_to_daily_note()


if __name__ == "__main__":
    init_db()
    sync_kanban_file_to_db()
    print("Database initialized and synced with KANBAN.md.")
