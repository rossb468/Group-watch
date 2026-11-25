import Foundation
@testable import GroupWatchCore

/// A pretend video player with the rough habits of mpv: seeks take time,
/// reported position is quantized to frames, and the hardware clock runs a
/// touch fast or slow.
final class SimPlayer {
    var truePosition: TimeInterval = 0
    var paused = true
    var speed: Double = 1
    var duration: TimeInterval = 7200
    /// Real playback rate relative to the controlling clock (sound card drift).
    var hardwareDrift: Double = 1
    var seekLatency: TimeInterval = 0.12
    var frameDuration: TimeInterval = 1.0 / 24

    private(set) var seekCount = 0
    private(set) var speedChanges = 0
    private var seekingUntil: TimeInterval?
    private var seekTarget: TimeInterval = 0
    private var scheduledUnpause: TimeInterval?

    var busy: Bool { seekingUntil != nil }

    func observe(at now: TimeInterval) -> PlayerObservation {
        let reported = (truePosition / frameDuration).rounded() * frameDuration
        return PlayerObservation(position: busy ? seekTarget : reported, paused: paused, busy: busy, speed: speed, duration: duration, time: now)
    }

    func apply(_ commands: [PlayerCommand], now: TimeInterval) {
        for command in commands {
            switch command {
            case .pause:
                paused = true
                scheduledUnpause = nil
            case let .unpause(at):
                if at <= now { paused = false; scheduledUnpause = nil } else { scheduledUnpause = at }
            case let .seek(to):
                seekCount += 1
                scheduledUnpause = nil
                seekTarget = min(to, duration)
                seekingUntil = now + seekLatency
            case let .setSpeed(s):
                speedChanges += 1
                speed = s
            }
        }
    }

    /// Advances real time by `dt`.
    func advance(from now: TimeInterval, by dt: TimeInterval) {
        let end = now + dt
        var t = now
        if let until = seekingUntil {
            if until > end { return }
            t = max(t, until)
            truePosition = seekTarget
            seekingUntil = nil
        }
        if paused, let at = scheduledUnpause, at <= end {
            // Play only the part of the step after the scheduled time.
            t = max(t, at)
            paused = false
            scheduledUnpause = nil
        }
        if !paused {
            truePosition = min(duration, truePosition + (end - t) * speed * hardwareDrift)
            if truePosition >= duration { paused = true }
        }
    }
}

/// Runs one controller against one simulated player.
struct Rig {
    var controller = SyncController()
    let player = SimPlayer()
    var now: TimeInterval = 1000

    mutating func run(seconds: TimeInterval, tick: TimeInterval = 0.02, target: () -> PlaybackState?) {
        let steps = Int((seconds / tick).rounded())
        for _ in 0..<steps {
            let commands = controller.update(target: target(), observed: player.observe(at: now), now: now)
            player.apply(commands, now: now)
            player.advance(from: now, by: tick)
            now += tick
        }
    }

    func error(against state: PlaybackState) -> TimeInterval {
        player.truePosition - state.position(at: now)
    }
}

/// Connects sessions through an in-memory network with latency.
final class SimNetwork {
    struct Packet {
        var deliverAt: TimeInterval
        var data: Data
        var from: String
        var to: String
    }

    var realTime: TimeInterval = 0
    var oneWayDelay: TimeInterval = 0.04
    var jitter: TimeInterval = 0.01
    private var packets: [Packet] = []
    private var sessions: [String: Session] = [:]
    private var clocks: [String: (ManualClock, TimeInterval)] = [:]
    private var rng = SeededRandom(seed: 42)

    func add(_ session: Session, clock: ManualClock, offset: TimeInterval) {
        sessions[session.localPeerID] = session
        clocks[session.localPeerID] = (clock, offset)
        clock.time = realTime + offset
    }

    func connect(_ a: String, _ b: String) {
        sessions[a]!.addPeer(id: b) { [unowned self] data, _ in self.send(data, from: a, to: b) }
        sessions[b]!.addPeer(id: a) { [unowned self] data, _ in self.send(data, from: b, to: a) }
    }

    private func send(_ data: Data, from: String, to: String) {
        let delay = oneWayDelay + Double.random(in: 0...jitter, using: &rng)
        packets.append(Packet(deliverAt: realTime + delay, data: data, from: from, to: to))
    }

    func advance(by dt: TimeInterval, tick: (() -> Void)? = nil) {
        let end = realTime + dt
        while true {
            packets.sort { $0.deliverAt < $1.deliverAt }
            guard let next = packets.first, next.deliverAt <= end else { break }
            packets.removeFirst()
            setTime(next.deliverAt)
            sessions[next.to]?.receive(next.data, from: next.from)
        }
        setTime(end)
        for s in sessions.values { s.tick() }
        tick?()
    }

    private func setTime(_ t: TimeInterval) {
        realTime = t
        for (clock, offset) in clocks.values { clock.time = t + offset }
    }
}

struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
