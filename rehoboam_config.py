#!/usr/bin/env python3
"""
rehoboam_config.py — config write-through helper for the HAL-Octopus widget dialog.

The Plasma widget config pages cannot safely pass arbitrary text (paths with
spaces, annotations, …) as command-line arguments, so every value is URL-encoded
by the QML side (encodeURIComponent) and decoded here (urllib.parse.unquote).

Subcommands (all values URL-encoded where noted):
  get KEY                    print KEY from ~/.config/rehoboam/config
  set KEY VALUE              set KEY (VALUE URL-encoded), atomic rewrite
  cat PATH                   print contents of PATH (URL-encoded)
  list                       JSON: {"groups": [...], "tasks": {group: [tasks]}}
  get-timew KEY              print current timew config value for KEY ("" if unset)
  timew-config KEY VALUE     timew config KEY VALUE (VALUE URL-encoded)
  timew-start GROUP TASK     timew start GROUP + timew annotate @1 TASK (both URL-encoded)
  timew-switch GROUP TASK    stop current tracking (if any), then timew-start (both URL-encoded)
  add-task GROUP TITLE       add a task to GROUP in the rehoboam DB (both URL-encoded)
  task-done ID               mark task ID done (moves it to the 'done' group)
  task-delete ID             delete task ID
  task-move ID GROUP         move task ID to GROUP (URL-encoded, created if missing)

The config file is sourced by common.sh and parsed by rehoboam_db.py, so values
are written shell-quoted (shlex.quote).
"""

import json
import os
import shlex
import subprocess
import sys
from urllib.parse import unquote

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

import rehoboam_db  # noqa: E402

CONFIG_DIR = os.path.expanduser("~/.config/rehoboam")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config")


def load_config():
    data = {}
    try:
        with open(CONFIG_FILE, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = shlex.split(line)
                if not parts or "=" not in parts[0]:
                    continue
                key, _, value = parts[0].partition("=")
                data[key.strip()] = value
    except OSError:
        pass
    return data


def save_config(data):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    tmp = CONFIG_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for key in sorted(data):
            f.write(f"{key}={shlex.quote(data[key])}\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, CONFIG_FILE)


def expand(value):
    value = unquote(value)
    if value.startswith("~/"):
        value = os.path.expanduser(value)
    return value


def get_timew_value(key):
    out = subprocess.run(["timew", "config"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if " = " in line:
            k, _, v = line.partition(" = ")
            if k.strip() == key:
                return v.strip()
    return ""


def list_board():
    groups = [g["name"] for g in rehoboam_db.get_groups()]
    tasks = {}
    for t in rehoboam_db.get_open_tasks():
        tasks.setdefault(t["group_name"], []).append(t["description"])
    return {"groups": groups, "tasks": tasks}


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = sys.argv[1]
    if cmd == "list":
        print(json.dumps(list_board()))
    elif len(sys.argv) < 3:
        print(f"missing argument for {cmd}", file=sys.stderr)
        return 2
    elif cmd == "get":
        print(load_config().get(sys.argv[2], ""))
    elif cmd == "set":
        key, value = sys.argv[2], expand(sys.argv[3])
        data = load_config()
        data[key] = value
        save_config(data)
    elif cmd == "cat":
        with open(expand(sys.argv[2]), encoding="utf-8") as f:
            print(f.read())
    elif cmd == "list":
        print(json.dumps(list_board()))
    elif cmd == "get-timew":
        print(get_timew_value(sys.argv[2]))
    elif cmd == "timew-config":
        key, value = sys.argv[2], expand(sys.argv[3])
        subprocess.run(["timew", "config", key, value], input="yes\n", text=True, check=False)
    elif cmd == "timew-start":
        group, task = expand(sys.argv[2]), expand(sys.argv[3])
        subprocess.run(["timew", "start", group], check=False)
        subprocess.run(["timew", "annotate", "@1", task], check=False)
    elif cmd == "timew-switch":
        group, task = expand(sys.argv[2]), expand(sys.argv[3])
        subprocess.run(["timew", "stop"], check=False)
        subprocess.run(["timew", "start", group], check=False)
        subprocess.run(["timew", "annotate", "@1", task], check=False)
    elif cmd == "add-task":
        group, title = expand(sys.argv[2]), expand(sys.argv[3])
        rehoboam_db.add_task(group, title)
    elif cmd == "task-done":
        rehoboam_db.mark_task_done(int(sys.argv[2]))
    elif cmd == "task-delete":
        rehoboam_db.delete_task(int(sys.argv[2]))
    elif cmd == "task-move":
        rehoboam_db.move_task(int(sys.argv[2]), expand(sys.argv[3]))
    else:
        print(f"unknown command: {cmd}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
