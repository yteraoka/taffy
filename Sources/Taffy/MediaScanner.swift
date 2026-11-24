import AppKit
import ApplicationServices

/// Finds tabs that are playing audio or using the camera, microphone or screen.
///
/// Browsers don't expose this over AppleScript, but they do in their tab strip:
/// Chromium names a tab "Title - Audio playing" / "Title - Camera recording"
/// for VoiceOver, and Safari puts a mute button inside a tab that plays audio.
/// This reads those tab elements through the Accessibility API (which needs
/// the Accessibility permission) and matches them to the AppleScript tabs.
enum MediaScanner {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to Accessibility settings.
    static func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private static var debug: Bool { UserDefaults.standard.bool(forKey: "mediaDebug") }

    /// Returns `tabs` with `media` filled in, for tabs that could be matched.
    static func annotate(_ tabs: [TabItem], browser: Browser) -> [TabItem] {
        guard !tabs.isEmpty,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).first
        else { return tabs }
        let pid = app.processIdentifier

        var result = isTrusted ? annotateFromTabStrip(tabs, browser: browser, pid: pid) : tabs

        // What macOS reports: a camera / microphone in use somewhere, and
        // whether this browser itself is playing or recording audio. When the
        // latter is known, it replaces "some microphone is in use", which also
        // fires for other apps and for headsets that only play sound.
        let appAudio = AppAudio.usage(pid: pid, bundleURL: app.bundleURL)
        let devices = CaptureDevices.inUse()
        var inUse = devices
        if let appAudio {
            inUse.remove(.microphone)
            inUse.formUnion(appAudio.intersection(.microphone))
        }
        if debug {
            NSLog("Taffy media: %@ trusted=%d devices in use: camera=%d microphone=%d; app audio: %@",
                  browser.name, isTrusted ? 1 : 0,
                  devices.contains(.camera) ? 1 : 0, devices.contains(.microphone) ? 1 : 0,
                  appAudio.map { "output=\($0.contains(.audio) ? 1 : 0) input=\($0.contains(.microphone) ? 1 : 0)" }
                      ?? "unavailable (needs macOS 14.2)")
            if #available(macOS 14.2, *) {
                for line in AppAudio.describe(pid: pid, bundleURL: app.bundleURL) {
                    NSLog("Taffy media: %@ audio process %@", browser.name, line)
                }
            }
        }
        return CaptureInference.apply(inUse, appAudio: appAudio, to: result)
    }

    /// Reads each tab's state from the tab strip through the Accessibility API.
    private static func annotateFromTabStrip(_ tabs: [TabItem], browser: Browser, pid: pid_t) -> [TabItem] {
        let axWindows = scanWindows(pid: pid)
        if debug {
            for (i, window) in axWindows.enumerated() {
                NSLog("Taffy media: %@ AX window %d: %@", browser.name, i, window.joined(separator: " || "))
            }
        }
        guard !axWindows.isEmpty else { return tabs }

        var result = tabs
        var usedAXWindows = Set<Int>()
        let windows = Dictionary(grouping: tabs.indices, by: { tabs[$0].windowNumber })
        for (_, indices) in windows {
            let ordered = indices.sorted { tabs[$0].tabIndex < tabs[$1].tabIndex }
            let titles = ordered.map { FuzzyMatcher.normalize(tabs[$0].title) }

            // Pick the AX window with the same number of tabs whose tab names
            // agree best with the AppleScript titles.
            var best: (index: Int, score: Int)?
            for (axIndex, axTabs) in axWindows.enumerated()
            where !usedAXWindows.contains(axIndex) && axTabs.count == titles.count {
                var score = 0
                for (title, text) in zip(titles, axTabs) {
                    let key = String(title.prefix(30))
                    if key.isEmpty || text.contains(key) { score += 1 }
                }
                if score * 2 >= titles.count, score > (best?.score ?? -1) {
                    best = (axIndex, score)
                }
            }
            guard let best else { continue }
            usedAXWindows.insert(best.index)

            for (position, tabIndex) in ordered.enumerated() {
                var text = axWindows[best.index][position]
                // Drop the page title so a title like "Audio mixing tips" isn't
                // mistaken for a state.
                if !titles[position].isEmpty {
                    text = text.replacingOccurrences(of: titles[position], with: "")
                }
                result[tabIndex].media = classify(text)
            }
        }
        return result
    }

    // MARK: - Classification

    private static let mutedWords = ["unmute", "muted", "消音を解除", "消音中", "ミュート解除", "ミュート中", "ミュートを解除"]
    private static let audioWords = ["audio", "playing", "sound", "mute", "音声", "再生", "消音", "ミュート", "サウンド"]
    private static let cameraWords = ["camera", "カメラ"]
    private static let microphoneWords = ["microphone", "マイク"]
    private static let screenWords = ["screen", "desktop", "画面", "デスクトップ"]
    private static let recordingWords = ["recording", "録画", "録音"]

    /// Classifies the state text of a tab (its accessible name, description
    /// and buttons, minus the page title). English and Japanese UIs are
    /// recognized.
    static func classify(_ text: String) -> MediaState {
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        var state: MediaState = []
        if has(cameraWords) { state.insert(.camera) }
        if has(microphoneWords) { state.insert(.microphone) }
        if has(screenWords) && (has(recordingWords) || text.contains("shar") || text.contains("共有")) {
            state.insert(.screen)
        }
        if state.isEmpty, has(recordingWords) { state.formUnion([.camera, .microphone]) }
        if has(mutedWords) {
            state.insert(.muted)
        } else if has(audioWords) {
            state.insert(.audio)
        }
        return state
    }

    // MARK: - Accessibility tree

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, "AXChildren") as? [AXUIElement]) ?? []
    }

    /// For each window of the app, the normalized text of every tab in its tab strip.
    private static func scanWindows(pid: pid_t) -> [[String]] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let windows = attribute(app, "AXWindows") as? [AXUIElement] else { return [] }
        return windows.map(tabTexts(in:)).filter { !$0.isEmpty }
    }

    /// Breadth-first search for the tab strip (an AXTabGroup) without descending
    /// into web content; returns its tabs in order.
    private static func tabTexts(in window: AXUIElement) -> [String] {
        var queue = [window]
        var head = 0
        var best: [AXUIElement] = []
        let budget = 3000
        while head < queue.count, head < budget {
            let element = queue[head]
            head += 1
            let role = string(element, "AXRole") ?? ""
            if role == "AXWebArea" { continue }
            if role == "AXTabGroup" {
                let tabs = tabElements(in: element, depth: 0)
                if tabs.count > best.count { best = tabs }
                continue
            }
            queue.append(contentsOf: children(element))
        }
        return best.map { text(of: $0, depth: 0) }
    }

    private static func tabElements(in element: AXUIElement, depth: Int) -> [AXUIElement] {
        var tabs: [AXUIElement] = []
        for child in children(element) {
            let role = string(child, "AXRole") ?? ""
            if role == "AXRadioButton" || role == "AXTab" {
                tabs.append(child)
            } else if depth < 3, role != "AXWebArea" {
                tabs += tabElements(in: child, depth: depth + 1)
            }
        }
        return tabs
    }

    /// The tab's name, description and help, plus those of its buttons
    /// (Safari's mute button, for example).
    private static func text(of element: AXUIElement, depth: Int) -> String {
        var parts: [String] = []
        for name in ["AXTitle", "AXDescription", "AXHelp", "AXValue"] {
            if let value = string(element, name), !value.isEmpty { parts.append(value) }
        }
        if depth < 2 {
            for child in children(element) {
                let childText = text(of: child, depth: depth + 1)
                if !childText.isEmpty { parts.append(childText) }
            }
        }
        return FuzzyMatcher.normalize(parts.joined(separator: " | "))
    }
}
