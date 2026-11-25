import XCTest
@testable import GroupWatchCore

/// Records delegate callbacks.
final class Recorder: SessionDelegate {
    var stateChanges = 0
    var chats: [ChatMessage] = []
    var reactions: [Reaction] = []
    var peerChanges = 0
    func sessionDidChangeState(_ session: Session) { stateChanges += 1 }
    func session(_ session: Session, didReceiveChat message: ChatMessage) { chats.append(message) }
    func session(_ session: Session, didReceiveReaction reaction: Reaction) { reactions.append(reaction) }
    func sessionPeersDidChange(_ session: Session) { peerChanges += 1 }
}

final class SessionTests: XCTestCase {
    let media = MediaInfo(fileName: "movie.mkv", fileSize: 1, duration: 7200, fingerprint: "f")

    private func makePair(offsetB: TimeInterval = 5_000) -> (SimNetwork, Session, ManualClock, Session, ManualClock) {
        let net = SimNetwork()
        let clockA = ManualClock(), clockB = ManualClock()
        let a = Session(peerID: "a", displayName: "Ann", clock: clockA)
        let b = Session(peerID: "b", displayName: "Bob", clock: clockB)
        net.add(a, clock: clockA, offset: 100)
        net.add(b, clock: clockB, offset: offsetB)
        return (net, a, clockA, b, clockB)
    }

    /// Both sessions' states describe the same real-time position.
    private func assertAgree(_ a: Session, _ clockA: ManualClock, _ b: Session, _ clockB: ManualClock, accuracy: TimeInterval = 0.01, file: StaticString = #filePath, line: UInt = #line) {
        guard let sa = a.state, let sb = b.state else { return XCTFail("missing state", file: file, line: line) }
        XCTAssertEqual(sa.version, sb.version, file: file, line: line)
        XCTAssertEqual(sa.playing, sb.playing, file: file, line: line)
        XCTAssertEqual(sa.position(at: clockA.now() + 10), sb.position(at: clockB.now() + 10), accuracy: accuracy, file: file, line: line)
    }

    func testLateJoinerAdoptsRunningState() {
        let (net, a, clockA, b, clockB) = makePair()
        a.mediaLoaded(media)
        a.play()
        net.advance(by: 30)
        b.mediaLoaded(media)
        net.connect("a", "b")
        for _ in 0..<20 { net.advance(by: 0.05) }
        XCTAssertTrue(b.state?.playing ?? false)
        assertAgree(a, clockA, b, clockB)
        XCTAssertEqual(b.mediaMatch(for: b.peers[0]), .same)
        XCTAssertEqual(b.peers.first?.name, "Ann")
    }

    func testEitherSideControlsPlayback() {
        let (net, a, clockA, b, clockB) = makePair()
        a.mediaLoaded(media)
        b.mediaLoaded(media)
        net.connect("a", "b")
        for _ in 0..<20 { net.advance(by: 0.05) }

        b.play()
        net.advance(by: 0.5)
        assertAgree(a, clockA, b, clockB)
        XCTAssertTrue(a.state!.playing)

        net.advance(by: 10)
        a.seek(to: 1234)
        net.advance(by: 0.5)
        assertAgree(a, clockA, b, clockB)

        b.pause()
        net.advance(by: 0.5)
        assertAgree(a, clockA, b, clockB)
        XCTAssertFalse(a.state!.playing)
    }

    func testScheduledStartLeavesTimeForTheNetwork() {
        let (net, a, clockA, b, _) = makePair()
        net.oneWayDelay = 0.12
        a.mediaLoaded(media)
        b.mediaLoaded(media)
        net.connect("a", "b")
        for _ in 0..<20 { net.advance(by: 0.05) }
        a.play()
        let start = a.state!.referenceTime
        XCTAssertGreaterThan(start - clockA.now(), 0.12, "start must be after the state reaches b")
        _ = b
    }

    func testConcurrentActionsConverge() {
        let (net, a, clockA, b, clockB) = makePair()
        a.mediaLoaded(media)
        b.mediaLoaded(media)
        net.connect("a", "b")
        for _ in 0..<20 { net.advance(by: 0.05) }
        a.seek(to: 100)
        b.seek(to: 200)
        net.advance(by: 0.5)
        assertAgree(a, clockA, b, clockB)
        XCTAssertEqual(a.state!.position, 200, "same counter, higher origin wins")
    }

    func testFreshFileDoesNotOverrideTheRoom() {
        let (net, a, clockA, b, clockB) = makePair()
        a.mediaLoaded(media)
        a.seek(to: 300)
        b.mediaLoaded(media) // version zero
        net.connect("a", "b")
        for _ in 0..<20 { net.advance(by: 0.05) }
        assertAgree(a, clockA, b, clockB)
        XCTAssertEqual(b.state!.position, 300)
    }

    func testJoinerWithoutFileStillLearnsState() {
        let (net, a, clockA, b, clockB) = makePair()
        a.mediaLoaded(media)
        a.seek(to: 77)
        net.connect("a", "b")
        for _ in 0..<20 { net.advance(by: 0.05) }
        XCTAssertNil(b.localMedia)
        b.mediaLoaded(media)
        assertAgree(a, clockA, b, clockB)
        XCTAssertEqual(b.peers.first?.media, media)
    }

    func testChatAndReactions() {
        let (net, a, _, b, _) = makePair()
        let rb = Recorder()
        b.delegate = rb
        a.mediaLoaded(media)
        net.connect("a", "b")
        a.sendChat("this part!")
        a.sendReaction("😱")
        net.advance(by: 0.5)
        XCTAssertEqual(rb.chats.map(\.text), ["this part!"])
        XCTAssertEqual(rb.chats.first?.name, "Ann")
        XCTAssertEqual(rb.reactions.map(\.emoji), ["😱"])
    }

    func testThreePeerMesh() {
        let net = SimNetwork()
        let clocks = (0..<3).map { _ in ManualClock() }
        let sessions = ["a", "b", "c"].enumerated().map { i, id in
            Session(peerID: id, displayName: id, clock: clocks[i])
        }
        for (i, s) in sessions.enumerated() {
            net.add(s, clock: clocks[i], offset: Double(i) * 777)
            s.mediaLoaded(media)
        }
        net.connect("a", "b")
        net.connect("a", "c")
        net.connect("b", "c")
        for _ in 0..<20 { net.advance(by: 0.05) }
        sessions[2].play()
        net.advance(by: 1)
        sessions[1].seek(to: 500)
        net.advance(by: 1)
        for i in 1..<3 {
            assertAgree(sessions[0], clocks[0], sessions[i], clocks[i])
        }
    }

    func testRemovingPeer() {
        let (net, a, _, _, _) = makePair()
        net.connect("a", "b")
        XCTAssertEqual(a.peers.count, 1)
        a.removePeer(id: "b")
        XCTAssertTrue(a.peers.isEmpty)
    }
}
