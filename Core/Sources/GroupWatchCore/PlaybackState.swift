import Foundation

/// Orders playback states across peers. Higher counter wins; ties break on
/// the origin peer ID, so every peer picks the same winner.
public struct StateVersion: Codable, Hashable, Comparable {
    public var counter: UInt64
    public var origin: String

    public init(counter: UInt64, origin: String) {
        self.counter = counter
        self.origin = origin
    }

    public static let zero = StateVersion(counter: 0, origin: "")

    public static func < (a: StateVersion, b: StateVersion) -> Bool {
        if a.counter != b.counter { return a.counter < b.counter }
        return a.origin < b.origin
    }
}

/// The group's shared idea of where playback is.
///
/// `position` is the media time at `referenceTime`. `referenceTime` is on the
/// clock of whoever holds the value: on the wire it is the sender's clock, and
/// `Session` converts it to ours on receipt.
///
/// A playing state whose `referenceTime` is in the future means "be paused at
/// `position` and start at `referenceTime`". That is how play and seek get
/// everyone moving at the same instant.
public struct PlaybackState: Codable, Equatable {
    public var playing: Bool
    public var position: TimeInterval
    public var referenceTime: TimeInterval
    public var rate: Double
    public var version: StateVersion

    public init(playing: Bool, position: TimeInterval, referenceTime: TimeInterval, rate: Double = 1, version: StateVersion) {
        self.playing = playing
        self.position = position
        self.referenceTime = referenceTime
        self.rate = rate
        self.version = version
    }

    /// Where playback should be at `time` (same clock as `referenceTime`).
    /// Before a scheduled start this is the start position.
    public func position(at time: TimeInterval) -> TimeInterval {
        guard playing, time > referenceTime else { return position }
        return position + (time - referenceTime) * rate
    }

    /// True if this state is a start scheduled after `time`.
    public func isPendingStart(at time: TimeInterval) -> Bool {
        playing && referenceTime > time
    }

    /// The same state, expressed on a clock that reads `delta` more than this one.
    public func shiftingClock(by delta: TimeInterval) -> PlaybackState {
        var s = self
        s.referenceTime += delta
        return s
    }
}
