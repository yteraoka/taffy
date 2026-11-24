import AppKit
import CoreAudio
import CoreMediaIO
import Foundation

/// Guesses which tab is using the camera / microphone when the tab strip
/// doesn't say.
///
/// Chromium shows only one alert per tab, and a video call is always playing
/// audio, so Brave (and recent Chrome) label a Google Meet tab "Audio playing"
/// rather than "Camera recording". macOS does tell whether a camera is in use
/// somewhere, and (on macOS 14.2 and later) whether the browser itself is
/// playing audio or recording from a microphone, so a meeting site tab that
/// plays audio while those are in use is assumed to be the one using them.
/// This is a guess: another app using the camera at the same time also lights
/// the tab up.
enum CaptureInference {
    /// Hosts (and their subdomains) of web meeting services.
    static let meetingHosts = [
        "meet.google.com",
        "zoom.us",
        "zoom.com",
        "teams.microsoft.com",
        "teams.live.com",
        "teams.cloud.microsoft",
        "webex.com",
        "whereby.com",
        "meet.jit.si",
        "app.chime.aws",
    ]

    static func isMeetingSite(_ url: String) -> Bool {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Adds the capture states in `inUse` (camera / microphone in use) to
    /// meeting site tabs that are playing (or muted) audio. A state is only
    /// added when no tab of the browser already reports it on its own.
    ///
    /// `appAudio` is what macOS reports for the browser as a whole (`.audio`
    /// while it plays sound, `.microphone` while it records), or nil when
    /// that isn't known. When no tab reports any state (the tab strip couldn't
    /// be read, e.g. without the Accessibility permission), meeting site tabs
    /// of a browser that is playing or recording audio are taken to be the
    /// ones doing it.
    static func apply(_ inUse: MediaState, appAudio: MediaState? = nil, to tabs: [TabItem]) -> [TabItem] {
        let reported = tabs.reduce(into: MediaState()) { $0.formUnion($1.media) }
        var tabs = tabs
        if reported.isEmpty, let appAudio, !appAudio.intersection([.audio, .microphone]).isEmpty {
            for index in tabs.indices where isMeetingSite(tabs[index].url) {
                tabs[index].media.formUnion(appAudio.intersection(.audio))
                if appAudio.contains(.microphone) { tabs[index].media.insert(.microphone) }
            }
        }
        let missing = inUse.intersection([.camera, .microphone]).subtracting(reported)
        guard !missing.isEmpty else { return tabs }
        return tabs.map { tab in
            var tab = tab
            if !tab.media.intersection([.audio, .muted, .microphone]).isEmpty, isMeetingSite(tab.url) {
                tab.media.formUnion(missing)
            }
            return tab
        }
    }
}

/// Whether any camera or microphone on the Mac is in use by some process.
/// Reading this needs no permission and doesn't open the devices.
enum CaptureDevices {
    static func inUse() -> MediaState {
        var state: MediaState = []
        if isAnyCameraRunning() { state.insert(.camera) }
        if isAnyMicrophoneRunning() { state.insert(.microphone) }
        return state
    }

    // MARK: Camera (CoreMediaIO)

    private static func isAnyCameraRunning() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr else {
            return false
        }

        address.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        return devices.contains { device in
            var running: UInt32 = 0
            var dataUsed: UInt32 = 0
            let status = CMIOObjectGetPropertyData(device, &address, 0, nil,
                                                   UInt32(MemoryLayout<UInt32>.size), &dataUsed, &running)
            return status == noErr && running != 0
        }
    }

    // MARK: Microphone (CoreAudio)

    private static func isAnyMicrophoneRunning() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDevices),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else {
            return false
        }
        return devices.contains { hasInput($0) && isRunningSomewhere($0) }
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioDevicePropertyStreams),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeInput),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioDevicePropertyDeviceIsRunningSomewhere),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }
}

/// Whether an app (with its helper processes) is playing audio or recording
/// from a microphone, from CoreAudio's per-process state. Reading this needs
/// no permission. It covers the whole app, not a single tab: Chromium plays
/// and records every tab's audio in one "audio service" helper process.
enum AppAudio {
    /// `.audio` while the app outputs sound and `.microphone` while it records,
    /// or nil before macOS 14.2 (which added per-process state).
    static func usage(pid: pid_t, bundleURL: URL?) -> MediaState? {
        guard #available(macOS 14.2, *) else { return nil }
        let bundlePath = bundleURL.map { $0.standardizedFileURL.path + "/" }
        var state: MediaState = []
        for process in CoreAudioObject.ids(AudioObjectID(kAudioObjectSystemObject),
                                           kAudioHardwarePropertyProcessObjectList) {
            let input = CoreAudioObject.uint32(process, kAudioProcessPropertyIsRunningInput) ?? 0 != 0
            let output = CoreAudioObject.uint32(process, kAudioProcessPropertyIsRunningOutput) ?? 0 != 0
            guard input || output,
                  let processPID = CoreAudioObject.int32(process, kAudioProcessPropertyPID),
                  belongs(processPID, to: pid, bundlePath: bundlePath)
            else { continue }
            if output { state.insert(.audio) }
            if input { state.insert(.microphone) }
        }
        return state
    }

    /// Every process of the app that uses audio, as reported by CoreAudio.
    @available(macOS 14.2, *)
    static func describe(pid: pid_t, bundleURL: URL?) -> [String] {
        let bundlePath = bundleURL.map { $0.standardizedFileURL.path + "/" }
        return CoreAudioObject.ids(AudioObjectID(kAudioObjectSystemObject),
                                   kAudioHardwarePropertyProcessObjectList).compactMap { process in
            guard let processPID = CoreAudioObject.int32(process, kAudioProcessPropertyPID),
                  belongs(processPID, to: pid, bundlePath: bundlePath)
            else { return nil }
            let input = CoreAudioObject.uint32(process, kAudioProcessPropertyIsRunningInput) ?? 0
            let output = CoreAudioObject.uint32(process, kAudioProcessPropertyIsRunningOutput) ?? 0
            return "pid=\(processPID) input=\(input) output=\(output)"
        }
    }

    /// Whether `process` is the app or one of its helpers: Chromium's helper
    /// apps live inside the app bundle, and Safari's audio is played by a
    /// WebKit GPU process that macOS holds Safari responsible for.
    private static func belongs(_ process: pid_t, to app: pid_t, bundlePath: String?) -> Bool {
        if process == app || responsiblePID(process) == app { return true }
        guard let bundlePath else { return false }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(process, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return String(cString: buffer).hasPrefix(bundlePath)
    }

    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
    private static let responsibleFunction: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
                                 "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    /// The process macOS holds responsible for `pid` (the app that launched an
    /// XPC service, for example), when the system provides that lookup.
    private static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let responsibleFunction else { return nil }
        let result = responsibleFunction(pid)
        return result > 0 ? result : nil
    }
}

/// Small helpers for reading CoreAudio object properties.
enum CoreAudioObject {
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: AudioObjectPropertyElement(kAudioObjectPropertyElementMain)
        )
    }

    static func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func int32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int32? {
        var address = address(selector)
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
}
