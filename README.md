q# REHOBOAM

Octopus-armed task board with a HAL 9000 eye, driven by the Rehoboam task suite.

REHOBOAM is a personal task-tracking stack built around a single source of
truth: an Obsidian **KANBAN.md** file. It consists of:

- a **gum-based TUI suite** (`rehoboam.sh`, `kanban.sh`, `timew.sh`) for
  Kanban CRUD, TimeWarrior tracking, and daily-note sync, and
- a **Plasma 6 desktop widget** (HAL-Octopus, `org.rehoboam.hal-octopus`)
  that renders the open board as glowing task nodes on a HAL 9000 eye, with a
  hover popup for full task info and a KDE configuration dialog.

| | |
|---|---|
| Widget | HAL-Octopus v1.2 (Plasma 6 / Qt6) |
| License | GPL-2.0-or-later |
| Shell | bash 5+, [gum](https://github.com/charmbracelet/gum) required for the TUI |
| Python | 3.9+ (stdlib only) |
| External | [TimeWarrior](https://timewarrior.net/) 1.9+, SQLite3, Obsidian (optional) |

---

## Features

- **Kanban**: groups and tasks in `KANBAN.md` (Obsidian Markdown) are
  synchronized bidirectionally with a SQLite database — the DB is the
  canonical store; the Markdown file is always regenerated and stays human-readable.
- **TimeWarrior integration**: start/stop/continue/switch/cancel from the TUI
  or the widget dialog. Intervals are tagged with the task's group and
  annotated with the task description, so the exporter can attribute time to
  the right task.
- **Reports**: today / week summaries and per-task totals, all backed by the
  SQLite `time_entries` table.
- **Daily notes**: sync tracked time and board state into Obsidian daily notes.
- **Widget**: the HAL-Octopus eye shows open tasks as nodes with live elapsed
  time; hovering a node for a configurable delay (default 2 s) pops up the
  full task panel. A single-instance Python daemon feeds it a JSON snapshot,
  atomically rewritten once per second.
- **KDE configuration dialog**: three pages — *Widget* (state file path,
  polling interval, hover delay), *Kanban* (board file and daily-notes
  directory), *TimeWarrior* (start/stop/continue + `maxtracking`, `verbose`,
  `confirmation` settings).

## Architecture

```
                  ┌─────────────────────────────────────────────────┐
                  │                  KANBAN.md (Obsidian)            │
                  └───────▲───────────────────────────▲─────────────┘
                          │ sync (init_db, startup_sync)│ sync_to_daily_note
        ┌─────────────────┴─────────┐        ┌─────────┴──────────┐
        │ rehoboam_db.py            │        │ daily notes (Obsidian)
        │ SQLite: groups / tasks /  │        └────────────────────┘
        │ time_entries              │
        └─────────▲─────────────────┘
                  │
  ┌───────────────┴───────────────────────────────────────────────┐
  │  TUI (gum)                                    Widget (QML)    │
  │  rehoboam.sh ── kanban.sh ──── rehoboam_db.py                 │
  │            └─ timew.sh ── timew CLI ──┬─ rehoboam_db.py       │
  │                                       │                       │
  │  rehoboam_exporter.py (1 s tick) ─────┘                       │
  │       │                                                       │
  │       └─ ~/.cache/rehoboam_widget.json (atomic) ── DataSource ┘
  └───────────────────────────────────────────────────────────────┘
```

Data flows:

1. `common.sh` / `rehoboam_db.py` load `~/.config/rehoboam/config`.
2. The TUI mutates tasks and groups through `rehoboam_db.py`; the Markdown
   file is regenerated on every entry (`startup_sync`).
3. `timew` intervals are imported into `time_entries` (deduplicated by
   `UNIQUE(start, end)`).
4. `rehoboam_exporter.py` polls the DB and TimeWarrior once per second and
   writes the widget snapshot atomically (tmp file + rename, single-instance
   `flock`).
5. The widget's `Plasma5Support.DataSource` runs
   `rehoboam_config.py cat <state-file>` every `pollInterval` seconds and
   renders `tasks[]` as eye nodes.

## Repository layout

```
rehoboam/
├── hal-octopus/                  # Plasma 6 widget (org.rehoboam.hal-octopus)
│   ├── metadata.json             # v1.2, GPL-2.0-or-later
│   └── contents/
│       ├── config/
│       │   ├── main.xml          # KConfigSkeleton: stateFile, pollInterval, hoverDelay
│       │   └── config.qml        # dialog model: Widget / Kanban / TimeWarrior tabs
│       └── ui/
│           ├── main.qml          # HAL eye, task nodes, hover popup, polling
│           ├── configGeneral.qml # state file, poll interval, hover delay
│           ├── configKanban.qml  # KANBAN_FILE / DAILY_NOTES_DIR write-through
│           └── configTimew.qml   # start/stop/continue + timew settings
├── rehoboam_db.py                # SQLite layer, Markdown sync, timew import, reports
├── rehoboam_config.py            # write-through CLI helper for the widget dialog
├── rehoboam_exporter.py          # 1 s widget-state daemon (atomic JSON)
├── common.sh                     # shared config, banner font, DB/shell helpers
├── rehoboam.sh                   # TUI entry point (menu)
├── kanban.sh                     # Kanban CRUD (gum)
├── timew.sh                      # TimeWarrior front end + reports
└── reload-widget.sh              # dev loop: lint → sync → reload widget
```

## Requirements

- Linux with KDE Plasma 6 (Qt 6 / QtQuick 6) for the widget
- Python 3.9+ (stdlib only)
- [TimeWarrior](https://timewarrior.net/) ≥ 1.9
- [gum](https://github.com/charmbracelet/gum) (TUI only)
- Obsidian vault (optional — paths are configurable)

## Installation

### 1. Installer script

```sh
./install.sh
```

Copies the project to `~/.local/share/rehoboam`, patches the machine-specific
paths baked into the widget QML, installs the plasmoid, links the commands
into `~/.local/bin` (`rehoboam`, `kanban.sh`, `timew.sh`, `rehoboam-config`,
`rehoboam-exporter`, `rehoboam-reload`), starts the exporter via a systemd
user unit (or XDG autostart), and restarts plasmashell.

```
./install.sh --prefix DIR        custom install prefix
./install.sh --no-links          skip ~/.local/bin symlinks
./install.sh --no-autostart      skip exporter autostart setup
./install.sh --no-restart        don't restart plasmashell afterwards
./install.sh --uninstall         remove installed artifacts
./install.sh --uninstall --purge also delete ~/.config/rehoboam, the DB and caches
```

### 2. Manual setup

Clone and configure paths (defaults assume an Obsidian vault layout):

```sh
git clone <your-fork-or-repo> rehoboam
cd rehoboam
```

Create the config file if you need different paths:

```sh
mkdir -p ~/.config/rehoboam
cat > ~/.config/rehoboam/config <<'EOF'
KANBAN_FILE=/path/to/KANBAN.md
DAILY_NOTES_DIR=/path/to/999 Daily Notes
EOF
```

Keys:

| Key | Default | Used by |
|---|---|---|
| `KANBAN_FILE` | `~/Obsidian Vault/Computer Science/KANBAN.md` | `rehoboam_db.py`, `common.sh` |
| `DAILY_NOTES_DIR` | `~/Obsidian Vault/Computer Science/999 Daily Notes` | `rehoboam_db.py`, `common.sh` |
| `REHOBOAM_DB_PATH` | `~/.config/rehoboam/rehoboam.db` | `rehoboam_db.py` |
| `HIDDEN_GROUPS` | *(unset)* | `rehoboam_exporter.py` |

`HIDDEN_GROUPS` is a comma-separated list of group names whose tasks are
excluded from the octopus eye display (case-insensitive; the exporter re-reads
the file on every tick, so changes appear within a second). It affects the
widget display only — tracking and the TUI are unaffected. Groups containing
commas aren't supported.

The file is `KEY=VALUE` per line with shell-quoted values — `common.sh`
sources it directly and `rehoboam_db.py` parses it on import. The widget
dialog rewrites it atomically (sorted keys, fsync + rename).

### 3. TUI

```sh
./rehoboam.sh
```

Menu: **Kanban**, **TimeW**, **Sync to Daily Note**, **Quit**.

### 4. Widget daemon (exporter)

The installer sets this up automatically (systemd user unit, falling back to
XDG autostart). To run manually:

```sh
nohup python3 ~/rehoboam/rehoboam_exporter.py >> /tmp/rehoboam_exporter.log 2>&1 &
```

The daemon is single-instance (`flock` on `~/.cache/rehoboam_widget.lock`)
and writes `~/.cache/rehoboam_widget.json` once per second.

### 5. Widget (dev reload)

For development from this repo:

```sh
./reload-widget.sh        # lint → rsync → clear caches → restart plasmashell
```

The script installs the widget into
`~/.local/share/plasma/plasmoids/org.rehoboam.hal-octopus` and restarts
plasmashell. After that, add **HAL-Octopus** to a panel from the Plasma
widget browser. (Alternatively copy `hal-octopus/` manually, then clear
`~/.cache/plasma` and restart plasmashell.)

## The widget

- **Eye**: open tasks are rendered as nodes on the HAL 9000 eye assembly;
  active tasks are highlighted and show live elapsed time (`run_time`).
- **Hover popup**: hover any node for `hoverDelay` ms (default 2000) to see
  the full task panel — description, group, run time, and status.
- **Polling**: `DataSource` runs
  `python3 ~/rehoboam/rehoboam_config.py cat <stateFile>` every
  `pollInterval` seconds (default 1, clamped to ≥ 1 s since the interval is
  milliseconds).
- **Config dialog**: right-click → *Configure*. Three tabs backed by
  `main.xml` (KConfigSkeleton):

  - **Widget** — `stateFile` (JSON snapshot path), `pollInterval` (s),
    `hoverDelay` (ms).
  - **Kanban** — `KANBAN_FILE`, `DAILY_NOTES_DIR` (edits write through to
    `~/.config/rehoboam/config` atomically), plus a **Hidden from the
    octopus** checkbox list: ticked groups' tasks are dropped from the eye
    display (persisted as `HIDDEN_GROUPS`).
  - **TimeWarrior** — start a task from dropdowns populated live from the
    board (group + open tasks), stop/continue, and toggle `maxtracking`,
    `verbose`, `confirmation`.

### JSON snapshot schema

`~/.cache/rehoboam_widget.json`:

```json
{
  "timestamp": "2026-08-04T00:35:07",
  "active_task_id": 25,
  "tasks": [
    {
      "id": 25,
      "description": "add change task group to edit task section (rehoboam)",
      "category": "@todo",
      "run_seconds": 3725,
      "run_time": "1h 2m",
      "is_active": true
    }
  ]
}
```

`error` is included (instead of `tasks`) when a tick fails, so the widget
stays alive and displays the problem.

## TimeWarrior integration protocol

- `timew start GROUP` — the tag is the **group name**.
- `timew annotate @1 TASK-DESCRIPTION` — the annotation is the **task
  description**, used for attribution.
- On import (`import_timew_entries`), an annotation is matched to a task:
  1. exact match against task descriptions (`match_task_id`),
  2. fallback: group tag must equal the task's group, description fuzzy-match
     (`match_task_by_group_tag`).
- Intervals are imported every 30 exporter ticks and whenever the active
  interval changes; duplicates are prevented by `UNIQUE(start, end)`.
- Manual tracking: `timew track DURATION GROUP` + `timew annotate @1 TASK`.

## `rehoboam_config.py` — write-through helper

The Plasma config pages cannot pass arbitrary text (paths with spaces,
annotations, …) as command-line arguments, so QML URL-encodes every value
(`encArg`: `encodeURIComponent` plus `! ' ( ) * ~`, which the Plasma
executable engine hands to `/bin/sh`) and the helper decodes with
`urllib.parse.unquote`.

```
rehoboam_config.py get KEY                 # print value from ~/.config/rehoboam/config
rehoboam_config.py set KEY VALUE           # set (VALUE URL-encoded), atomic rewrite
rehoboam_config.py cat PATH                # print a file's contents (PATH URL-encoded)
rehoboam_config.py list                    # {"groups": [...], "tasks": {group: [tasks]}}
rehoboam_config.py get-timew KEY           # current timew config value
rehoboam_config.py timew-config KEY VALUE  # timew config KEY VALUE
rehoboam_config.py timew-start GROUP TASK  # timew start GROUP + annotate @1 TASK
```

## Database schema

```sql
groups        (id, name UNIQUE, position)
tasks         (id, group_id FK→groups ON DELETE CASCADE, description,
               is_done, position, created_at, updated_at)
time_entries  (id, task_id FK→tasks ON DELETE SET NULL, timew_id,
               start, end, duration_seconds, UNIQUE(start, end))
```

`init_db()` also migrates the legacy `time_entries` schema (positional
`timew_id UNIQUE` → `UNIQUE(start, end)`), rebuilding derived data.

## Development

```sh
./reload-widget.sh   # qmllint → rsync to plasmoids dir → clear QML caches → restart plasmashell
```

Each widget dialog page declares the `cfg_*` properties it does not use to
silence `SimpleKCM does not have a property` warnings from the KCM framework.

### Gotchas

- The Plasma executable engine runs commands via `/bin/sh` — shell-special
  characters must stay percent-encoded (`encArg`).
- Widget polling interval is **milliseconds**; `pollInterval` (seconds) is
  multiplied by 1000 and clamped to ≥ 1 s.
- Never pipe the widget helper through `head`/truncating tools when testing —
  a closed pipe delivers SIGPIPE and can kill the `timew` subprocess mid-write.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Widget shows nothing / no node updates | Is `rehoboam_exporter.py` running? Check `~/.cache/rehoboam_widget.json` and `journalctl --user -b \| grep rehoboam` |
| `sh: syntax error near unexpected token` | Caused by unencoded shell-special chars in task text — use `encArg`/URL-encoded args |
| Board file not found | Set `KANBAN_FILE` in `~/.config/rehoboam/config` or the widget's Kanban page |
| Config dialog warnings (`SimpleKCM ... cfg_*`) | Cosmetic; declare the unused `cfg_*` properties on the page |

## License

GPL-2.0-or-later.
