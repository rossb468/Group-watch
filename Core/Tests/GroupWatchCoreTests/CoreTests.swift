import XCTest
@testable import GroupWatchCore

final class ClockSyncTests: XCTestCase {
    func testRecoversOffsetDespiteAsymmetricJitter() {
        var estimator = ClockOffsetEstimator()
        var rng = SeededRandom(seed: 7)
        let trueOffset = 12_345.678
        var local: TimeInterval = 100
        for _ in 0..<30 {
            let up = 0.02 + Double.random(in: 0...0.05, using: &rng)
            let down = 0.02 + Double.random(in: 0...0.05, using: &rng)
            let t0 = local
            let t1 = t0 + up + trueOffset
            let t2 = t1 + 0.0005
            let t3 = t2 - trueOffset + down
            estimator.add(t0: t0, t1: t1, t2: t2, t3: t3)
            local = t3 + 0.5
        }
        XCTAssertTrue(estimator.isSynced)
        XCTAssertEqual(estimator.offset, trueOffset, accuracy: 0.01)
        XCTAssertEqual(estimator.toLocal(estimator.toRemote(5)), 5, accuracy: 1e-9)
    }
}

final class PlaybackStateTests: XCTestCase {
    func testPositionExtrapolation() {
        let v = StateVersion(counter: 1, origin: "a")
        let playing = PlaybackState(playing: true, position: 10, referenceTime: 100, version: v)
        XCTAssertEqual(playing.position(at: 105), 15, accuracy: 1e-9)
        XCTAssertEqual(playing.position(at: 99), 10, accuracy: 1e-9, "before a scheduled start, sit on the start position")
        XCTAssertTrue(playing.isPendingStart(at: 99))
        let paused = PlaybackState(playing: false, position: 10, referenceTime: 100, version: v)
        XCTAssertEqual(paused.position(at: 500), 10)
    }

    func testVersionOrdering() {
        XCTAssertLessThan(StateVersion(counter: 1, origin: "z"), StateVersion(counter: 2, origin: "a"))
        XCTAssertLessThan(StateVersion(counter: 2, origin: "a"), StateVersion(counter: 2, origin: "b"))
        XCTAssertLessThan(StateVersion.zero, StateVersion(counter: 0, origin: "a"))
    }
}

final class ProtocolTests: XCTestCase {
    func testRoundTripsEveryMessage() {
        let state = PlaybackState(playing: true, position: 1.5, referenceTime: 9, version: StateVersion(counter: 3, origin: "p"))
        let media = MediaInfo(fileName: "a.mkv", fileSize: 42, duration: 5400, fingerprint: "abc")
        let messages: [WireMessage] = [
            .hello(Hello(peerID: "p", name: "Ross", protocolVersion: 1, appVersion: "1.0", media: media, state: state)),
            .ping(ClockPing(id: 1, t0: 2)),
            .pong(ClockPong(id: 1, t0: 2, t1: 3, t2: 4, lead: 0.3)),
            .state(state),
            .chat(ChatMessage(id: "c", from: "p", name: "Ross", text: "hi 👋", mediaTime: 3, sentAt: Date(timeIntervalSince1970: 1_700_000_000))),
            .reaction(Reaction(id: "r", from: "p", name: "Ross", emoji: "😂", mediaTime: 3)),
            .media(media),
            .media(nil),
        ]
        for message in messages {
            XCTAssertEqual(WireCodec.decode(WireCodec.encode(message)), message)
        }
    }

    func testWireFormatIsTypeTagged() throws {
        let data = WireCodec.encode(.ping(ClockPing(id: 7, t0: 1)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["t"] as? String, "ping")
        XCTAssertNotNil(json["v"] as? [String: Any])
    }

    func testIgnoresGarbage() {
        XCTAssertNil(WireCodec.decode(Data("nope".utf8)))
        XCTAssertNil(WireCodec.decode(Data(#"{"t":"future-thing","v":{}}"#.utf8)))
    }

    func testMediaMatch() {
        let a = MediaInfo(fileName: "a", fileSize: 1, duration: 100, fingerprint: "x")
        var b = a
        XCTAssertEqual(MediaMatch.compare(a, b), .same)
        b.fingerprint = "y"
        XCTAssertEqual(MediaMatch.compare(a, b), .similar)
        b.duration = 200
        XCTAssertEqual(MediaMatch.compare(a, b), .different)
        XCTAssertEqual(MediaMatch.compare(a, nil), .unknown)
    }
}

final class RoomCodeTests: XCTestCase {
    func testGenerateAndParse() {
        for _ in 0..<100 {
            let code = RoomCode.generate()
            XCTAssertEqual(code.count, 6)
            XCTAssertEqual(RoomCode.parse(code), code)
            XCTAssertEqual(RoomCode.parse(RoomCode.display(code).lowercased()), code)
        }
    }

    func testParsesLinks() {
        XCTAssertEqual(RoomCode.parse("groupwatch://join/ABCDEF"), "ABCDEF")
        XCTAssertEqual(RoomCode.parse("https://gw.example.workers.dev/j/ABC-DEF"), "ABCDEF")
        XCTAssertEqual(RoomCode.parse("  abc def \n"), "ABCDEF")
        XCTAssertNil(RoomCode.parse("ABCDE"))
        XCTAssertNil(RoomCode.parse("ABCDE0"), "0 is not in the alphabet")
    }
}
