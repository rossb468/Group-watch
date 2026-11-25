import Foundation

/// What the local player is doing right now.
public struct PlayerObservation: Equatable {
    /// Media position in seconds.
    public var position: TimeInterval
    /// The player's own pause flag.
    public var paused: Bool
    /// Seeking or buffering: position is not meaningful.
    public var busy: Bool
    /// Current playback speed.
    public var speed: Double
    /// Media duration, if known.
    public var duration: TimeInterval?
    /// Local clock time `position` was read.
    public var time: TimeInterval

    public init(position: TimeInterval, paused: Bool, busy: Bool, speed: Double, duration: TimeInterval?, time: TimeInterval) {
        self.position = position
        self.paused = paused
        self.busy = busy
        self.speed = speed
        self.duration = duration
        self.time = time
    }
}

/// Something the controller wants the player to do.
public enum PlayerCommand: Equatable {
    case pause
    /// Unpause at a local clock time. A time in the past means now. Any later
    /// `pause` or `seek` cancels a scheduled unpause.
    case unpause(at: TimeInterval)
    /// Exact seek to an absolute media position.
    case seek(to: TimeInterval)
    case setSpeed(Double)
}

public struct SyncConfig {
    /// Start nudging speed when average error exceeds this.
    public var correctionEnter: TimeInterval = 0.040
    /// Stop nudging once average error is back under this.
    public var correctionExit: TimeInterval = 0.012
    /// Beyond this error, re-seek instead of nudging.
    public var hardSeekThreshold: TimeInterval = 0.75
    /// Largest speed change used for nudging (0.04 = ±4%).
    public var maxRateAdjust: Double = 0.04
    /// Aim to remove the current error over roughly this many seconds.
    public var correctionHorizon: TimeInterval = 2.0
    /// When paused (or waiting to start), tolerate this much position error before seeking.
    public var pausedTolerance: TimeInterval = 0.08
    /// Number of error samples averaged. Averaging cancels frame-quantization noise.
    public var errorWindow = 12
    /// Initial guess at how long an exact seek takes; refined by measurement.
    public var initialSeekLatency: TimeInterval = 0.25
    /// Give up waiting on a seek that has not finished after this long.
    public var seekTimeout: TimeInterval = 3.0

    public init() {}
}

/// Drives the local player toward the group's `PlaybackState`.
///
/// Pure logic: feed it observations, apply the commands it returns. Call
/// `update` often (every 20–50 ms).
///
/// - Paused group state: pause and sit on the exact frame.
/// - Scheduled start: pause on the start frame, unpause at the start time.
/// - Playing: average the position error; nudge speed by a few percent to
///   close small gaps invisibly; re-seek (with a scheduled resume) for big ones.
public struct SyncController {
    public var config: SyncConfig

    private enum Phase: Equatable {
        case idle
        /// Waiting to unpause at `resumeAt` for the state with `version`.
        case starting(version: StateVersion, resumeAt: TimeInterval, scheduled: Bool)
        case tracking
    }

    private struct PendingSeek {
        var target: TimeInterval
        var issuedAt: TimeInterval
        var version: StateVersion
    }

    private var phase: Phase = .idle
    private var pendingSeek: PendingSeek?
    private var errors: [TimeInterval] = []
    private var correcting = false
    private var seekLatency: TimeInterval
    /// The state version the tracking loop last ran against.
    private var trackedVersion: StateVersion?

    /// Latest averaged error (local minus target), for diagnostics. Nil when not tracking.
    public private(set) var currentError: TimeInterval?

    public init(config: SyncConfig = SyncConfig()) {
        self.config = config
        self.seekLatency = config.initialSeekLatency
    }

    /// How far ahead to schedule a start that needs a seek on this machine.
    public var suggestedStartLead: TimeInterval {
        min(2.0, max(0.15, seekLatency * 1.5 + 0.08))
    }

    /// Measured exact-seek time on this machine.
    public var measuredSeekLatency: TimeInterval { seekLatency }

    /// Forget everything (new file loaded).
    public mutating func reset() {
        phase = .idle
        pendingSeek = nil
        errors = []
        correcting = false
        currentError = nil
        trackedVersion = nil
    }

    public mutating func update(target: PlaybackState?, observed: PlayerObservation, now: TimeInterval) -> [PlayerCommand] {
        guard let target else {
            phase = .idle
            currentError = nil
            return []
        }

        // Wait out an in-flight seek, unless the group moved on.
        if let seek = pendingSeek {
            let landed = !observed.busy && abs(observed.position - seek.target) < 0.5
            let landedAtEnd = !observed.busy && (observed.duration.map { seek.target >= $0 - 0.5 } ?? false)
            if landed || landedAtEnd {
                let measured = now - seek.issuedAt
                seekLatency = seekLatency * 0.7 + min(measured, 2.0) * 0.3
                pendingSeek = nil
            } else if now - seek.issuedAt > config.seekTimeout {
                pendingSeek = nil
            } else if seek.version == target.version {
                return []
            }
        }
        if observed.busy && pendingSeek == nil {
            // Buffering or a seek we did not start. Nothing sensible to do yet.
            return []
        }

        if !target.playing {
            return holdPaused(at: target.position, target: target, observed: observed, now: now)
        }

        // Past the end of the file: stop there instead of seeking forever.
        if let duration = observed.duration, duration > 0, target.position(at: now) >= duration - 0.1 {
            return holdPaused(at: nil, target: target, observed: observed, now: now)
        }

        // Waiting for a scheduled unpause.
        if case let .starting(version, resumeAt, scheduled) = phase, version == target.version {
            if pendingSeek != nil { return [] }
            if !scheduled {
                phase = .starting(version: version, resumeAt: resumeAt, scheduled: true)
                return [.unpause(at: resumeAt)]
            }
            if observed.paused && now < resumeAt + 0.5 { return [] }
            phase = .tracking
            errors = []
            correcting = false
        }

        // A start in the future: sit on the start frame, then go at the agreed time.
        if target.isPendingStart(at: now) {
            var commands: [PlayerCommand] = []
            if !observed.paused { commands.append(.pause) }
            if abs(observed.speed - target.rate) > 0.0005 { commands.append(.setSpeed(target.rate)) }
            if abs(observed.position - target.position) > config.pausedTolerance {
                commands.append(seek(to: target.position, version: target.version, now: now))
                phase = .starting(version: target.version, resumeAt: target.referenceTime, scheduled: false)
            } else {
                phase = .starting(version: target.version, resumeAt: target.referenceTime, scheduled: true)
                commands.append(.unpause(at: target.referenceTime))
            }
            currentError = nil
            return commands
        }

        // A start we heard about slightly late: go now and let speed nudging
        // absorb the small gap, rather than paying for a seek.
        let lateness = now - target.referenceTime
        if observed.paused, phase == .idle, lateness < 0.15,
           abs(observed.position - target.position) <= config.pausedTolerance {
            phase = .tracking
            errors = []
            correcting = false
            var commands: [PlayerCommand] = []
            if abs(observed.speed - target.rate) > 0.0005 { commands.append(.setSpeed(target.rate)) }
            commands.append(.unpause(at: now))
            return commands
        }

        // Playing. If we are not, or are far off, re-align with a scheduled resume.
        if observed.paused || phase == .idle {
            return align(target: target, observed: observed, now: now)
        }

        let error = observed.position - target.position(at: observed.time)
        // A fresh state (someone seeked) that we are not already on: jump, don't drift.
        let isNewVersion = trackedVersion != target.version
        trackedVersion = target.version
        if abs(error) > config.hardSeekThreshold || (isNewVersion && abs(error) > 0.1) {
            return align(target: target, observed: observed, now: now)
        }

        phase = .tracking
        errors.append(error)
        if errors.count > config.errorWindow { errors.removeFirst(errors.count - config.errorWindow) }
        guard errors.count >= min(4, config.errorWindow) else { return [] }

        let average = errors.reduce(0, +) / Double(errors.count)
        currentError = average
        if correcting {
            if abs(average) < config.correctionExit { correcting = false }
        } else if abs(average) > config.correctionEnter {
            correcting = true
        }

        var desired = target.rate
        if correcting {
            let adjust = max(-config.maxRateAdjust, min(config.maxRateAdjust, average / config.correctionHorizon))
            desired = target.rate * (1 - adjust)
        }
        if abs(desired - observed.speed) > 0.002 || (desired == target.rate && observed.speed != target.rate) {
            return [.setSpeed(desired)]
        }
        return []
    }

    // MARK: - Helpers

    private mutating func holdPaused(at position: TimeInterval?, target: PlaybackState, observed: PlayerObservation, now: TimeInterval) -> [PlayerCommand] {
        phase = .idle
        errors = []
        correcting = false
        currentError = nil
        var commands: [PlayerCommand] = []
        if !observed.paused { commands.append(.pause) }
        if observed.speed != target.rate { commands.append(.setSpeed(target.rate)) }
        if let position, pendingSeek == nil, abs(observed.position - position) > config.pausedTolerance {
            commands.append(seek(to: position, version: target.version, now: now))
        }
        return commands
    }

    private mutating func align(target: PlaybackState, observed: PlayerObservation, now: TimeInterval) -> [PlayerCommand] {
        let resumeAt = now + suggestedStartLead
        var destination = target.position(at: resumeAt)
        if let duration = observed.duration, duration > 0 { destination = min(destination, duration) }
        var commands: [PlayerCommand] = []
        if !observed.paused { commands.append(.pause) }
        if observed.speed != target.rate { commands.append(.setSpeed(target.rate)) }
        commands.append(seek(to: destination, version: target.version, now: now))
        phase = .starting(version: target.version, resumeAt: resumeAt, scheduled: false)
        errors = []
        correcting = false
        currentError = nil
        return commands
    }

    private mutating func seek(to position: TimeInterval, version: StateVersion, now: TimeInterval) -> PlayerCommand {
        pendingSeek = PendingSeek(target: position, issuedAt: now, version: version)
        return .seek(to: position)
    }
}
