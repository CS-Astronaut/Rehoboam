# REHOBOAM

An octopus-armed task board with a HAL 9000 eye, driven by a task-tracking
suite built around a single source of truth: an Obsidian **KANBAN.md** file.

REHOBOAM has two faces:

- a **gum-based terminal suite** (`rehoboam.sh`, `kanban.sh`, `timew.sh`) for
  Kanban management, TimeWarrior time tracking, and daily-note sync;
- a **Plasma 6 widget** (HAL-Octopus, `org.rehoboam.hal-octopus`) that renders
  the open board as glowing task nodes on a HAL 9000 eye, with click-to-track,
  a hover popup, and a full KDE configuration dialog.

| | |
|---|---|
| Widget | HAL-Octopus v1.2 (Plasma 6 / Qt6) |
| License | GPL-2.0-or-later |
| Shell | bash 5+, [gum](https://github.com/charmbracelet/gum) |
| Python | 3.9+ (stdlib only) |
| External | [TimeWarrior](https://timewarrior.net/) 1.9+, SQLite, Obsidian (optional) |

---

## Features

- **Kanban** — groups and tasks live in a SQLite database and are mirrored to
  `KANBAN.md`; the Markdown file is regenerated and stays human-readable.
- **TimeWarrior integration** — start, stop, switch, and cancel tracking from
  the TUI or by clicking the widget's nodes. Intervals are tagged with the
  task's group and annotated with the task description, so every tracked
  interval is attributed to the right task.
- **Reports** — today and week summaries plus per-task totals, backed by the
  SQLite `time_entries` table.
- **Daily notes** — tracked time and board state are written into the current
  Obsidian daily note.
- **Widget** — the HAL-Octopus eye shows open tasks with live elapsed time;
  click a node to start tracking, click the active node to stop. A hover
  popup shows full task details. A single-instance daemon feeds the widget an
  atomic JSON snapshot every second.
- **Configuration dialog** — three pages (Kanban, TimeWarrior, Widget) for
  board paths, hidden groups, adding tasks, tracking actions, and polling.

## Architecture

```
        KANBAN.md (Obsidian)                    daily notes (Obsidian)
             │  startup_sync                          ▲
             ▼                                        │ sync_to_daily_note
        rehoboam_db.py  (SQLite: groups / tasks / time_entries)
             ▲                     ▲
             │                     │
     kanban.sh / timew.sh    rehoboam_exporter.py (1 s tick)
     (gum TUI)                     │ atomic JSON → ~/.cache/rehoboam_widget.json
                                   ▼
                      HAL-Octopus widget (QML, polls every pollInterval s)
```

1. `~/.config/rehoboam/config` is loaded by `common.sh` and `rehoboam_db.py`.
2. The TUI mutates the board through `rehoboam_db.py`; `KANBAN.md` is
   regenerated on every entry.
3. Finished `timew` intervals are imported into `time_entries`, deduplicated
   by `UNIQUE(start, end)`.
4. `rehoboam_exporter.py` polls the DB and TimeWarrior once per second and
   writes the widget snapshot atomically (single-instance via `flock`).
5. The widget polls the snapshot and renders the tasks as eye nodes.

## Repository layout

```
rehoboam/
├── hal-octopus/                  # Plasma 6 widget (org.rehoboam.hal-octopus)
│   ├── metadata.json             # v1.2, GPL-2.0-or-later
│   └── contents/
│       ├── config/
│       │   ├── main.xml          # KConfigSkeleton: stateFile, pollInterval, hoverDelay
│       │   └── config.qml        # dialog tabs: Kanban / TimeWarrior / Widget
│       └── ui/
│           ├── main.qml          # HAL eye, task nodes, click-to-track, hover popup
│           ├── configGeneral.qml # state file, poll interval, hover delay
│           ├── configKanban.qml  # add task, hidden groups, board paths
│           └── configTimew.qml   # tracking actions + timew settings
├── rehoboam_db.py                # SQLite layer, Markdown sync, timew import, reports
├── rehoboam_config.py            # CLI helper for the widget dialog
├── rehoboam_exporter.py          # widget-state daemon (atomic JSON, 1 s tick)
├── common.sh                     # shared config, banner font, DB/shell helpers
├── rehoboam.sh                   # TUI entry point
├── kanban.sh                     # Kanban management (gum)
├── timew.sh                      # TimeWarrior front end + reports
├── install.sh                    # portable installer / uninstaller
└── reload-widget.sh              # dev loop: lint → sync → reload widget
```

## Requirements

- KDE Plasma 6 (Qt 6 / QtQuick 6) for the widget
- Python 3.9+ (stdlib only)
- TimeWarrior 1.9+
- gum (TUI only)
- Obsidian vault (optional — paths are configurable)

## Installation

### Installer

```sh
./install.sh
```

The installer copies the project to `~/.local/share/rehoboam`, patches the
machine-specific paths baked into the widget QML, installs the plasmoid,
links the commands into `~/.local/bin` (`rehoboam`, `kanban.sh`, `timew.sh`,
`rehoboam-config`, `rehoboam-exporter`, `rehoboam-reload`), starts the
exporter via a systemd user unit (or XDG autostart), and restarts
plasmashell.

```
./install.sh --prefix DIR        custom install prefix
./install.sh --no-links          skip ~/.local/bin symlinks
./install.sh --no-autostart      skip exporter autostart setup
./install.sh --no-restart        don't restart plasmashell afterwards
./install.sh --uninstall         remove installed artifacts
./install.sh --uninstall --purge also delete ~/.config/rehoboam, the DB and caches
```

### Manual setup

Clone the repository and, if your layout differs from the defaults, create a
config file:

```sh
mkdir -p ~/.config/rehoboam
cat > ~/.config/rehoboam/config <<'EOF'
KANBAN_FILE=/path/to/KANBAN.md
DAILY_NOTES_DIR=/path/to/999 Daily Notes
EOF
```

| Key | Default | Used by |
|---|---|---|
| `KANBAN_FILE` | `~/Obsidian Vault/Computer Science/KANBAN.md` | `rehoboam_db.py`, `common.sh` |
| `DAILY_NOTES_DIR` | `~/Obsidian Vault/Computer Science/999 Daily Notes` | `rehoboam_db.py`, `common.sh` |
| `REHOBOAM_DB_PATH` | `~/.config/rehoboam/rehoboam.db` | `rehoboam_db.py` |
| `HIDDEN_GROUPS` | *(unset)* | `rehoboam_exporter.py` |

`HIDDEN_GROUPS` is a comma-separated list of group names excluded from the
octopus eye display (case-insensitive, re-read on every tick). It affects the
widget display only — tracking and the TUI are unaffected. Group names
containing commas are not supported.

The file is `KEY=VALUE` per line with shell-quoted values; `common.sh`
sources it directly and `rehoboam_db.py` parses it on import. The widget
dialog rewrites it atomically.

### Running the pieces

```sh
./rehoboam.sh    # TUI menu: Kanban → TimeW → Sync to Daily Note → Quit
```

The exporter daemon is started automatically by the installer. Manually:

```sh
nohup python3 ~/rehoboam/rehoboam_exporter.py >> /tmp/rehoboam_exporter.log 2>&1 &
```

It is single-instance (`flock` on `~/.cache/rehoboam_widget.lock`) and
writes `~/.cache/rehoboam_widget.json` once per second. After installing the
plasmoid, add **HAL-Octopus** to a panel from the Plasma widget browser.

## The widget

- **Eye** — open tasks are rendered as nodes; the active task glows and shows
  live elapsed time.
- **Click to track** — click a node to start TimeWarrior tracking, click the
  active node to stop, click another node to switch. The eye reflects the
  change within ~1 s.
- **Hover popup** — hover a node for `hoverDelay` ms (default 2000) to see
  description, group, run time, and status.
- **Polling** — the widget polls the state file every `pollInterval` seconds
  (default 1).
- **Configuration dialog** — right-click → *Configure*:

  - **Kanban** — add a task (group dropdown + title), hide groups from the
    eye, and set the board file / daily-notes directory. Edits write through
    to `~/.config/rehoboam/config` atomically.
  - **TimeWarrior** — start a task from live dropdowns (group + open tasks),
    stop/continue, and toggle `maxtracking`, `verbose`, `confirmation`.
  - **Widget** — `stateFile` (snapshot path), `pollInterval` (s),
    `hoverDelay` (ms).

### Snapshot schema

`~/.cache/rehoboam_widget.json`:

```json
{
  "timestamp": "2026-08-04T00:35:07",
  "active_task_id": 25,
  "tasks": [
    {
      "id": 25,
      "description": "add change task group to edit task section (rehoboam)",
      "group": "todo",
      "category": "@todo",
      "run_seconds": 3725,
      "run_time": "1h 2m",
      "is_active": true
    }
  ]
}
```

When a tick fails, an `error` field replaces `tasks` so the widget stays
alive and displays the problem.

## TimeWarrior integration

- `timew start GROUP` — the tag is the **group name**.
- `timew annotate @1 TASK-DESCRIPTION` — the annotation is the **task
  description**, used for attribution.
- On import, an annotation is matched to a task: first an exact description
  match, then a fallback requiring the group tag to equal the task's group
  with a fuzzy description match.
- Intervals are imported every 30 ticks and whenever the active interval
  changes; duplicates are prevented by `UNIQUE(start, end)`.

## `rehoboam_config.py`

The Plasma config pages and the widget cannot pass arbitrary text as
command-line arguments, so QML URL-encodes every value (`encArg` —
`encodeURIComponent` plus `! ' ( ) * ~`, which the executable engine hands to
`/bin/sh`) and the helper decodes with `urllib.parse.unquote`.

```
rehoboam_config.py get KEY                 # value from ~/.config/rehoboam/config
rehoboam_config.py set KEY VALUE           # set (VALUE URL-encoded), atomic rewrite
rehoboam_config.py cat PATH                # print a file's contents (PATH URL-encoded)
rehoboam_config.py list                    # {"groups": [...], "tasks": {group: [tasks]}}
rehoboam_config.py get-timew KEY           # current timew config value
rehoboam_config.py timew-config KEY VALUE  # timew config KEY VALUE
rehoboam_config.py timew-start GROUP TASK  # timew start GROUP + annotate @1 TASK
rehoboam_config.py timew-switch GROUP TASK # stop current (if any), then start + annotate
rehoboam_config.py add-task GROUP TITLE    # add a task to GROUP (DB + KANBAN.md + daily note)
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
./reload-widget.sh   # qmllint → rsync to the plasmoids dir → clear caches → restart plasmashell
```

Gotchas:

- The Plasma executable engine runs commands via `/bin/sh` — shell-special
  characters must stay percent-encoded (`encArg`).
- The widget polling interval is **milliseconds**; `pollInterval` (seconds)
  is multiplied by 1000 and clamped to ≥ 1 s.
- Don't pipe the widget helper through truncating tools when testing — a
  closed pipe delivers SIGPIPE and can kill the `timew` subprocess mid-write.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Widget shows nothing / no node updates | Is the exporter running? Check `~/.cache/rehoboam_widget.json` and `journalctl --user -b \| grep rehoboam` |
| `sh: syntax error near unexpected token` | Unencoded shell-special characters — always use `encArg`/URL-encoded args |
| Board file not found | Set `KANBAN_FILE` in `~/.config/rehoboam/config` or the widget's Kanban page |
| `SimpleKCM ... cfg_*` dialog warnings | Cosmetic; declare the unused `cfg_*` properties on the page |

## License

GPL-2.0-or-later.
