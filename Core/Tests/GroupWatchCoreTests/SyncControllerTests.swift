import XCTest
@testable import GroupWatchCore

final class SyncControllerTests: XCTestCase {
    private func playing(at position: TimeInterval, ref: TimeInterval, counter: UInt64 = 1) -> PlaybackState {
        PlaybackState(playing: true, position: position, referenceTime: ref, version: StateVersion(counter: counter, origin: "x"))
    }

    func testJoinsPlaybackInProgress() {
        var rig = Rig()
        let state = playing(at: 600, ref: rig.now)
        rig.run(seconds: 3) { state }
        XCTAssertFalse(rig.player.paused)
        XCTAssertEqual(rig.error(against: state), 0, accuracy: 0.03)
        XCTAssertLessThanOrEqual(rig.player.seekCount, 2)
    }

    func testClosesSmallGapWithoutSeeking() {
        var rig = Rig()
        let state = playing(at: 100, ref: rig.now)
        rig.run(seconds: 3) { state }
        rig.player.truePosition += 0.2
        let seeksBefore = rig.player.seekCount
        rig.run(seconds: 15) { state }
        XCTAssertEqual(rig.player.seekCount, seeksBefore, "a 200 ms gap is closed by speed alone")
        XCTAssertGreaterThan(rig.player.speedChanges, 0)
        XCTAssertEqual(rig.error(against: state), 0, accuracy: 0.04)
    }

    func testHoldsAgainstHardwareClockDrift() {
        var rig = Rig()
        rig.player.hardwareDrift = 1.002 // 7 seconds an hour fast
        let state = playing(at: 0, ref: rig.now)
        rig.run(seconds: 120) { state }
        XCTAssertEqual(rig.error(against: state), 0, accuracy: 0.05)
        XCTAssertLessThanOrEqual(rig.player.seekCount, 2, "drift is corrected by speed, not seeks")
    }

    func testPausesOnTheExactFrame() {
        var rig = Rig()
        rig.player.paused = false
        rig.player.truePosition = 50
        let state = PlaybackState(playing: false, position: 42, referenceTime: rig.now, version: StateVersion(counter: 1, origin: "x"))
        rig.run(seconds: 1) { state }
        XCTAssertTrue(rig.player.paused)
        XCTAssertEqual(rig.player.truePosition, 42, accuracy: 0.001)
        XCTAssertEqual(rig.player.seekCount, 1, "no re-seek loop on frame quantization")
    }

    func testScheduledStartBeginsOnTime() {
        var a = Rig()
        var b = Rig()
        b.player.seekLatency = 0.3
        b.player.truePosition = 9 // b is elsewhere and must seek first
        let start = a.now + 0.6
        let state = playing(at: 10, ref: start)
        a.player.truePosition = 10
        a.run(seconds: 2) { state }
        b.run(seconds: 2) { state }
        XCTAssertEqual(a.error(against: state), 0, accuracy: 0.03)
        XCTAssertEqual(b.error(against: state), 0, accuracy: 0.03)
        XCTAssertEqual(a.player.seekCount, 0, "already on the start frame")
    }

    func testSeekWhilePlayingJumpsInsteadOfDrifting() {
        var rig = Rig()
        var state = playing(at: 100, ref: rig.now)
        rig.run(seconds: 3) { state }
        let seeks = rig.player.seekCount
        state = playing(at: state.position(at: rig.now) + 0.5, ref: rig.now, counter: 2)
        rig.run(seconds: 2) { state }
        XCTAssertGreaterThan(rig.player.seekCount, seeks)
        XCTAssertEqual(rig.error(against: state), 0, accuracy: 0.03)
    }

    func testStopsAtEndOfFile() {
        var rig = Rig()
        rig.player.duration = 60
        let state = playing(at: 59, ref: rig.now)
        rig.run(seconds: 5) { state }
        let seeks = rig.player.seekCount
        rig.run(seconds: 5) { state }
        XCTAssertEqual(rig.player.seekCount, seeks, "no seek loop past the end")
        XCTAssertTrue(rig.player.paused)
    }

    func testLearnsSlowSeeks() {
        var rig = Rig()
        rig.player.seekLatency = 0.8
        var state = playing(at: 0, ref: rig.now)
        for i in 1...5 {
            state = playing(at: Double(i) * 100, ref: rig.now, counter: UInt64(i))
            rig.run(seconds: 3) { state }
        }
        XCTAssertGreaterThan(rig.controller.suggestedStartLead, 0.8)
        XCTAssertEqual(rig.error(against: state), 0, accuracy: 0.04)
    }
}
