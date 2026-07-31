# TymeClone

A tiny macOS menu bar timer that reproduces the one feature from [Tyme 2](https://www.tyme-app.com) worth keeping around after its development stopped: automatic idle detection with a prompt to keep, split, or stop the running timer.

## Features

- Menu bar timer with Start/Stop recording
- Idle detection via macOS' native `HIDIdleTime` (the same signal used for screensaver/display sleep) — no accessibility permissions required
- When the configured idle threshold is exceeded, a popup offers three choices:
  - **Keep Running** — count the idle time as work
  - **Split Here** — end the current segment at the last-active timestamp and start a new one now
  - **Stop** — end the current segment at the last-active timestamp and stop recording
- Configurable idle threshold (1/3/5/10/15 min)
- "Show Seconds" toggle for the menu bar display (monospaced digits, no jitter)
- Every finished segment is appended to a `segments.csv` file
- Configurable output folder (defaults to the folder containing `main.swift`)

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

The app runs as a menu bar accessory (no Dock icon). Look for the stopwatch icon — if your menu bar is full, hold **Cmd** and drag icons around to reveal it.

## Usage

Click the stopwatch icon in the menu bar:

- **Start/Stop Recording** — toggles the timer
- **Idle Threshold** — how long the Mac must be idle before the popup appears
- **Show Seconds** — toggle seconds in the menu bar display
- **Output Folder** — shows the current CSV location; "Choose Output Folder…" picks a custom folder, "Use Default Location" resets to the folder containing `main.swift`

## CSV format

`segments.csv` gets a header row on first write, then one row per finished segment:

```csv
Start,End,Duration
2026-07-31 09:00:12,2026-07-31 10:15:47,01:15:35
```

- `Start` / `End`: `yyyy-MM-dd HH:mm:ss`
- `Duration`: `HH:mm:ss`

## Scope

This is a focused prototype covering just the idle-detection killer feature — there's no project/task management or reporting (yet). Segments are a single flat timeline, not tied to a project.
