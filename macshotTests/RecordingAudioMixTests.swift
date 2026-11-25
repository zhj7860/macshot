import XCTest

final class RecordingAudioMixTests: XCTestCase {

    func testMixAppliesOnlyWhenBothSourcesRecordedAndAudioIsKept() {
        XCTAssertTrue(RecordingAudioMix.shouldMix(systemAudio: true, microphone: true, isGIF: false))
        XCTAssertFalse(RecordingAudioMix.shouldMix(systemAudio: false, microphone: true, isGIF: false))
        XCTAssertFalse(RecordingAudioMix.shouldMix(systemAudio: true, microphone: false, isGIF: false))
        XCTAssertFalse(RecordingAudioMix.shouldMix(systemAudio: false, microphone: false, isGIF: false))
        // GIF output drops audio, so a mix would only add work.
        XCTAssertFalse(RecordingAudioMix.shouldMix(systemAudio: true, microphone: true, isGIF: true))
    }

    func testMixedCopyStaysInTheTakeFolderAndKeepsTheExtension() {
        let take = URL(fileURLWithPath: "/library/Screen Recording 2026-11-15.mp4")
        let mixed = RecordingAudioMix.destination(beside: take)
        XCTAssertEqual(mixed.deletingLastPathComponent(), take.deletingLastPathComponent())
        XCTAssertEqual(mixed.lastPathComponent, "Screen Recording 2026-11-15 (mixed).mp4")
        XCTAssertNotEqual(mixed, take)
        XCTAssertEqual(RecordingAudioMix.destination(beside: URL(fileURLWithPath: "/tmp/take")).lastPathComponent,
                       "take (mixed).mp4")
    }

    @MainActor
    func testCombinedToolbarButtonIsSelectedOnlyWhenBothSourcesAreOn() {
        for (system, mic, expected) in [(true, true, true), (true, false, false),
                                        (false, true, false), (false, false, false)] {
            withDefaults(["recordSystemAudio": system, "recordMicAudio": mic]) {
                let buttons = ToolbarLayout.rightButtons(isRecording: true)
                let combined = buttons.first { if case .combinedAudio = $0.action { return true }; return false }
                XCTAssertEqual(combined?.isSelected, expected,
                               "system=\(system) mic=\(mic)")
            }
        }
    }
}
