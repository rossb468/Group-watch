import Foundation

/// Estimates the offset between our monotonic clock and a remote peer's,
/// NTP style.
///
/// For a ping we send at local `t0`, the peer stamps receipt `t1` and reply
/// `t2` (its clock), and we receive the pong at local `t3`:
///
///     offset = ((t1 - t0) + (t2 - t3)) / 2     // remote - local
///     rtt    = (t3 - t0) - (t2 - t1)
///
/// The sample with the smallest round trip has the least queuing noise, so
/// the estimate is the offset of the lowest-RTT sample in a recent window.
public struct ClockOffsetEstimator {
    public struct Sample: Equatable {
        public var offset: TimeInterval
        public var rtt: TimeInterval
        public var takenAt: TimeInterval
    }

    /// Samples kept. At one ping every 2 s this is about a minute of history,
    /// short enough to follow slow clock drift between machines.
    public var capacity = 30
    /// Samples needed before the estimate is trusted.
    public var minimumSamples = 3

    public private(set) var samples: [Sample] = []

    public init() {}

    public var isSynced: Bool { samples.count >= minimumSamples }

    /// Remote clock minus local clock. Zero until the first sample arrives.
    public var offset: TimeInterval { best?.offset ?? 0 }

    /// Round trip of the best sample.
    public var rtt: TimeInterval { best?.rtt ?? 0 }

    /// A smoothed round trip of recent samples, for picking start delays.
    public var typicalRTT: TimeInterval {
        guard !samples.isEmpty else { return 0 }
        let recent = samples.suffix(8).map(\.rtt).sorted()
        return recent[recent.count / 2]
    }

    private var best: Sample? { samples.min { $0.rtt < $1.rtt } }

    public mutating func add(t0: TimeInterval, t1: TimeInterval, t2: TimeInterval, t3: TimeInterval) {
        let rtt = max(0, (t3 - t0) - (t2 - t1))
        let offset = ((t1 - t0) + (t2 - t3)) / 2
        samples.append(Sample(offset: offset, rtt: rtt, takenAt: t3))
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    /// Converts a time on the remote clock to our clock.
    public func toLocal(_ remoteTime: TimeInterval) -> TimeInterval { remoteTime - offset }

    /// Converts a time on our clock to the remote clock.
    public func toRemote(_ localTime: TimeInterval) -> TimeInterval { localTime + offset }
}
