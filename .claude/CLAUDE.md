# TymeClone

Menu bar time tracker for macOS, single-file Swift package. See [README.md](../README.md) for user-facing feature docs.

## Structure

Everything lives in `Sources/TymeClone/main.swift` — top-level free functions (idle detection, CSV read/write, icon building), then one `AppDelegate` class holding all UI/menu state. Keep it this way unless the project grows enough to justify splitting files; it's still small enough that one file is easier to navigate than jumping around.

The one exception is `Sources/TymeClone/ReportHTML.swift`, which holds `reportHTMLTemplate` — the entire HTML/CSS/JS report page as one Swift raw string literal (`#"""..."""#`). It's split out purely so the giant string doesn't drown out `main.swift`; it's still compiled as a normal part of the same target (no `Package.swift` change needed, no resource bundling — see below).

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

## Task Total menu item

`taskHistoricalTotal` is an in-memory cache of "sum of all `segments.csv` rows matching the current task name", not re-read from disk on every tick. It's recomputed from disk (`totalDuration(forTask:)`) only on launch and on task change (`setCurrentTask`); on `stopRecording` it's just incremented in-memory by the new segment's duration instead of re-reading the file — cheaper, and correct as long as nothing else writes to `segments.csv` concurrently. If you ever add a way to edit/delete past segments, this cache needs an explicit invalidation path or it'll drift from the file.

## HTML report (`report.html`)

`writeReportHTML()` in `main.swift` writes `reportHTMLTemplate` (from `ReportHTML.swift`) to `FileManager.default.temporaryDirectory` (**not** the output folder) as `report.html`, overwriting it every launch and every "Open Report" click — there's no versioning, the file on disk always matches whatever's currently compiled in. It's a fully static, dependency-free page: no build step, no bundling, nothing to keep in sync with `main.swift` beyond the CSV column contract below.

- **Deliberately lives in the temp directory, not next to `segments.csv`.** It originally wrote into the output folder (same place as the CSVs), but the user wanted app-internal files kept away from their data so there's nothing to accidentally rename/edit/delete. The temp directory was the pragmatic way to get that "can't be broken by the user" property without the SwiftPM-resource-bundling complexity below — don't move it back into the output folder.
- **Deliberately did not use SwiftPM resource bundling** (`resources: [.copy(...)]` + `Bundle.module`) for this file either, for the same "keep it inside the app, out of user reach" goal. That approach would need `build-app.sh` to also copy the generated resource bundle into `TymeClone.app/Contents/Resources/`, adding a second place that can silently drift out of sync. A plain Swift string constant, rewritten to temp on demand, gets the same practical outcome (nothing user-editable, nothing to break) without touching `build-app.sh` at all.
- **Wrote the Swift string as a raw literal (`#"""..."""#`), not a normal `"""..."""`.** The JS inside uses backslash escapes (`\r`, `\n` in a regex, `\'` in a string) that a normal Swift string would silently reinterpret as its own escape sequences (e.g. `\r` becomes an actual carriage-return character instead of staying literal backslash-r). Raw string means backslashes pass through untouched. The corollary: inside that raw string, `\#(...)` **is** real Swift interpolation (matches the `#` count) — don't let one slip in by accident, it'll fail to compile with a confusing "cannot find in scope" error pointing at whatever token follows.
- **The page never attempts `fetch('segments.csv')` as its primary path in practice** — even setting that aside, local `file://` pages can't fetch cross-origin in Safari/Chrome, so it was already falling back to the drop-zone/file-picker UI every time before the temp-directory move too; moving away from the output folder just removed the now-pointless relative path. Verified during development by serving the same file over a local `python3 -m http.server` (where fetch works) to confirm the parsing/rendering logic itself was correct, separately from the file:// limitation.
- **The CSV parser in the JS (`parseCSVLine`) is a hand-ported duplicate of the Swift one** in `main.swift` — same quote-doubling logic, kept manually in sync. If the CSV format ever changes (columns added/reordered, escaping rules changed), both places need the edit; there's no shared source of truth between Swift and JS here.
- Screenshot-verified in both light and dark mode via a local HTTP server during development (see `Known environment constraint` above for why `file://` + `screencapture` don't work together here) — don't assume future visual changes are correct without doing the same.

## Conventions

- Code comments and identifiers in English (user's global preference), chat responses in German.
- No test suite — validate behavior either by isolated `/tmp` scripts (logic) or by asking the user to confirm after a rebuild (UI/visual).
- Keep changes scoped to what's asked; this is a deliberately minimal prototype, not a framework for hypothetical future features (project/task hierarchies, reporting UI, etc. are explicitly out of scope for now per the README).
