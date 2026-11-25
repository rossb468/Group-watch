import Foundation

/// Peer-to-peer wire protocol. JSON objects of the form `{"t": type, "v": body}`.
/// See docs/PROTOCOL.md.
public enum WireProtocol {
    public static let version = 1
}

public struct MediaInfo: Codable, Equatable, Hashable {
    public var fileName: String
    public var fileSize: Int64
    public var duration: TimeInterval
    /// Hash of file size plus the first and last few MB. Identical files match.
    public var fingerprint: String

    public init(fileName: String, fileSize: Int64, duration: TimeInterval, fingerprint: String) {
        self.fileName = fileName
        self.fileSize = fileSize
        self.duration = duration
        self.fingerprint = fingerprint
    }
}

public enum MediaMatch: Equatable {
    /// One side has not loaded a file yet.
    case unknown
    /// Same file.
    case same
    /// Different files of about the same length. Probably the same title, a different release.
    case similar
    /// Different videos.
    case different

    public static func compare(_ a: MediaInfo?, _ b: MediaInfo?) -> MediaMatch {
        guard let a, let b else { return .unknown }
        if a.fingerprint == b.fingerprint { return .same }
        if a.duration > 0, b.duration > 0, abs(a.duration - b.duration) < 3 { return .similar }
        return .different
    }
}

public struct Hello: Codable, Equatable {
    public var peerID: String
    public var name: String
    public var protocolVersion: Int
    public var appVersion: String
    public var media: MediaInfo?
    /// The sender's current state, on the sender's clock.
    public var state: PlaybackState?
}

public struct ClockPing: Codable, Equatable {
    public var id: UInt32
    public var t0: TimeInterval
}

public struct ClockPong: Codable, Equatable {
    public var id: UInt32
    public var t0: TimeInterval
    public var t1: TimeInterval
    public var t2: TimeInterval
    /// The sender's suggested start lead (how long it needs to seek and be ready).
    public var lead: TimeInterval
}

public struct ChatMessage: Codable, Equatable, Identifiable {
    public var id: String
    public var from: String
    public var name: String
    public var text: String
    /// Media position when sent, for anchoring to the scene.
    public var mediaTime: TimeInterval
    public var sentAt: Date

    public init(id: String = UUID().uuidString, from: String, name: String, text: String, mediaTime: TimeInterval, sentAt: Date = Date()) {
        self.id = id
        self.from = from
        self.name = name
        self.text = text
        self.mediaTime = mediaTime
        self.sentAt = sentAt
    }
}

public struct Reaction: Codable, Equatable, Identifiable {
    public var id: String
    public var from: String
    public var name: String
    public var emoji: String
    public var mediaTime: TimeInterval

    public init(id: String = UUID().uuidString, from: String, name: String, emoji: String, mediaTime: TimeInterval) {
        self.id = id
        self.from = from
        self.name = name
        self.emoji = emoji
        self.mediaTime = mediaTime
    }
}

public enum WireMessage: Equatable {
    case hello(Hello)
    case ping(ClockPing)
    case pong(ClockPong)
    case state(PlaybackState)
    case chat(ChatMessage)
    case reaction(Reaction)
    case media(MediaInfo?)
}

extension WireMessage: Codable {
    private enum Kind: String, Codable {
        case hello, ping, pong, state, chat, reaction, media
    }

    private enum CodingKeys: String, CodingKey {
        case t, v
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .t) {
        case .hello: self = .hello(try c.decode(Hello.self, forKey: .v))
        case .ping: self = .ping(try c.decode(ClockPing.self, forKey: .v))
        case .pong: self = .pong(try c.decode(ClockPong.self, forKey: .v))
        case .state: self = .state(try c.decode(PlaybackState.self, forKey: .v))
        case .chat: self = .chat(try c.decode(ChatMessage.self, forKey: .v))
        case .reaction: self = .reaction(try c.decode(Reaction.self, forKey: .v))
        case .media: self = .media(try c.decodeIfPresent(MediaInfo.self, forKey: .v))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .hello(v): try c.encode(Kind.hello, forKey: .t); try c.encode(v, forKey: .v)
        case let .ping(v): try c.encode(Kind.ping, forKey: .t); try c.encode(v, forKey: .v)
        case let .pong(v): try c.encode(Kind.pong, forKey: .t); try c.encode(v, forKey: .v)
        case let .state(v): try c.encode(Kind.state, forKey: .t); try c.encode(v, forKey: .v)
        case let .chat(v): try c.encode(Kind.chat, forKey: .t); try c.encode(v, forKey: .v)
        case let .reaction(v): try c.encode(Kind.reaction, forKey: .t); try c.encode(v, forKey: .v)
        case let .media(v): try c.encode(Kind.media, forKey: .t); try c.encodeIfPresent(v, forKey: .v)
        }
    }
}

public enum WireCodec {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    public static func encode(_ message: WireMessage) -> Data {
        // Encoding our own value types cannot fail.
        (try? encoder.encode(message)) ?? Data()
    }

    public static func decode(_ data: Data) -> WireMessage? {
        try? decoder.decode(WireMessage.self, from: data)
    }
}
