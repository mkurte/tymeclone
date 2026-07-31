import AppKit
import IOKit

// Reads the system-wide HID idle time (seconds since last mouse/keyboard input),
// the same value macOS itself uses for screensaver/display-sleep timing.
func systemIdleSeconds() -> TimeInterval {
    var iterator: io_iterator_t = 0
    let matchResult = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iterator)
    guard matchResult == KERN_SUCCESS else { return 0 }
    defer { IOObjectRelease(iterator) }

    let entry = IOIteratorNext(iterator)
    guard entry != 0 else { return 0 }
    defer { IOObjectRelease(entry) }

    var unmanagedDict: Unmanaged<CFMutableDictionary>?
    let kernResult = IORegistryEntryCreateCFProperties(entry, &unmanagedDict, kCFAllocatorDefault, 0)
    guard kernResult == KERN_SUCCESS,
          let props = unmanagedDict?.takeRetainedValue() as? [String: Any],
          let idleNs = props["HIDIdleTime"] as? UInt64 else {
        return 0
    }
    return TimeInterval(idleNs) / 1_000_000_000
}

func formatDuration(_ seconds: TimeInterval, includeSeconds: Bool = true) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return includeSeconds ? String(format: "%02d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", h, m)
}

func formatClock(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
}

func formatDateTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: date)
}

// Resolved at runtime from the current user's home directory, so the default
// works on any machine - unlike a path baked in at compile time via #filePath.
let defaultOutputFolder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Documents")
    .appendingPathComponent("TymeClone")
let outputFolderDefaultsKey = "OutputFolder"
let lastTaskNameDefaultsKey = "LastTaskName"

func currentOutputFolder() -> URL {
    if let custom = UserDefaults.standard.string(forKey: outputFolderDefaultsKey), !custom.isEmpty {
        return URL(fileURLWithPath: custom)
    }
    return defaultOutputFolder
}

// Quotes a CSV field if it contains characters that would otherwise break column parsing.
func csvField(_ value: String) -> String {
    guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
        return value
    }
    return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}

// Parses a single CSV line, honoring quoted fields (so task names may contain commas).
func parseCSVLine(_ line: Substring) -> [String] {
    var fields: [String] = []
    var current = ""
    var insideQuotes = false
    let chars = Array(line)
    var i = 0
    while i < chars.count {
        let char = chars[i]
        if insideQuotes {
            if char == "\"" {
                if i + 1 < chars.count && chars[i + 1] == "\"" {
                    current.append("\"")
                    i += 1
                } else {
                    insideQuotes = false
                }
            } else {
                current.append(char)
            }
        } else if char == "\"" {
            insideQuotes = true
        } else if char == "," {
            fields.append(current)
            current = ""
        } else {
            current.append(char)
        }
        i += 1
    }
    fields.append(current)
    return fields
}

func appendSegmentToCSV(task: String, start: Date, end: Date, duration: TimeInterval) {
    let folder = currentOutputFolder()
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fileURL = folder.appendingPathComponent("segments.csv")
    let line = "\(csvField(task)),\(formatDateTime(start)),\(formatDateTime(end)),\(formatDuration(duration))\n"

    if !FileManager.default.fileExists(atPath: fileURL.path) {
        let header = "Task,Start,End,Duration\n"
        try? (header + line).write(to: fileURL, atomically: true, encoding: .utf8)
    } else if let handle = try? FileHandle(forWritingTo: fileURL) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    }
}

func parseDuration(_ text: String) -> TimeInterval {
    let parts = text.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 3 else { return 0 }
    return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
}

enum ExportError: Error {
    case noSegmentsFile
}

// Groups segments.csv by the Start date and writes the per-day totals to daily_summary.csv.
func exportDailySummary() throws -> URL {
    let folder = currentOutputFolder()
    let segmentsURL = folder.appendingPathComponent("segments.csv")
    guard FileManager.default.fileExists(atPath: segmentsURL.path) else {
        throw ExportError.noSegmentsFile
    }

    let content = try String(contentsOf: segmentsURL, encoding: .utf8)
    var totalsByDate: [String: TimeInterval] = [:]

    for line in content.split(separator: "\n").dropFirst() {
        let columns = parseCSVLine(line)
        guard columns.count == 4 else { continue }
        let date = String(columns[1].prefix(10))
        totalsByDate[date, default: 0] += parseDuration(columns[3])
    }

    var output = "Date,Total Duration\n"
    for date in totalsByDate.keys.sorted() {
        output += "\(date),\(formatDuration(totalsByDate[date]!))\n"
    }

    let summaryURL = folder.appendingPathComponent("daily_summary.csv")
    try output.write(to: summaryURL, atomically: true, encoding: .utf8)
    return summaryURL
}

// SF Symbols give pixel-precise size and baseline control, unlike emoji characters
// whose glyph metrics vary and don't line up cleanly with monospaced digit text.
func makeStatusIcon(systemName: String, tint: NSColor?, pointSize: CGFloat = NSFont.systemFontSize - 1) -> NSImage {
    let sizeConfig = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
    guard var image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
        .withSymbolConfiguration(sizeConfig) else {
        return NSImage()
    }
    if let tint {
        let paletteConfig = NSImage.SymbolConfiguration(paletteColors: [tint])
        image = image.withSymbolConfiguration(paletteConfig) ?? image
    } else {
        image.isTemplate = true
    }
    return image
}

let recordingRed = NSColor(calibratedRed: 0.7, green: 0.0, blue: 0.0, alpha: 1.0)
let recordingIcon = makeStatusIcon(systemName: "circle.fill", tint: recordingRed, pointSize: NSFont.systemFontSize - 6)
let idleIcon = makeStatusIcon(systemName: "square.fill", tint: nil)

// Fixed-width digits keep the status bar title from jittering as the seconds tick.
func statusBarTitle(icon: NSImage, text: String) -> NSAttributedString {
    let textFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    let iconSize = icon.size

    let attachment = NSTextAttachment()
    attachment.image = icon
    attachment.bounds = CGRect(
        x: 0,
        y: (textFont.capHeight - iconSize.height) / 2,
        width: iconSize.width,
        height: iconSize.height
    )

    let result = NSMutableAttributedString(attachment: attachment)
    result.append(NSAttributedString(string: " \(text)", attributes: [.font: textFont]))
    return result
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?

    private var isRecording = false
    private var sessionStart: Date?
    private var currentTaskName = "Unnamed task"
    private var idleThreshold: TimeInterval = 5 * 60
    private var hasPromptedForCurrentIdlePeriod = false
    private var showSeconds = true

    private var startStopItem: NSMenuItem!
    private var setTaskItem: NSMenuItem!
    private var showSecondsItem: NSMenuItem!
    private var outputFolderInfoItem: NSMenuItem!
    private var thresholdItems: [TimeInterval: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let savedTaskName = UserDefaults.standard.string(forKey: lastTaskNameDefaultsKey) ?? ""
        currentTaskName = savedTaskName.isEmpty ? "Unnamed task" : savedTaskName

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.attributedTitle = statusBarTitle(icon: idleIcon, text: "00:00:00")

        let menu = NSMenu()

        startStopItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
        startStopItem.target = self
        menu.addItem(startStopItem)

        setTaskItem = NSMenuItem(title: "Set task (\(currentTaskName))", action: #selector(setCurrentTask), keyEquivalent: "")
        setTaskItem.target = self
        menu.addItem(setTaskItem)

        menu.addItem(NSMenuItem.separator())

        let thresholdMenu = NSMenu()
        for minutes in [1, 3, 5, 10, 15] {
            let seconds = TimeInterval(minutes * 60)
            let item = NSMenuItem(title: "\(minutes) min", action: #selector(setThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = (seconds == idleThreshold) ? .on : .off
            thresholdMenu.addItem(item)
            thresholdItems[seconds] = item
        }
        let thresholdParent = NSMenuItem(title: "Idle Threshold", action: nil, keyEquivalent: "")
        thresholdParent.submenu = thresholdMenu
        menu.addItem(thresholdParent)

        showSecondsItem = NSMenuItem(title: "Show Seconds", action: #selector(toggleShowSeconds), keyEquivalent: "")
        showSecondsItem.target = self
        showSecondsItem.state = showSeconds ? .on : .off
        menu.addItem(showSecondsItem)

        let outputMenu = NSMenu()
        outputFolderInfoItem = NSMenuItem(title: currentOutputFolder().path, action: nil, keyEquivalent: "")
        outputFolderInfoItem.isEnabled = false
        outputMenu.addItem(outputFolderInfoItem)
        outputMenu.addItem(NSMenuItem.separator())
        let chooseFolderItem = NSMenuItem(title: "Choose Output Folder\u{2026}", action: #selector(chooseOutputFolder), keyEquivalent: "")
        chooseFolderItem.target = self
        outputMenu.addItem(chooseFolderItem)
        let resetFolderItem = NSMenuItem(title: "Use Default Location", action: #selector(resetOutputFolder), keyEquivalent: "")
        resetFolderItem.target = self
        outputMenu.addItem(resetFolderItem)
        let outputParent = NSMenuItem(title: "Output Folder", action: nil, keyEquivalent: "")
        outputParent.submenu = outputMenu
        menu.addItem(outputParent)

        let exportItem = NSMenuItem(title: "Export Daily Summary\u{2026}", action: #selector(exportDailySummaryAction), keyEquivalent: "")
        exportItem.target = self
        menu.addItem(exportItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    @objc private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    @objc private func setCurrentTask() {
        let alert = NSAlert()
        alert.messageText = "Task"
        alert.informativeText = "What are you working on?"
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = currentTaskName
        textField.placeholderString = "Task name"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let entered = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        currentTaskName = entered.isEmpty ? "Unnamed task" : entered
        UserDefaults.standard.set(currentTaskName, forKey: lastTaskNameDefaultsKey)
        setTaskItem.title = "Set task (\(currentTaskName))"
    }

    @objc private func setThreshold(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        idleThreshold = seconds
        for (value, item) in thresholdItems {
            item.state = (value == seconds) ? .on : .off
        }
    }

    @objc private func toggleShowSeconds() {
        showSeconds.toggle()
        showSecondsItem.state = showSeconds ? .on : .off
    }

    @objc private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose a folder for segments.csv"

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: outputFolderDefaultsKey)
            outputFolderInfoItem.title = currentOutputFolder().path
        }
    }

    @objc private func resetOutputFolder() {
        UserDefaults.standard.removeObject(forKey: outputFolderDefaultsKey)
        outputFolderInfoItem.title = currentOutputFolder().path
    }

    @objc private func exportDailySummaryAction() {
        let alert = NSAlert()
        do {
            let summaryURL = try exportDailySummary()
            alert.messageText = "Export complete"
            alert.informativeText = "daily_summary.csv was written to \(summaryURL.path)"
            alert.alertStyle = .informational
        } catch {
            alert.messageText = "Export failed"
            alert.informativeText = "No segments.csv found in \(currentOutputFolder().path) yet. Record something first."
            alert.alertStyle = .warning
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func startRecording() {
        isRecording = true
        sessionStart = Date()
        hasPromptedForCurrentIdlePeriod = false
        startStopItem.title = "Stop Recording"
        print("Recording started at \(formatClock(sessionStart!)) for task '\(currentTaskName)'")
    }

    private func stopRecording(splitAt endDate: Date? = nil) {
        guard let start = sessionStart else { return }
        let end = endDate ?? Date()
        let duration = end.timeIntervalSince(start)
        print("Segment: \(formatClock(start)) - \(formatClock(end)) (\(formatDuration(duration))) [\(currentTaskName)]")
        appendSegmentToCSV(task: currentTaskName, start: start, end: end, duration: duration)
        isRecording = false
        sessionStart = nil
        startStopItem.title = "Start Recording"
    }

    private func tick() {
        guard isRecording, let start = sessionStart else {
            statusItem.button?.attributedTitle = statusBarTitle(icon: idleIcon, text: formatDuration(0, includeSeconds: showSeconds))
            return
        }

        let elapsed = Date().timeIntervalSince(start)
        statusItem.button?.attributedTitle = statusBarTitle(icon: recordingIcon, text: formatDuration(elapsed, includeSeconds: showSeconds))

        let idle = systemIdleSeconds()

        if idle >= idleThreshold && !hasPromptedForCurrentIdlePeriod {
            hasPromptedForCurrentIdlePeriod = true
            promptIdleDecision(idleSeconds: idle)
        } else if idle < 1 {
            hasPromptedForCurrentIdlePeriod = false
        }
    }

    private func promptIdleDecision(idleSeconds: TimeInterval) {
        let lastActive = Date().addingTimeInterval(-idleSeconds)

        let alert = NSAlert()
        alert.messageText = "Inactivity detected"
        alert.informativeText = "This Mac has not been used since \(formatClock(lastActive)) (\(formatDuration(idleSeconds)) idle). Keep counting the idle time, or split here and start a new segment now?"
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Split Here")
        alert.addButton(withTitle: "Stop")
        alert.alertStyle = .warning

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        switch response {
        case .alertSecondButtonReturn:
            // Close out the current segment at the last-active timestamp,
            // then immediately start a fresh one from now - the idle gap is excluded.
            stopRecording(splitAt: lastActive)
            startRecording()
        case .alertThirdButtonReturn:
            // Stop for good at the last-active timestamp, no new segment starts.
            stopRecording(splitAt: lastActive)
        default:
            // "Keep Running": no action needed, the segment just continues uninterrupted.
            break
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
