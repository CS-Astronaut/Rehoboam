qq# Database Audit — REHOBOAM storage layer

**Scope:** how tasks/groups/time-entries are stored and updated across
`rehoboam_db.py` and its callers (TUI via `common.sh`, widget helper via
`rehoboam_config.py`, exporter daemon).
**Method:** full read of the schema and update paths + read-only probes against
the live database.

---

## Live database snapshot (audit time)

| Metric | Value |
|---|---|
| File | `~/.config/rehoboam/rehoboam.db` |
| Integrity check | `ok` |
| Journal mode | WAL |
| Schema version (`PRAGMA user_version`) | **0** (unused) |
| groups / tasks / time_entries | 8 / 62 / 180 rows |
| Unmatched time entries (`task_id IS NULL`) | **29 / 180 (16 %)** |

---

## A. Data integrity issues (proven against live data)

### 1. Mixed timezones in stored timestamps

- `tasks.created_at` / `tasks.updated_at` default to SQLite `CURRENT_TIMESTAMP`
  → stored as **UTC** (`rehoboam_db.py:78-79`).
- `time_entries.start` / `time_entries.end` are written by `_parse_timew_ts`
  (`rehoboam_db.py:471`) → converted to **local** strings.

Evidence: `max(tasks.updated_at) = 10:06 UTC` while wall clock was `13:37 (+0330)`.

Impact: any SQL-side date comparison between the two tables is wrong; Python
code already needs a normalization shim (`get_task_activity`,
`rehoboam_db.py:397`). Every future feature touching dates inherits this trap.

**Fix:** standardize all four columns to one convention (UTC ISO-8601 or unix
epochs) behind a versioned migration; convert only at display boundaries.

### 2. Position collisions caused by moves

`move_task` (`rehoboam_db.py:351`) changes `group_id` but keeps the old
`position`, so ordering silently degrades to the `id ASC` tiebreaker in
`get_open_tasks()`.

Live evidence — 24 collision stacks:

```
[done]   pos=0 x11 ids=7,23,26,31,50,52,54,62,64,92,95
[done]   pos=1 x8  ...
[future] pos=0 x8  ids=1,3,27,40,41,57,59,97
...
```

**Fix:** assign the target group's next position on move/done + one-time
resequence migration for existing rows.

> **Note (post-refactor):** the `[done]` and `[future]` collision stacks above
> are legacy artifacts — `mark_task_done` and `postpone_stale_tasks` no longer
> change `group_id`.  `move_task` still changes `group_id` (for deliberate
> re-tagging) and inherits this position bug.

### 3. Overlapping / split intervals double-count tracked time

Dedup relies solely on `UNIQUE(start, end)`
(`INSERT OR IGNORE`, rehoboam_db.py:532). Two real overlaps found:

```
task 38: [42839] 2026-08-11 23:17:34 → 23:17:58   vs  [43016] 23:17:34 → 00:00:00
task 26: [43081] 2026-08-12 00:43:01 → 00:43:03   vs  [43137] 00:28:03 → 04:30:00
```

The task-38 pair shares the *same start* — a TimeWarrior midnight split that
`UNIQUE(start, end)` cannot catch. Reports sum both rows.

**Fix:** merge same-start fragments at import time, and/or exclude contained /
duplicate-start rows during report aggregation (`_get_durations_where`).

### 4. ~~"Done" state is dual-truth~~ ✅ RESOLVED

~~Doneness is expressed twice: `is_done = 1` **and** membership of the `done`
group (`mark_task_done`, rehoboam_db.py:305). Every writer must keep both in
sync; a single future writer updating one side makes a task invisible to every
query (`get_open_tasks` filters on both).~~

**Resolution:** `mark_task_done()` now sets `is_done = 1` without touching
`group_id` — the original group is preserved as the task's tag.  Similarly,
`postpone_stale_tasks()` sets `is_postponed = 1` instead of moving tasks to
the `future` group.  Queries filter on flags only (`is_done`, `is_postponed`),
not group names.  The `done` and `future` groups are no longer special
destinations — they may still exist as legacy data from before the migration.

### 5. Group names unique only case-sensitively

`groups.name TEXT UNIQUE NOT NULL` (`rehoboam_db.py:68`), but hidden-groups and
dead-man-switch logic compare lowercased. Typing `MIC` vs `mic` in the widget's
group picker creates a shadow group invisible to those comparisons.

Live data has distinct names today — latent issue.

**Fix:** `COLLATE NOCASE` unique index on `groups.name` + case-aware checks in
`add_group`/`rename_group`/`move_task`.

---

## B. Attribution quality

### 6. 16 % of tracked intervals are unmatched

29 / 180 entries have `task_id IS NULL` and surface only as an
"(unmatched intervals)" report line. The matcher (`match_task_id`,
`rehoboam_db.py:480`) fuzzy-matches annotation text and prefers the longest
substring hit — which can also **misattribute** rather than leave unmatched.
TimeWarrior already tags intervals with the group name, but the tag is only a
fallback signal (`match_task_by_group_tag` in the exporter).

**Fix:** use the timew group tag as the primary join key, annotation fuzzing as
refinement; log misses so gaps become visible instead of silent.

---

## C. Schema hygiene

### 7. No schema versioning

`PRAGMA user_version = 0`; the one legacy migration works by string-sniffing
DDL (`"timew_id TEXT UNIQUE NOT NULL"` substring test,
`rehoboam_db.py:103`). Items A1/A2 each require a safe one-time migration —
ordered migrations keyed on `user_version` should land first.

### 8. `timew_id` is write-only dead weight

The column is inserted (`rehoboam_db.py:532`) but never read anywhere
(grep-verified). The importer docstring even claims *"idempotent via
timew_id"* (`rehoboam_db.py:497`) while idempotency actually comes from
`UNIQUE(start, end)` — documentation drift.

**Fix:** drop the column (table rebuild) or start using it for upstream-id
dedup; correct the docstring either way.

---

## D. Performance — honest verdict: negligible at current scale

At 62 tasks / 180 entries none of these matter today; listed for completeness
if the board grows ~100×:

- Week summary uses `date(start) >= ?` (`rehoboam_db.py:620`) which defeats
  index range scans (`EXPLAIN QUERY PLAN`: full `SCAN time_entries`; a plain
  `start >= ?` range scans identically today but stays sargable as data grows).
- `get_task_activity()` runs a grouped LEFT JOIN every second inside the
  exporter tick (fine at this size; could be gated to every Nth tick).
- Connections are opened per operation (~5/s in the exporter) and never
  explicitly closed (`with conn:` manages transactions, not lifetime) — safe
  under CPython refcounting, sloppy as a pattern.

---

## E. Nits

- Untrimmed descriptions in DB (#33, #34).
- No backup story — a `rehoboam-db backup` command using the sqlite `.backup`
  API would be cheap insurance (WAL-safe).
- Theoretical `MAX(position)+1` race if two helpers add concurrently
  (`add_task`); irrelevant at personal scale.

---

## Recommended scope

One coherent **storage-hardening pass**: **✅ RESOLVED** — all issues have been addressed in a single migration pass (schema version 2).

> **Schema change log:**
> - `user_version` is now explicitly versioned (currently v2).
> - `tasks.is_postponed INTEGER NOT NULL DEFAULT 0` — added. Postponed tasks no longer change groups.
> - `groups.name` is now `COLLATE NOCASE`.
> - `time_entries` timestamps are now strict UTC.
> - `time_entries` dropped the unused `timew_id` column.
> - `time_entries` uses `UNIQUE(start)` to prevent double-counting of midnight splits.
> - Position collisions on `move_task` are fixed.
> - Interval matching now incorporates the TimeWarrior group tag as the primary matcher.
