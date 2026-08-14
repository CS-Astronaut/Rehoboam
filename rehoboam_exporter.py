#!/usr/bin/env python3
"""
rehoboam_exporter.py — background state daemon for the HAL-Octopus Plasma widget.

Queries rehoboam_db (SQLite) and TimeWarrior once per second and writes a
structured JSON snapshot to ~/.cache/rehoboam_widget.json for the QML widget
to poll. The write is atomic (tmp file + rename) so a polling reader never
sees a truncated document.

Active interval detection mirrors rehoboam_db.get_timew_current_description()
(logic of _describe_interval) but reads the open interval from a single
`timew export :day` call, which also yields the start timestamp needed for
live elapsed time — one subprocess per tick instead of two.

Run manually, or via ~/.config/autostart/rehoboam-exporter.desktop or a
systemd user unit:

    nohup python3 ~/rehoboam/rehoboam_exporter.py >> /tmp/rehoboam_exporter.log 2>&1 &
"""

import fcntl
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

import rehoboam_db  # noqa: E402

CACHE_FILE = os.path.expanduser("~/.cache/rehoboam_widget.json")
TMP_FILE = CACHE_FILE + ".tmp"
LOCK_FILE = os.path.expanduser("~/.cache/rehoboam_widget.lock")

POLL_SECONDS = 1.0
IMPORT_EVERY_TICKS = 30  # re-import finished timew intervals into the DB
IDLE_RECHECK_TICKS = 3  # while idle, re-check for a new interval every N seconds


def format_run_time(seconds: int) -> str:
    """'3725' -> '1h 2m', '1500' -> '25 min'."""
    seconds = max(int(seconds), 0)
    minutes = seconds // 60
    hours = minutes // 60
    minutes %= 60
    if hours > 0:
        return f"{hours}h {minutes}m"
    return f"{minutes} min"


def fetch_active_interval(export_data):
    """Returns (entry, start_local_str) for the open interval, or (None, None)."""
    for entry in export_data:
        if not entry.get("end"):
            start = rehoboam_db._parse_timew_ts(entry.get("start", ""))
            return entry, start
    return None, None


def match_task_by_group_tag(tasks, tag, annotation):
    """Fallback matcher: group_name must equal the timew tag, description fuzzy."""
    ann = (annotation or "").strip().lower()
    if not ann:
        return None
    candidates = [t for t in tasks if t["group_name"].strip().lower() == (tag or "").strip().lower()]
    for t in candidates:
        desc = (t["description"] or "").strip().lower()
        if desc and (ann in desc or desc in ann):
            return t["id"]
    return None


def build_payload(tasks, active_task_id, today_durs, error=None):
    entries = []
    for t in tasks:
        seconds = int(today_durs.get(t["id"], 0))
        is_active = t["id"] == active_task_id
        entries.append({
            "id": t["id"],
            "description": t["description"],
            "group": t["group_name"],
            "category": "@" + t["group_name"],
            "run_seconds": seconds,
            "run_time": format_run_time(seconds),
            "is_active": is_active,
        })
    payload = {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "active_task_id": active_task_id,
        "error": error,
        "tasks": entries,
    }
    if error is None:
        payload.pop("error")
    return payload


def atomic_write(payload):
    with open(TMP_FILE, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
        f.flush()
        os.fsync(f.fileno())
    os.replace(TMP_FILE, CACHE_FILE)


def read_timew_export():
    res = subprocess.run(
        ["timew", "export", ":day"],
        capture_output=True, text=True, check=True
    )
    data = json.loads(res.stdout) if res.stdout.strip() else []
    return data if isinstance(data, list) else []


def main():
    os.makedirs(os.path.dirname(CACHE_FILE), exist_ok=True)
    rehoboam_db.init_db()

    lock_fd = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("Another rehoboam_exporter instance is already running.", file=sys.stderr)
        return 1

    tick = 0
    last_active_start = ""  # "" forces a full first tick so the cache is seeded
    try:
        while True:
            tick += 1
            # Fully idle: the payload can't change, so only re-check for a new
            # interval occasionally instead of exporting timew every second.
            if last_active_start is None and tick % IDLE_RECHECK_TICKS != 0:
                time.sleep(POLL_SECONDS)
                continue
            error = None
            active_task_id = None
            live_seconds = 0
            tasks = []
            today_durs = {}
            try:
                tasks = list(rehoboam_db.get_open_tasks())
                hidden = rehoboam_db.get_hidden_groups()
                if hidden:
                    tasks = [t for t in tasks if t["group_name"].strip().lower() not in hidden]
                export_data = read_timew_export()
                entry, start_local = fetch_active_interval(export_data)
                if entry is None:
                    if last_active_start is not None:
                        rehoboam_db.import_timew_entries(":day")
                        last_active_start = None
                elif start_local != last_active_start:
                    rehoboam_db.import_timew_entries(":day")
                    last_active_start = start_local
                try:
                    start_dt = datetime.strptime(start_local, "%Y-%m-%d %H:%M:%S")
                    live_seconds = max(int((datetime.now() - start_dt).total_seconds()), 0)
                except Exception:
                    live_seconds = 0
                if entry is not None:
                    with rehoboam_db.get_db_connection() as conn:
                        active_task_id = rehoboam_db.match_task_id(conn, entry.get("annotation", ""))
                    if active_task_id is None:
                        tag = (entry.get("tags") or [None])[0]
                        active_task_id = match_task_by_group_tag(tasks, tag, entry.get("annotation", ""))
                if tick % IMPORT_EVERY_TICKS == 0:
                    rehoboam_db.import_timew_entries(":day")
                today_durs = rehoboam_db.get_durations_for_date(datetime.now().strftime("%Y-%m-%d"))
                if active_task_id is not None:
                    today_durs[active_task_id] = today_durs.get(active_task_id, 0) + live_seconds
            except Exception as exc:  # keep the widget alive on any failure
                error = str(exc)
                tasks = []
                active_task_id = None

            payload = build_payload(tasks, active_task_id, today_durs, error=error)
            atomic_write(payload)
            time.sleep(POLL_SECONDS)
    except KeyboardInterrupt:
        pass
    finally:
        try:
            os.unlink(CACHE_FILE)
        except OSError:
            pass
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        lock_fd.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
