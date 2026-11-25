import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A monotonic clock, in seconds. Never jumps when the wall clock is changed.
///
/// Each peer has its own clock with an arbitrary epoch; `ClockOffsetEstimator`
/// learns the difference between two peers' clocks.
public protocol MonotonicClock: AnyObject {
    func now() -> TimeInterval
}

public final class SystemClock: MonotonicClock {
    public init() {}

    public func now() -> TimeInterval {
        var ts = timespec()
        clock_gettime(CLOCK_MONOTONIC, &ts)
        return TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000
    }
}

/// A clock you move by hand. For tests and simulations.
public final class ManualClock: MonotonicClock {
    public var time: TimeInterval

    public init(_ start: TimeInterval = 1000) { time = start }

    public func now() -> TimeInterval { time }

    public func advance(_ dt: TimeInterval) { time += dt }
}
