# TymeClone

Menu bar time tracker for macOS, single-file Swift package. See [README.md](../README.md) for user-facing feature docs.

## Structure

Everything lives in `Sources/TymeClone/main.swift` — top-level free functions (idle detection, CSV read/write, icon building), then one `AppDelegate` class holding all UI/menu state. Keep it this way unless the project grows enough to justify splitting files; it's still small enough that one file is easier to navigate than jumping around.

## Build & run

```bash
swift build        # compile, surfaces warnings/errors
swift run           # build + launch
swift build -c release
```

No test target. Verify logic changes (CSV parsing/escaping, duration math, aggregation) by writing a throwaway script under `/tmp` that copies just the relevant function(s) and running it with `swift script.swift` — faster than wiring into the full app, and the only way to check correctness since the app itself can't be visually verified here (see below).

## Known environment constraint

`screencapture` and other screen-recording APIs fail in this sandbox (`could not create image from display` — no Screen Recording permission for the automation process). There is no way to visually verify menu bar rendering, icon alignment, or popup layout from this session. For anything involving visual polish (icon size, alignment, colors), make the change, rebuild, and ask the user to check after restarting the app — don't claim it looks right without seeing it.

## Non-obvious constraints learned this project

- **Default output folder is `~/Documents/TymeClone`**, resolved at runtime via `FileManager.default.homeDirectoryForCurrentUser`. It used to be derived from `#filePath` (baked in at compile time to the build machine's absolute path) — that broke as soon as the binary/`.app` ran on a different machine or user account (wrong path, and `try?`-swallowed `createDirectory` failures silently dropped every write). Don't reintroduce a compile-time-baked default path. A user-chosen override lives in `UserDefaults` (`OutputFolder` key).
- **`UserDefaults` domain differs between run modes.** The bundled `TymeClone.app` (built via `build-app.sh`) persists under its `CFBundleIdentifier` (`de.kurte.tymeclone`), while running the bare binary (`swift run` / `.build/*/TymeClone`) persists under a domain named after the executable (`TymeClone`). These are separate `~/Library/Preferences/*.plist` files — an Output Folder or Task name set in one run mode does **not** carry over to the other. Verified via `defaults read TymeClone` vs `defaults read de.kurte.tymeclone`.
- **`UserDefaults` persists fine** across restarts for this unbundled, unsigned executable (no `Info.plist`/bundle ID) — verified empirically by running a compiled binary twice in a row. Don't assume it needs a proper `.app` bundle to work.
- **SwiftPM's `exclude` in `Package.swift` requires the excluded file to actually exist** at build time, or it emits its own "Invalid Exclude" warning. There's no clean way to permanently silence the "found unhandled file" warning for a file that's *sometimes* present (e.g. `segments.csv`, which is gitignored and only appears after the first recording in the default folder). Declaring `sources: ["main.swift"]` does **not** suppress it either — SwiftPM still scans the whole `path` directory for stray files regardless. Current tradeoff: `exclude: ["segments.csv"]` works as long as the file exists (it does, from prior testing); a truly fresh clone would briefly see the inverse warning until the app runs once. Don't chase a fully warning-free state here — it's cosmetic.
- **SF Symbols have a minimum render size floor.** Below a certain `pointSize` in `NSImage.SymbolConfiguration`, the rendered image stops shrinking further. Don't keep decreasing the value expecting continued effect — confirmed with the user when `circle.fill` stopped shrinking around `systemFontSize - 6`/`-7`.
- **Menu bar icon/text alignment**: icons are `NSTextAttachment`s with `bounds` computed relative to the font's `capHeight`, not emoji characters — emoji glyph metrics don't line up with monospaced digit text baselines.

## CSV format (source of truth: `main.swift`, not the README, if they ever drift)

`segments.csv`: `Task,Start,End,Duration` — `Task` is free text and CSV-escaped (quoted if it contains `,`, `"`, or newline) via `csvField`/`parseCSVLine`. Any code reading this file must use `parseCSVLine`, not a naive `split(separator: ",")`, or quoted task names containing commas will misalign columns.

`daily_summary.csv` (from "Export Daily Summary…"): `Date,Total Duration`, grouped by the date portion of `Start`.

## Conventions

- Code comments and identifiers in English (user's global preference), chat responses in German.
- No test suite — validate behavior either by isolated `/tmp` scripts (logic) or by asking the user to confirm after a rebuild (UI/visual).
- Keep changes scoped to what's asked; this is a deliberately minimal prototype, not a framework for hypothetical future features (project/task hierarchies, reporting UI, etc. are explicitly out of scope for now per the README).
