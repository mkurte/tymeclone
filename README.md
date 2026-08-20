# TymeClone

A tiny macOS menu bar timer that reproduces the one feature from [Tyme 2](https://www.tyme-app.com) worth keeping around after its development stopped: automatic idle detection with a prompt to keep, split, or stop the running timer.

## Features

- Menu bar timer with Start/Stop recording, tagged with a free-text task name
- A red dot (● recording) or black square (■ idle) status icon, plus a jitter-free monospaced elapsed time
- Idle detection via macOS' native `HIDIdleTime` (the same signal used for screensaver/display sleep) — no accessibility permissions required
- When the configured idle threshold is exceeded, a popup offers three choices:
  - **Keep Running** — count the idle time as work
  - **Split Here** — end the current segment at the last-active timestamp and start a new one now, keeping the same task
  - **Stop** — end the current segment at the last-active timestamp and stop recording
- Configurable idle threshold (1/3/5/10/15 min)
- "Show Seconds" toggle for the menu bar display
- Read-only "Task Total" menu entry showing the summed time for the current task across all recorded segments, live while recording
- Every finished segment is appended to a `segments.csv` file, one row per segment
- Configurable output folder (defaults to `~/Documents/TymeClone`, resolved at runtime so it works on any machine)
- "Export Daily Summary…" writes a `daily_summary.csv` with per-day totals

## Requirements

- macOS 13 or later
- Swift toolchain (Xcode Command Line Tools are enough: `xcode-select --install`)

## Build & Run

```bash
swift run
```

or build a standalone binary:

```bash
swift build -c release
./.build/release/TymeClone
```

The app runs as a menu bar accessory (no Dock icon). Look for the status icon (● or ■) — if your menu bar is full, hold **Cmd** and drag icons around to reveal it.

### Launching by double-click

A bare command-line binary usually opens in a Terminal window when double-clicked in Finder. To get a proper double-clickable app instead:

```bash
./build-app.sh
```

This builds a release binary and wraps it into `TymeClone.app` (ad-hoc signed, `LSUIElement` so it stays a menu-bar-only app with no Dock icon). Double-click `TymeClone.app` in Finder, or drag it into `/Applications`. Re-run the script after any code change to rebuild the bundle — `TymeClone.app` itself is gitignored, only `build-app.sh` is tracked.

To install it properly, copy the built bundle into `/Applications`:

```bash
cp -R TymeClone.app /Applications/
```

Since it's built locally (not downloaded), macOS won't set a quarantine flag, so Gatekeeper won't complain on first launch. To start it automatically at login, add it in **System Settings → General → Login Items** after copying it to `/Applications`. There's no auto-update mechanism — after a code change, rebuild with `./build-app.sh` and copy it over again.

## Usage

Click the status icon in the menu bar:

- **Start/Stop Recording** — toggles the timer for the current task
- **Set task (…)** — opens a popup to change the current task name; the menu title always shows the active one. Confirming with an empty field falls back to "Unnamed task". The last name used is remembered across restarts
- **Task Total: …** — read-only, shows the total time recorded for the current task (sum of all matching `segments.csv` rows, plus the running elapsed time while recording)
- **Idle Threshold** — how long the Mac must be idle before the popup appears
- **Show Seconds** — toggle seconds in the menu bar display
- **Output Folder** — shows the current CSV location; "Choose Output Folder…" picks a custom folder, "Use Default Location" resets to `~/Documents/TymeClone`
- **Export Daily Summary…** — aggregates `segments.csv` by day into `daily_summary.csv` in the same folder

## CSV format

`segments.csv` gets a header row on first write, then one row per finished segment:

```csv
Task,Start,End,Duration
Client Report,2026-07-31 09:00:12,2026-07-31 10:15:47,01:15:35
```

- `Task`: free text, quoted per standard CSV rules if it contains a comma, quote, or newline
- `Start` / `End`: `yyyy-MM-dd HH:mm:ss`
- `Duration`: `HH:mm:ss`

`daily_summary.csv` (written by "Export Daily Summary…") groups all segments by the `Start` date:

```csv
Date,Total Duration
2026-07-31,03:45:22
```

## Scope

This is a focused prototype covering the idle-detection killer feature plus just enough to make the export usable — there's no project hierarchy, editing of past segments, or GUI reporting (yet). Segments are a single flat timeline tagged with a task name, not a full project/task tree.

## Please note

This app is vibe coded with Claude.