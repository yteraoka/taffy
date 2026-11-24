import Foundation

/// Which group of apps the panel searches. The panel shows one at a time and
/// Tab switches between them.
enum AppCategory: String, CaseIterable, Hashable, Sendable {
    case browser
    case terminal

    var title: String {
        switch self {
        case .browser: return "Browsers"
        case .terminal: return "Terminals"
        }
    }

    var other: AppCategory { self == .browser ? .terminal : .browser }
}

/// How an app exposes its tabs over AppleScript.
enum BrowserKind: String, Hashable, Sendable {
    /// Chrome-compatible scripting dictionary (Chrome, Brave, Edge, Vivaldi, ...).
    case chromium
    /// Safari's scripting dictionary.
    case safari
    /// Arc's scripting dictionary (tabs are selected with the `select` command).
    case arc
    /// Ghostty 1.3+ (windows > tabs > terminals, with tty and working directory).
    case ghostty
    /// Terminal.app (tabs have a tty and a process list, but no id).
    case appleTerminal

    var category: AppCategory {
        switch self {
        case .chromium, .safari, .arc: return .browser
        case .ghostty, .appleTerminal: return .terminal
        }
    }
}

/// An app whose tabs Taffy lists: a browser or a terminal.
struct Browser: Hashable, Sendable {
    let name: String
    let bundleID: String
    let kind: BrowserKind

    var category: AppCategory { kind.category }

    /// Supported apps, in the order their tabs are listed.
    static let all: [Browser] = [
        Browser(name: "Safari", bundleID: "com.apple.Safari", kind: .safari),
        Browser(name: "Safari Technology Preview", bundleID: "com.apple.SafariTechnologyPreview", kind: .safari),
        Browser(name: "Google Chrome", bundleID: "com.google.Chrome", kind: .chromium),
        Browser(name: "Google Chrome Beta", bundleID: "com.google.Chrome.beta", kind: .chromium),
        Browser(name: "Google Chrome Dev", bundleID: "com.google.Chrome.dev", kind: .chromium),
        Browser(name: "Google Chrome Canary", bundleID: "com.google.Chrome.canary", kind: .chromium),
        Browser(name: "Chromium", bundleID: "org.chromium.Chromium", kind: .chromium),
        Browser(name: "Brave", bundleID: "com.brave.Browser", kind: .chromium),
        Browser(name: "Brave Beta", bundleID: "com.brave.Browser.beta", kind: .chromium),
        Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", kind: .chromium),
        Browser(name: "Microsoft Edge Beta", bundleID: "com.microsoft.edgemac.Beta", kind: .chromium),
        Browser(name: "Microsoft Edge Dev", bundleID: "com.microsoft.edgemac.Dev", kind: .chromium),
        Browser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", kind: .chromium),
        Browser(name: "Arc", bundleID: "company.thebrowser.Browser", kind: .arc),
        Browser(name: "Ghostty", bundleID: "com.mitchellh.ghostty", kind: .ghostty),
        Browser(name: "Terminal", bundleID: "com.apple.Terminal", kind: .appleTerminal),
    ]
}

/// Audio / capture state of a tab, read from the browser's tab strip through
/// the Accessibility API (see MediaScanner) and inferred from what macOS
/// reports about the browser's audio and the cameras (see CaptureInference).
struct MediaState: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let audio = MediaState(rawValue: 1 << 0)
    static let muted = MediaState(rawValue: 1 << 1)
    static let camera = MediaState(rawValue: 1 << 2)
    static let microphone = MediaState(rawValue: 1 << 3)
    static let screen = MediaState(rawValue: 1 << 4)

    static let capture: MediaState = [.camera, .microphone, .screen]
    /// Everything except "muted": the tab is actually doing something.
    static let active: MediaState = [.audio, .camera, .microphone, .screen]

    /// Sort order for listing: capturing tabs first, then audio, then muted.
    var priority: Int {
        if !intersection(.capture).isEmpty { return 0 }
        if contains(.audio) { return 1 }
        if contains(.muted) { return 2 }
        return 3
    }
}

struct TabItem: Identifiable, Hashable, Sendable {
    let browser: Browser
    /// The browser's own window id (number or string, kept as text).
    let windowID: String
    /// 1-based position of the window in the browser's window list (for display).
    let windowNumber: Int
    /// 1-based index of the tab within its window.
    let tabIndex: Int
    /// The browser's own tab id, when it has one (Chromium, Arc, Ghostty).
    let tabID: String?
    let title: String
    /// The page URL for browsers; the working directory or tty for terminals.
    let url: String
    let isActive: Bool
    /// Terminals: the ttys of the tab's terminals (several with splits), as "ttys003".
    let ttys: [String]
    var media: MediaState = []
    /// Terminals: Claude Code is running in this tab.
    var claudeCode = false

    /// Normalized fields used for matching.
    let searchTitle: String
    let searchURL: String
    let searchBrowser: String

    var id: String { "\(browser.bundleID)|\(windowID)|\(tabIndex)" }

    var displayTitle: String { title.isEmpty ? url : title }

    /// Sort order when nothing is typed: Claude Code tabs, then media tabs.
    var priority: Int { claudeCode ? -1 : media.priority }

    init(browser: Browser, windowID: String, windowNumber: Int, tabIndex: Int,
         tabID: String?, title: String, url: String, isActive: Bool, ttys: [String] = []) {
        self.browser = browser
        self.windowID = windowID
        self.windowNumber = windowNumber
        self.tabIndex = tabIndex
        self.tabID = tabID
        self.title = title
        self.url = url
        self.isActive = isActive
        self.ttys = ttys
        self.searchTitle = FuzzyMatcher.normalize(title)
        self.searchURL = FuzzyMatcher.normalize(url)
        self.searchBrowser = FuzzyMatcher.normalize(browser.name)
    }

    /// A copy with a different subtitle (URL / working directory).
    func withURL(_ newURL: String) -> TabItem {
        var copy = TabItem(browser: browser, windowID: windowID, windowNumber: windowNumber,
                           tabIndex: tabIndex, tabID: tabID, title: title, url: newURL,
                           isActive: isActive, ttys: ttys)
        copy.media = media
        copy.claudeCode = claudeCode
        return copy
    }
}
