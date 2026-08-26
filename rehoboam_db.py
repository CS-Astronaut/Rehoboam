"""
rehoboam_db.py — SQLite Database Layer for REHOBOAM.

Manages SQLite database storage (~/.config/rehoboam/rehoboam.db) for tasks and groups,
and imports tracked TimeWarrior intervals into the time_entries table.
"""

import json
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

DEFAULT_GROUPS = ("todo", "other")


def get_db_connection() -> sqlite3.Connection:
    """Returns a SQLite connection with WAL, foreign keys and busy timeout."""
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode = WAL;")
    conn.execute("PRAGMA busy_timeout = 3000;")
    conn.execute("PRAGMA foreign_keys = ON;")
    return conn


_INITIALIZED = False


def init_db():
    """Initializes SQLite schema if tables do not exist (once per process)."""
    global _INITIALIZED
    if _INITIALIZED:
        return
    with get_db_connection() as conn:
        user_version = conn.execute("PRAGMA user_version").fetchone()[0]
        if user_version == 0:
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
                    is_postponed INTEGER NOT NULL DEFAULT 0,
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
                CREATE INDEX IF NOT EXISTS idx_time_entries_start ON time_entries(start);
                CREATE INDEX IF NOT EXISTS idx_time_entries_task ON time_entries(task_id);
            """)

            existing = conn.execute("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'time_entries'").fetchone()
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
                conn.execute("CREATE INDEX idx_time_entries_start ON time_entries(start);")
                conn.execute("CREATE INDEX idx_time_entries_task ON time_entries(task_id);")

            cols = {r[1] for r in conn.execute("PRAGMA table_info(tasks)").fetchall()}
            if "is_postponed" not in cols:
                conn.execute("ALTER TABLE tasks ADD COLUMN is_postponed INTEGER NOT NULL DEFAULT 0")
                future_group = conn.execute("SELECT id FROM groups WHERE LOWER(name) = 'future'").fetchone()
                if future_group:
                    conn.execute("UPDATE tasks SET is_postponed = 1 WHERE group_id = ? AND is_done = 0", (future_group["id"],))

            conn.execute("PRAGMA user_version = 1")
            conn.commit()
            user_version = 1

    if user_version == 1:
        conn = get_db_connection()
        conn.execute("PRAGMA foreign_keys = OFF")
        try:
            # Migrate time_entries to UTC and merge overlaps (UNIQUE start)
            rows = conn.execute("SELECT id, task_id, start, end, duration_seconds FROM time_entries").fetchall()
            
            conn.execute("DROP TABLE time_entries")
            conn.execute("""
                CREATE TABLE time_entries (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    task_id INTEGER,
                    start TIMESTAMP NOT NULL UNIQUE,
                    end TIMESTAMP NOT NULL,
                    duration_seconds INTEGER NOT NULL,
                    FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE SET NULL
                )
            """)
            processed_entries = {}
            for r in rows:
                try:
                    start_utc = datetime.strptime(r["start"], "%Y-%m-%d %H:%M:%S").astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
                    end_utc = datetime.strptime(r["end"], "%Y-%m-%d %H:%M:%S").astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
                except Exception:
                    start_utc = r["start"]
                    end_utc = r["end"]
                
                dur = r["duration_seconds"]
                if start_utc not in processed_entries or processed_entries[start_utc]["dur"] < dur:
                    processed_entries[start_utc] = {
                        "id": r["id"], "task_id": r["task_id"], "end": end_utc, "dur": dur
                    }

            for start_utc, d in processed_entries.items():
                conn.execute(
                    "INSERT INTO time_entries (id, task_id, start, end, duration_seconds) VALUES (?, ?, ?, ?, ?)",
                    (d["id"], d["task_id"], start_utc, d["end"], d["dur"])
                )
            conn.execute("CREATE INDEX idx_time_entries_start ON time_entries(start);")
            conn.execute("CREATE INDEX idx_time_entries_task ON time_entries(task_id);")

            # Rebuild groups (NOCASE)
            conn.executescript("""
                CREATE TABLE groups_new (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT UNIQUE COLLATE NOCASE NOT NULL,
                    position INTEGER NOT NULL DEFAULT 0
                );
                INSERT INTO groups_new SELECT id, name, position FROM groups;
                DROP TABLE groups;
                ALTER TABLE groups_new RENAME TO groups;
            """)

            # Fix task positions (grouped by group_id)
            tasks = conn.execute("SELECT id, group_id FROM tasks ORDER BY group_id, position, id").fetchall()
            pos_map = {}
            for t in tasks:
                gid = t["group_id"]
                pos = pos_map.get(gid, 0)
                conn.execute("UPDATE tasks SET position = ? WHERE id = ?", (pos, t["id"]))
                pos_map[gid] = pos + 1

            conn.execute("PRAGMA user_version = 2")
            conn.commit()
            user_version = 2
        finally:
            conn.close()

    ensure_default_groups()
    _INITIALIZED = True


def ensure_default_groups():
    """Seeds DEFAULT_GROUPS into an empty groups table (fresh install)."""
    with get_db_connection() as conn:
        count = conn.execute("SELECT COUNT(*) FROM groups").fetchone()[0]
        if count != 0:
            return
        for position, name in enumerate(DEFAULT_GROUPS):
            conn.execute(
                "INSERT INTO groups (name, position) VALUES (?, ?)",
                (name, position)
            )
        conn.commit()


# ===========================================================================
# CRUD Operations
# ===========================================================================

def get_groups() -> List[sqlite3.Row]:
    """Returns all non-'done' groups for menu displays, ordered by position."""
    init_db()
    with get_db_connection() as conn:
        return conn.execute(
            "SELECT * FROM groups WHERE LOWER(name) != 'done' ORDER BY position ASC, id ASC"
        ).fetchall()


_HIDDEN_CACHE = None  # (config mtime, frozenset) — avoids re-parsing on every exporter tick


def get_hidden_groups() -> set:
    """Returns the set of group names hidden from the octopus widget display.

    Reads HIDDEN_GROUPS (comma-separated, shell-quoted values written by
    rehoboam_config.py) from ~/.config/rehoboam/config, cached by file mtime so
    the exporter picks up dialog changes (config rewrites bump the mtime).
    Matching is case-insensitive; a missing key or file yields an empty set.
    """
    global _HIDDEN_CACHE
    path = os.path.expanduser("~/.config/rehoboam/config")
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        _HIDDEN_CACHE = None
        return set()
    if _HIDDEN_CACHE is not None and _HIDDEN_CACHE[0] == mtime:
        return set(_HIDDEN_CACHE[1])
    hidden = set()
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                if key.strip() != "HIDDEN_GROUPS":
                    continue
                value = value.strip()
                if len(value) >= 2 and value[0] in "'\"" and value[-1] == value[0]:
                    value = value[1:-1]
                hidden = {g.strip().lower() for g in value.split(",") if g.strip()}
                break
    except OSError:
        hidden = set()
    _HIDDEN_CACHE = (mtime, frozenset(hidden))
    return hidden


_BOARD_SETTINGS_CACHE = None  # (config mtime, dict) — avoids re-parsing on every exporter tick

# Normalized defaults; raw keys parsed from ~/.config/rehoboam/config:
#   POSTPONE_HOURS -> 'postpone_hours', LIFELINE_MINUTES -> 'lifeline_minutes'
_BOARD_SETTING_DEFAULTS = {"postpone_hours": 24.0, "lifeline_minutes": 5}


def get_board_settings() -> Dict[str, float]:
    """Returns dead-man-switch settings from ~/.config/rehoboam/config.

    POSTPONE_HOURS — hours without activity before an open task is auto-flagged
    as postponed (default 24, 0 disables). LIFELINE_MINUTES — refresh
    step of the widget lifeline in minutes (default 5). Cached by file mtime
    like get_hidden_groups(); unknown or invalid values fall back to defaults.
    """
    global _BOARD_SETTINGS_CACHE
    path = os.path.expanduser("~/.config/rehoboam/config")
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return dict(_BOARD_SETTING_DEFAULTS)
    if _BOARD_SETTINGS_CACHE is not None and _BOARD_SETTINGS_CACHE[0] == mtime:
        return dict(_BOARD_SETTINGS_CACHE[1])
    values: Dict[str, float] = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                key = key.strip()
                if key not in ("POSTPONE_HOURS", "LIFELINE_MINUTES"):
                    continue
                value = value.strip()
                if len(value) >= 2 and value[0] in "'\"" and value[-1] == value[0]:
                    value = value[1:-1]
                try:
                    values[key] = float(value)
                except ValueError:
                    pass
    except OSError:
        values = {}
    settings = {
        "postpone_hours": max(values.get("POSTPONE_HOURS",
                                         _BOARD_SETTING_DEFAULTS["postpone_hours"]), 0.0),
        "lifeline_minutes": max(int(values.get("LIFELINE_MINUTES",
                                               _BOARD_SETTING_DEFAULTS["lifeline_minutes"])), 1),
    }
    _BOARD_SETTINGS_CACHE = (mtime, dict(settings))
    return settings


def get_all_groups() -> List[sqlite3.Row]:
    """Returns all groups including 'done'."""
    init_db()
    with get_db_connection() as conn:
        return conn.execute("SELECT * FROM groups ORDER BY position ASC, id ASC").fetchall()


def get_open_tasks() -> List[sqlite3.Row]:
    """
    Returns active (is_done=0, is_postponed=0) tasks with group names attached.
    """
    init_db()
    with get_db_connection() as conn:
        return conn.execute("""
            SELECT t.*, g.name as group_name
            FROM tasks t
            JOIN groups g ON t.group_id = g.id
            WHERE t.is_done = 0 AND t.is_postponed = 0
            ORDER BY g.position ASC, t.position ASC, t.id ASC
        """).fetchall()


def get_all_tasks() -> List[sqlite3.Row]:
    """
    Returns all non-done tasks (including postponed) with group names attached.
    """
    init_db()
    with get_db_connection() as conn:
        return conn.execute("""
            SELECT t.*, g.name as group_name
            FROM tasks t
            JOIN groups g ON t.group_id = g.id
            WHERE t.is_done = 0
            ORDER BY g.position ASC, t.position ASC, t.id ASC
        """).fetchall()


def add_task(group_name: str, description: str):
    """Adds a task to the specified group in the DB; returns the new task id."""
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

        cursor = conn.execute(
            "INSERT INTO tasks (group_id, description, is_done, position) VALUES (?, ?, 0, ?)",
            (group_id, description, next_pos)
        )
        conn.commit()
        return cursor.lastrowid


def mark_task_done(task_id: int):
    """
    Marks a task as done (preserves original group_id as the task's tag).
    """
    with get_db_connection() as conn:
        conn.execute(
            "UPDATE tasks SET is_done = 1, is_postponed = 0, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
            (task_id,)
        )
        conn.commit()


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
    return True


def edit_task_text(task_id: int, new_text: str):
    """Updates task description in DB."""
    with get_db_connection() as conn:
        conn.execute(
            "UPDATE tasks SET description = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
            (new_text, task_id)
        )
        conn.commit()


def move_task(task_id: int, new_group_name: str):
    """Moves a task to the specified group (creating the group if needed).
    Also clears the postponed flag (rescuing a postponed task)."""
    with get_db_connection() as conn:
        g = conn.execute("SELECT id FROM groups WHERE name = ?", (new_group_name,)).fetchone()
        if not g:
            max_gpos = conn.execute("SELECT MAX(position) FROM groups").fetchone()[0]
            next_gpos = (max_gpos + 1) if max_gpos is not None else 0
            cursor = conn.execute("INSERT INTO groups (name, position) VALUES (?, ?)", (new_group_name, next_gpos))
            new_group_id = cursor.lastrowid
        else:
            new_group_id = g["id"]

        max_pos_row = conn.execute(
            "SELECT MAX(position) FROM tasks WHERE group_id = ?", (new_group_id,)
        ).fetchone()
        next_pos = (max_pos_row[0] + 1) if max_pos_row[0] is not None else 0

        conn.execute(
            "UPDATE tasks SET group_id = ?, position = ?, is_postponed = 0, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
            (new_group_id, next_pos, task_id)
        )
        conn.commit()


def delete_task(task_id: int):
    """Deletes task from DB."""
    with get_db_connection() as conn:
        conn.execute("DELETE FROM tasks WHERE id = ?", (task_id,))
        conn.commit()


def rename_group(group_id: int, new_name: str):
    """Renames group in DB."""
    with get_db_connection() as conn:
        conn.execute("UPDATE groups SET name = ? WHERE id = ?", (new_name, group_id))
        conn.commit()


def delete_group(group_id: int):
    """Deletes group and its tasks from DB."""
    with get_db_connection() as conn:
        conn.execute("DELETE FROM groups WHERE id = ?", (group_id,))
        conn.commit()


def unpostpone_task(task_id: int):
    """Clears the postponed flag on a task (rescuing it back to active).
    Refreshes updated_at so the dead-man switch countdown restarts."""
    with get_db_connection() as conn:
        conn.execute(
            "UPDATE tasks SET is_postponed = 0, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
            (task_id,)
        )
        conn.commit()


def postpone_task(task_id: int):
    """Manually marks a single task as postponed (preserves original group_id).
    Refreshes updated_at."""
    with get_db_connection() as conn:
        conn.execute(
            "UPDATE tasks SET is_postponed = 1, updated_at = CURRENT_TIMESTAMP WHERE id = ?",
            (task_id,)
        )
        conn.commit()


def get_postponed_tasks() -> List[sqlite3.Row]:
    """Returns postponed (is_postponed=1, is_done=0) tasks with group names."""
    init_db()
    with get_db_connection() as conn:
        return conn.execute("""
            SELECT t.*, g.name as group_name
            FROM tasks t
            JOIN groups g ON t.group_id = g.id
            WHERE t.is_done = 0 AND t.is_postponed = 1
            ORDER BY g.position ASC, t.position ASC, t.id ASC
        """).fetchall()


# ===========================================================================
# Dead-Man Switch (auto-postpone)
# ===========================================================================

def get_task_activity() -> Dict[int, float]:
    """Returns {task_id: baseline_epoch} for open tasks: the newest of creation,
    last update (move/rename) and last tracked-interval end.

    All timestamps (created_at, updated_at, last_end) are UTC strings.
    """
    init_db()
    out: Dict[int, float] = {}
    with get_db_connection() as conn:
        rows = conn.execute("""
            SELECT t.id AS id, t.created_at AS created_at,
                   t.updated_at AS updated_at, MAX(te.end) AS last_end
            FROM tasks t
            LEFT JOIN time_entries te ON te.task_id = t.id
            WHERE t.is_done = 0
            GROUP BY t.id
        """).fetchall()
    for r in rows:
        stamps = []
        for raw in (r["created_at"], r["updated_at"], r["last_end"]):
            if not raw:
                continue
            try:
                dt = datetime.strptime(str(raw), "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
                stamps.append(dt.timestamp())
            except ValueError:
                continue
        if stamps:
            out[r["id"]] = max(stamps)
    return out


def postpone_stale_tasks(max_hours: float, active_task_id: Optional[int] = None) -> List[int]:
    """Dead-man switch: marks stale open tasks as postponed.

    A task is stale when now - baseline exceeds max_hours hours (baseline per
    get_task_activity); the currently tracked task never goes stale. The flag
    change refreshes updated_at, so unpostponing a task starts a fresh
    countdown instead of being bounced right back. Returns the postponed
    task ids.
    """
    if max_hours <= 0:
        return []
    init_db()
    activity = get_task_activity()
    cutoff = datetime.now().timestamp() - max_hours * 3600
    with get_db_connection() as conn:
        rows = conn.execute("""
            SELECT t.id FROM tasks t
            WHERE t.is_done = 0 AND t.is_postponed = 0
        """).fetchall()
        stale = [r["id"] for r in rows
                 if r["id"] != active_task_id and activity.get(r["id"], 0.0) < cutoff]
        if not stale:
            return []
        placeholders = ",".join("?" * len(stale))
        conn.execute(
            f"UPDATE tasks SET is_postponed = 1, updated_at = CURRENT_TIMESTAMP "
            f"WHERE id IN ({placeholders})",
            stale
        )
        conn.commit()
    return stale


# ===========================================================================
# TimeWarrior Import & Reports
# ===========================================================================

def _parse_timew_ts(ts_str: str) -> Optional[str]:
    """Converts TimeWarrior UTC timestamps (YYYYMMDDTHHMMSSZ) to standard UTC 'YYYY-MM-DD HH:MM:SS'."""
    try:
        ts = datetime.strptime(ts_str, "%Y%m%dT%H%M%SZ")
        return ts.strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        return None


def match_task_id(conn: sqlite3.Connection, annotation: str, tags: List[str] = None) -> Optional[int]:
    """Finds the single best task for a timew annotation/tags; returns None if no match."""
    ann = re.sub(r"\s*\{[^}]*\}\s*$", "", annotation).strip().lower()
    
    rows = conn.execute("SELECT t.id, LOWER(t.description) AS descr, LOWER(g.name) AS gname "
                        "FROM tasks t JOIN groups g ON t.group_id = g.id").fetchall()
    
    candidates = rows
    if tags:
        tag_lower = [t.lower() for t in tags]
        group_matches = [r for r in rows if r["gname"] in tag_lower]
        if group_matches:
            candidates = group_matches
            
    if not ann:
        if len(candidates) == 1:
            return candidates[0]["id"]
        return None

    def find_match(cands):
        exact = [r for r in cands if r["descr"] == ann]
        if exact:
            return exact[0]["id"]
        partial = [r for r in cands if r["descr"] and (ann in r["descr"] or r["descr"] in ann)]
        if partial:
            return max(partial, key=lambda r: len(r["descr"]))["id"]
        return None

    match = find_match(candidates)
    if match is not None:
        return match
    
    if candidates != rows:
        return find_match(rows)
        
    return None


def import_timew_entries(range_arg: str = ":day") -> int:
    """
    Imports TimeWarrior intervals into time_entries.
    Intervals whose annotation matches no task are stored with task_id NULL.
    Ongoing intervals (no end) are skipped until stopped. Returns rows inserted.
    """
    init_db()
    try:
        res = subprocess.run(
            ["timew", "export", range_arg],
            capture_output=True, text=True, check=True
        )
        data = json.loads(res.stdout) if res.stdout.strip() else []
    except Exception:
        return 0

    inserted = 0
    with get_db_connection() as conn:
        processed_entries = {}
        for entry in data:
            start_str = entry.get("start")
            end_str = entry.get("end")
            ann = entry.get("annotation", "").strip()
            tags = entry.get("tags", [])
            if not (start_str and end_str):
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
            
            if start not in processed_entries or processed_entries[start]["dur"] < dur:
                processed_entries[start] = {
                    "end": end,
                    "dur": dur,
                    "ann": ann,
                    "tags": tags
                }
                
        for start, entry_data in processed_entries.items():
            task_id = match_task_id(conn, entry_data["ann"], entry_data["tags"])
            cur = conn.execute(
                "INSERT OR IGNORE INTO time_entries (task_id, start, end, duration_seconds) "
                "VALUES (?, ?, ?, ?)",
                (task_id, start, entry_data["end"], entry_data["dur"])
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
    local_start = datetime.strptime(date_str, "%Y-%m-%d").astimezone()
    local_end = local_start + timedelta(days=1)
    
    utc_start = local_start.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    utc_end = local_end.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    
    d = _get_durations_where("start >= ? AND start < ?", (utc_start, utc_end))
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
    local_start = (datetime.now().astimezone() - timedelta(days=6)).replace(hour=0, minute=0, second=0, microsecond=0)
    utc_start = local_start.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    durs = _get_durations_where("start >= ?", (utc_start,))
    start_str = local_start.strftime("%Y-%m-%d")
    return _build_summary(f"Last 7 days (since {start_str})", durs)


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
        data = json.loads(res.stdout) if res.stdout.strip() else []
    except Exception:
        return ""
    for entry in data:
        if entry.get("end"):
            continue
        head = f"Tracking {_describe_interval(entry)}"
        start = _parse_timew_ts(entry.get("start", ""))
        if not start:
            start = "?"
            elapsed = 0
            local_start = "?"
        else:
            try:
                start_dt = datetime.strptime(start, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
                elapsed = int((datetime.now(timezone.utc) - start_dt).total_seconds())
                local_start = start_dt.astimezone().strftime("%Y-%m-%d %H:%M:%S")
            except Exception:
                elapsed = 0
                local_start = start
        return f"{head}\n  Started {local_start}\n  Elapsed {format_duration(elapsed)}"
    return ""


def get_timew_durations_today() -> Dict[int, int]:
    """Imports today's TimeWarrior intervals into the DB and returns {task_id: seconds}."""
    import_timew_entries()
    today = datetime.now().strftime("%Y-%m-%d")
    return get_durations_for_date(today)


def startup_sync():
    """One-shot sync at startup: init DB and import timew → time_entries."""
    init_db()
    import_timew_entries()


if __name__ == "__main__":
    init_db()
    import_timew_entries()
    print("Database initialized.")
