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

DEFAULT_GROUPS = ("todo", "other", "future")


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

            CREATE INDEX IF NOT EXISTS idx_time_entries_start ON time_entries(start);
            CREATE INDEX IF NOT EXISTS idx_time_entries_task ON time_entries(task_id);
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
            conn.execute("CREATE INDEX idx_time_entries_start ON time_entries(start);")
            conn.execute("CREATE INDEX idx_time_entries_task ON time_entries(task_id);")

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

    POSTPONE_HOURS — hours without activity before an open task auto-moves to
    the 'future' group (default 24, 0 disables). LIFELINE_MINUTES — refresh
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
    Returns open (is_done=0) tasks from non-'done' groups with group names attached.
    """
    init_db()
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
    init_db()
    with get_db_connection() as conn:
        return conn.execute("""
            SELECT t.*, g.name as group_name
            FROM tasks t
            JOIN groups g ON t.group_id = g.id
            WHERE LOWER(g.name) != 'done'
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
    Moves a task to the 'done' group in SQLite DB (creating 'done' group if needed).
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


# ===========================================================================
# Dead-Man Switch (auto-postpone)
# ===========================================================================

def get_task_activity() -> Dict[int, float]:
    """Returns {task_id: baseline_epoch} for open tasks: the newest of creation,
    last update (move/rename) and last tracked-interval end.

    tasks.created_at / updated_at come from SQLite CURRENT_TIMESTAMP and are
    UTC, while time_entries timestamps are local strings — both are normalized
    to local epochs here so they can be compared safely.
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
        for raw, is_utc in ((r["created_at"], True), (r["updated_at"], True), (r["last_end"], False)):
            if not raw:
                continue
            try:
                dt = datetime.strptime(str(raw), "%Y-%m-%d %H:%M:%S")
                if is_utc:
                    dt = dt.replace(tzinfo=timezone.utc).astimezone()
                stamps.append(dt.timestamp())
            except ValueError:
                continue
        if stamps:
            out[r["id"]] = max(stamps)
    return out


def postpone_stale_tasks(max_hours: float, active_task_id: Optional[int] = None) -> List[int]:
    """Dead-man switch: moves stale open tasks into the 'future' group.

    A task is stale when now - baseline exceeds max_hours hours (baseline per
    get_task_activity); the currently tracked task never goes stale. The move
    itself refreshes updated_at, so manually rescuing a task from 'future'
    starts a fresh countdown instead of being bounced right back. Returns the
    moved task ids.
    """
    if max_hours <= 0:
        return []
    init_db()
    activity = get_task_activity()
    cutoff = datetime.now().timestamp() - max_hours * 3600
    with get_db_connection() as conn:
        rows = conn.execute("""
            SELECT t.id FROM tasks t
            JOIN groups g ON t.group_id = g.id
            WHERE t.is_done = 0 AND LOWER(g.name) != 'future'
        """).fetchall()
        stale = [r["id"] for r in rows
                 if r["id"] != active_task_id and activity.get(r["id"], 0.0) < cutoff]
        if not stale:
            return []
        group = conn.execute("SELECT id FROM groups WHERE name = 'future'").fetchone()
        if not group:
            conn.execute("INSERT INTO groups (name) VALUES ('future')")
            group = conn.execute("SELECT id FROM groups WHERE name = 'future'").fetchone()
        placeholders = ",".join("?" * len(stale))
        conn.execute(
            f"UPDATE tasks SET group_id = ?, updated_at = CURRENT_TIMESTAMP "
            f"WHERE id IN ({placeholders})",
            [group["id"]] + stale
        )
        conn.commit()
    return stale


# ===========================================================================
# TimeWarrior Import & Reports
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
    start = date_str + " 00:00:00"
    end = (datetime.strptime(date_str, "%Y-%m-%d") + timedelta(days=1)).strftime("%Y-%m-%d 00:00:00")
    d = _get_durations_where("start >= ? AND start < ?", (start, end))
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


def startup_sync():
    """One-shot sync at startup: init DB and import timew → time_entries."""
    init_db()
    import_timew_entries()


if __name__ == "__main__":
    init_db()
    import_timew_entries()
    print("Database initialized.")
