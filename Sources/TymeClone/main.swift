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

// #filePath is resolved at compile time, so this reliably points at the directory
// containing main.swift regardless of the working directory the app is launched from.
let sourceFileDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let outputFolderDefaultsKey = "OutputFolder"

func currentOutputFolder() -> URL {
    if let custom = UserDefaults.standard.string(forKey: outputFolderDefaultsKey), !custom.isEmpty {
        return URL(fileURLWithPath: custom)
    }
    return sourceFileDirectory
}

func appendSegmentToCSV(start: Date, end: Date, duration: TimeInterval) {
    let folder = currentOutputFolder()
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fileURL = folder.appendingPathComponent("segments.csv")
    let line = "\(formatDateTime(start)),\(formatDateTime(end)),\(formatDuration(duration))\n"

    if !FileManager.default.fileExists(atPath: fileURL.path) {
        let header = "Start,End,Duration\n"
        try? (header + line).write(to: fileURL, atomically: true, encoding: .utf8)
    } else if let handle = try? FileHandle(forWritingTo: fileURL) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    }
}

// Fixed-width digits keep the status bar title from jittering as the seconds tick.
func statusBarTitle(_ text: String) -> NSAttributedString {
    NSAttributedString(
        string: text,
        attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)]
    )
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?

    private var isRecording = false
    private var sessionStart: Date?
    private var idleThreshold: TimeInterval = 5 * 60
    private var hasPromptedForCurrentIdlePeriod = false
    private var showSeconds = true

    private var startStopItem: NSMenuItem!
    private var showSecondsItem: NSMenuItem!
    private var outputFolderInfoItem: NSMenuItem!
    private var thresholdItems: [TimeInterval: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.attributedTitle = statusBarTitle("\u{23F1} 00:00:00")

        let menu = NSMenu()

        startStopItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
        startStopItem.target = self
        menu.addItem(startStopItem)

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

    private func startRecording() {
        isRecording = true
        sessionStart = Date()
        hasPromptedForCurrentIdlePeriod = false
        startStopItem.title = "Stop Recording"
        print("Recording started at \(formatClock(sessionStart!))")
    }

    private func stopRecording(splitAt endDate: Date? = nil) {
        guard let start = sessionStart else { return }
        let end = endDate ?? Date()
        let duration = end.timeIntervalSince(start)
        print("Segment: \(formatClock(start)) - \(formatClock(end)) (\(formatDuration(duration)))")
        appendSegmentToCSV(start: start, end: end, duration: duration)
        isRecording = false
        sessionStart = nil
        startStopItem.title = "Start Recording"
    }

    private func tick() {
        guard isRecording, let start = sessionStart else {
            statusItem.button?.attributedTitle = statusBarTitle("\u{23F1} \(formatDuration(0, includeSeconds: showSeconds))")
            return
        }

        let elapsed = Date().timeIntervalSince(start)
        statusItem.button?.attributedTitle = statusBarTitle("\u{23F1} \(formatDuration(elapsed, includeSeconds: showSeconds))")

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
