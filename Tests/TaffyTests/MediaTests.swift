import XCTest
@testable import Taffy

final class MediaScannerClassifyTests: XCTestCase {
    func testChromiumLabels() {
        XCTAssertEqual(MediaScanner.classify(" - audio playing"), .audio)
        XCTAssertEqual(MediaScanner.classify(" - audio muted"), .muted)
        XCTAssertEqual(MediaScanner.classify(" - camera recording"), .camera)
        XCTAssertEqual(MediaScanner.classify(" - microphone recording"), .microphone)
        XCTAssertEqual(MediaScanner.classify(" - camera or microphone recording"), [.camera, .microphone])
        XCTAssertEqual(MediaScanner.classify(" - sharing your screen"), .screen)
    }

    func testSafariMuteButton() {
        XCTAssertEqual(MediaScanner.classify(" | mute this tab"), .audio)
        XCTAssertEqual(MediaScanner.classify(" | unmute this tab"), .muted)
    }

    func testJapaneseLabels() {
        XCTAssertEqual(MediaScanner.classify(" - 音声を再生中"), .audio)
        XCTAssertEqual(MediaScanner.classify(" - カメラを使用中"), .camera)
        XCTAssertEqual(MediaScanner.classify(" - マイクを使用中"), .microphone)
        XCTAssertEqual(MediaScanner.classify(" - ミュート中"), .muted)
    }

    func testPlainTabHasNoState() {
        XCTAssertEqual(MediaScanner.classify(""), [])
        XCTAssertEqual(MediaScanner.classify(" | close tab"), [])
    }

    func testPriority() {
        XCTAssertLessThan(MediaState.camera.priority, MediaState.audio.priority)
        XCTAssertLessThan(MediaState.audio.priority, MediaState.muted.priority)
        XCTAssertLessThan(MediaState.muted.priority, MediaState().priority)
    }
}

final class MediaFilterTests: XCTestCase {
    func testExactNames() {
        XCTAssertEqual(MediaFilter.parse("@media"), .active)
        XCTAssertEqual(MediaFilter.parse("@camera"), .camera)
        XCTAssertEqual(MediaFilter.parse("@mic"), .microphone)
        XCTAssertEqual(MediaFilter.parse("@screen"), .screen)
        XCTAssertEqual(MediaFilter.parse("@audio"), .audio)
        XCTAssertEqual(MediaFilter.parse("@muted"), .muted)
    }

    func testPrefixes() {
        XCTAssertEqual(MediaFilter.parse("@cam"), .camera)
        // "@m" covers media, mic, microphone and muted.
        XCTAssertEqual(MediaFilter.parse("@m"), MediaState.active.union(.muted))
        XCTAssertEqual(MediaFilter.parse("@"), MediaState.active.union(.muted))
    }

    func testNonFilters() {
        XCTAssertNil(MediaFilter.parse("media"))
        XCTAssertNil(MediaFilter.parse("@xyz"))
    }
}

final class CaptureInferenceTests: XCTestCase {
    private let brave = Browser(name: "Brave", bundleID: "com.brave.Browser", kind: .chromium)

    private func tab(_ url: String, _ media: MediaState, index: Int = 1) -> TabItem {
        var tab = TabItem(browser: brave, windowID: "1", windowNumber: 1, tabIndex: index,
                          tabID: nil, title: "t", url: url, isActive: false)
        tab.media = media
        return tab
    }

    func testMeetingSites() {
        XCTAssertTrue(CaptureInference.isMeetingSite("https://meet.google.com/abc-defg-hij"))
        XCTAssertTrue(CaptureInference.isMeetingSite("https://us02web.zoom.us/wc/123/join"))
        XCTAssertTrue(CaptureInference.isMeetingSite("https://teams.microsoft.com/v2/"))
        XCTAssertFalse(CaptureInference.isMeetingSite("https://www.youtube.com/watch?v=1"))
        XCTAssertFalse(CaptureInference.isMeetingSite("https://notzoom.us/"))
        XCTAssertFalse(CaptureInference.isMeetingSite("not a url"))
    }

    func testMeetingTabPlayingAudioGetsDevicesInUse() {
        let tabs = [tab("https://meet.google.com/abc-defg-hij", .audio),
                    tab("https://www.youtube.com/watch?v=1", .audio, index: 2)]
        let result = CaptureInference.apply([.camera, .microphone], to: tabs)
        XCTAssertEqual(result[0].media, [.audio, .camera, .microphone])
        XCTAssertEqual(result[1].media, .audio)
    }

    func testMutedMeetingTab() {
        let result = CaptureInference.apply(.microphone, to: [tab("https://meet.google.com/x", .muted)])
        XCTAssertEqual(result[0].media, [.muted, .microphone])
    }

    func testSilentMeetingTabIsLeftAlone() {
        let result = CaptureInference.apply(.camera, to: [tab("https://meet.google.com/x", [])])
        XCTAssertEqual(result[0].media, [])
    }

    func testNothingInUse() {
        let result = CaptureInference.apply([], to: [tab("https://meet.google.com/x", .audio)])
        XCTAssertEqual(result[0].media, .audio)
    }

    func testStateAlreadyReportedByTabStrip() {
        let tabs = [tab("https://meet.google.com/x", .audio),
                    tab("https://example.com/", .camera, index: 2)]
        let result = CaptureInference.apply([.camera, .microphone], to: tabs)
        XCTAssertEqual(result[0].media, [.audio, .microphone])
    }

    func testOtherAppUsingMicrophoneIsIgnoredWhenAppAudioIsKnown() {
        // The browser plays audio but doesn't record: the microphone in use
        // belongs to another app, so it isn't passed in.
        let result = CaptureInference.apply([], appAudio: .audio,
                                            to: [tab("https://meet.google.com/x", .audio)])
        XCTAssertEqual(result[0].media, .audio)
    }

    func testWithoutTabStripMeetingTabGetsBrowserAudio() {
        let tabs = [tab("https://meet.google.com/x", []),
                    tab("https://www.youtube.com/watch?v=1", [], index: 2)]
        let result = CaptureInference.apply([.camera, .microphone], appAudio: [.audio, .microphone], to: tabs)
        XCTAssertEqual(result[0].media, [.audio, .camera, .microphone])
        XCTAssertEqual(result[1].media, [])
    }

    func testWithoutTabStripRecordingOnly() {
        let result = CaptureInference.apply(.microphone, appAudio: .microphone,
                                            to: [tab("https://meet.google.com/x", [])])
        XCTAssertEqual(result[0].media, .microphone)
    }

    func testWithoutTabStripSilentBrowser() {
        let result = CaptureInference.apply(.camera, appAudio: [],
                                            to: [tab("https://meet.google.com/x", [])])
        XCTAssertEqual(result[0].media, [])
    }

    func testTabStripStatesWinOverBrowserAudio() {
        // A tab already reports audio, so the browser-wide state isn't spread
        // to the (silent) meeting tab.
        let tabs = [tab("https://meet.google.com/x", []),
                    tab("https://www.youtube.com/watch?v=1", .audio, index: 2)]
        let result = CaptureInference.apply([], appAudio: .audio, to: tabs)
        XCTAssertEqual(result[0].media, [])
        XCTAssertEqual(result[1].media, .audio)
    }
}

/// Reads real CoreAudio state, so it only runs when asked:
/// `TAFFY_LIVE_AUDIO=1 swift test --filter AppAudioLiveTests`.
final class AppAudioLiveTests: XCTestCase {
    func testDetectsAProcessPlayingSound() throws {
        guard ProcessInfo.processInfo.environment["TAFFY_LIVE_AUDIO"] == "1" else {
            throw XCTSkip("set TAFFY_LIVE_AUDIO=1 to run")
        }
        guard #available(macOS 14.2, *) else { throw XCTSkip("needs macOS 14.2") }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0.02", "/System/Library/Sounds/Submarine.aiff"]
        try player.run()
        defer { player.terminate() }

        var usage: MediaState?
        for _ in 0..<20 where usage?.contains(.audio) != true {
            Thread.sleep(forTimeInterval: 0.05)
            usage = AppAudio.usage(pid: player.processIdentifier, bundleURL: nil)
        }
        XCTAssertEqual(usage, .audio)
        XCTAssertEqual(AppAudio.usage(pid: ProcessInfo.processInfo.processIdentifier, bundleURL: nil), [])
    }
}
