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

Each tick also enforces the dead-man switch: open tasks whose newest activity
(creation, tracking end, or manual move/rename) is older than POSTPONE_HOURS
are flagged as postponed (is_postponed=1) while preserving their original
group tag, and reported on stdout. Postponed tasks never reach the widget
payload (only a postponed_count badge) — they live on the kanban Postponed
Shelf until rescued from the TUI, or until the user starts tracking one,
which auto-rescues it with a fresh countdown.

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
TMP_FILE = CACHE_FILE + f".{os.getpid()}.tmp"
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
    """Returns (entry, start_utc_str) for the open interval, or (None, None)."""
    for entry in export_data:
        if not entry.get("end"):
            start = rehoboam_db._parse_timew_ts(entry.get("start", ""))
            return entry, start
    return None, None


def compute_lifelines(tasks, baselines, active_task_id, postpone_hours, lifeline_minutes):
    """Returns {task_id: (ratio, '3h 20m')} for the time left before auto-postpone.

    Remaining time is quantized down to lifeline_minutes steps so the widget's
    lifeline ticks calmly instead of draining every second; the tracked task is
    always full (baseline = now). Postponed tasks report 0 (empty
    line) so their cards stay visually consistent.
    """
    total = max(float(postpone_hours), 0.0) * 3600.0
    step = max(int(lifeline_minutes), 1) * 60.0
    now = datetime.now().timestamp()
    life = {}
    if total <= 0:
        return life
    for t in tasks:
        is_postponed = bool(t["is_postponed"])
        base = baselines.get(t["id"])
        elapsed = max(now - base, 0.0) if base is not None else 0.0
        if t["id"] == active_task_id:
            elapsed = 0.0
        remaining = min(max(total - elapsed, 0.0), total)
        if is_postponed or remaining <= 0:
            life[t["id"]] = (0.0, "0m")
            continue
        quantized_elapsed = float(int(elapsed // step) * step)
        q_remaining = min(max(total - quantized_elapsed, 0.0), total)
        life[t["id"]] = (q_remaining / total, format_run_time(int(q_remaining)))
    return life


def build_payload(tasks, active_task_id, today_durs, tracking, error=None, life=None,
                  postponed_count=0):
    """life: None (feature off) or {'postpone_hours': h, 'life': {id: (ratio, txt)}}.

    tasks must already be filtered: postponed rows stay off the eye and are
    only reflected in the postponed_count badge on the payload.
    """
    entries = []
    for t in tasks:
        seconds = int(today_durs.get(t["id"], 0))
        is_active = t["id"] == active_task_id
        entry = {
            "id": t["id"],
            "description": t["description"],
            "group": t["group_name"],
            "category": "@" + t["group_name"],
            "is_postponed": bool(t["is_postponed"]),
            "run_seconds": seconds,
            "run_time": format_run_time(seconds),
            "is_active": is_active,
        }
        if life is not None:
            ratio, life_time = life["life"].get(t["id"], (0.0, "0m"))
            entry["life_ratio"] = round(ratio, 4)
            entry["life_time"] = life_time
        entries.append(entry)
    payload = {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "active_task_id": active_task_id,
        "tracking": tracking,
        "postpone_hours": life["postpone_hours"] if life else 0,
        "postponed_count": postponed_count,
        "tasks": entries,
    }
    if error is not None:
        payload["error"] = error
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


def build_snapshot(export_data=None):
    """Assemble the widget payload from the DB and TimeWarrior, and write it.

    Used by the daemon loop once per tick, and by rehoboam_config.py right
    after a DB mutation so the widget refreshes instantly instead of waiting
    for the next tick.
    """
    if export_data is None:
        export_data = read_timew_export()
    tasks = list(rehoboam_db.get_all_tasks())
    hidden = rehoboam_db.get_hidden_groups()
    if hidden:
        tasks = [t for t in tasks if t["group_name"].strip().lower() not in hidden]
    entry, start_utc = fetch_active_interval(export_data)
    tracking = entry is not None
    live_seconds = 0
    active_task_id = None
    if entry is not None:
        with rehoboam_db.get_db_connection() as conn:
            tags = entry.get("tags", [])
            active_task_id = rehoboam_db.match_task_id(conn, entry.get("annotation", ""), tags)
        try:
            start_dt = datetime.strptime(start_utc, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
            live_seconds = max(int((datetime.now(timezone.utc) - start_dt).total_seconds()), 0)
        except Exception:
            pass

    # Rescue: tracking a postponed task means the user chose to spend time on
    # it — clear the flag so it returns to the eye with a fresh countdown
    # (unpostpone_task refreshes updated_at, restarting the dead-man timer).
    if active_task_id is not None:
        rescued = next((t for t in tasks
                        if t["id"] == active_task_id and t["is_postponed"]), None)
        if rescued is not None:
            rehoboam_db.unpostpone_task(active_task_id)
            print(f"auto-rescue: unpostponed tracked task #{active_task_id}",
                  flush=True)
            tasks = list(rehoboam_db.get_all_tasks())
            if hidden:
                tasks = [t for t in tasks
                         if t["group_name"].strip().lower() not in hidden]

    # Dead-man switch: flag stale open tasks as postponed before rendering.
    settings = rehoboam_db.get_board_settings()
    if settings["postpone_hours"] > 0:
        try:
            moved = rehoboam_db.postpone_stale_tasks(
                settings["postpone_hours"], active_task_id=active_task_id)
        except Exception:
            moved = []
        if moved:
            for task_id in moved:
                print(f"dead-man switch: postponed task #{task_id}", flush=True)
            tasks = list(rehoboam_db.get_all_tasks())
            if hidden:
                tasks = [t for t in tasks if t["group_name"].strip().lower() not in hidden]

    # Postponed tasks stay off the eye: they live on the kanban Postponed
    # Shelf until rescued from the TUI (or auto-rescued by tracking, above).
    postponed_count = sum(1 for t in tasks if t["is_postponed"])
    tasks = [t for t in tasks if not t["is_postponed"]]

    today_durs = rehoboam_db.get_durations_for_date(datetime.now().strftime("%Y-%m-%d"))
    if active_task_id is not None:
        today_durs[active_task_id] = today_durs.get(active_task_id, 0) + live_seconds
    life = None
    if settings["postpone_hours"] > 0:
        try:
            baselines = rehoboam_db.get_task_activity()
        except Exception:
            baselines = {}
        life = {
            "postpone_hours": settings["postpone_hours"],
            "life": compute_lifelines(tasks, baselines, active_task_id,
                                      settings["postpone_hours"],
                                      settings["lifeline_minutes"]),
        }
    payload = build_payload(tasks, active_task_id, today_durs, tracking, life=life,
                            postponed_count=postponed_count)
    atomic_write(payload)
    return payload


def publish_snapshot():
    """Write a fresh payload outside the daemon loop (config.py calls this).

    Failures are swallowed — the daemon's next tick heals the payload anyway.
    """
    try:
        build_snapshot()
    except Exception:
        pass


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
            # A cheap dom.active query on every idle tick still catches a fresh
            # start within ~1s, keeping the widget's optimistic window intact.
            if last_active_start is None and tick % IDLE_RECHECK_TICKS != 0:
                try:
                    active = subprocess.run(
                        ["timew", "get", "dom.active"],
                        capture_output=True, text=True, timeout=2
                    ).stdout.strip() == "1"
                except Exception:
                    active = False
                if not active:
                    time.sleep(POLL_SECONDS)
                    continue
            error = None
            try:
                export_data = read_timew_export()
                entry, start_utc = fetch_active_interval(export_data)
                if entry is None:
                    if last_active_start is not None:
                        rehoboam_db.import_timew_entries(":day")
                        last_active_start = None
                elif start_utc != last_active_start:
                    rehoboam_db.import_timew_entries(":day")
                    last_active_start = start_utc
                if tick % IMPORT_EVERY_TICKS == 0:
                    rehoboam_db.import_timew_entries(":day")
                build_snapshot(export_data)
            except Exception as exc:  # keep the widget alive on any failure
                error = str(exc)
                atomic_write(build_payload([], None, {}, False, error=error))
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
