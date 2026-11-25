import Foundation

public protocol SessionDelegate: AnyObject {
    /// The group's playback state changed (on our clock).
    func sessionDidChangeState(_ session: Session)
    func session(_ session: Session, didReceiveChat message: ChatMessage)
    func session(_ session: Session, didReceiveReaction reaction: Reaction)
    /// A peer joined, left, or changed name, media, or sync status.
    func sessionPeersDidChange(_ session: Session)
}

/// One watch party, seen from this machine.
///
/// Transport-agnostic: hand it a send function per connected peer, feed it
/// received bytes, and call `tick()` regularly. Not thread-safe; use it from
/// one thread (the app uses the main thread).
///
/// Every peer is equal. Any peer may play, pause, or seek; the newest
/// `StateVersion` wins everywhere. Each state is sent directly to every peer
/// (full mesh), and late joiners pick it up from the `hello` handshake.
public final class Session {
    public enum Channel {
        /// Ordered and reliable: state, chat, reactions.
        case reliable
        /// Unordered, no retransmits: clock pings, where a late answer is a useless answer.
        case unreliable
    }

    public struct Peer: Equatable {
        public let id: String
        public var name: String
        public var media: MediaInfo?
        public var clock = ClockOffsetEstimator()
        /// The peer's own suggested start lead, from its pongs.
        public var lead: TimeInterval = 0.3
        public var helloReceived = false
        public var protocolVersion: Int?
        fileprivate var lastPingSent: TimeInterval = -.infinity
        fileprivate var nextPingID: UInt32 = 1
        /// A state that arrived before the clock was synced (sender's clock).
        fileprivate var pendingState: PlaybackState?

        public var isCompatible: Bool { protocolVersion.map { $0 == WireProtocol.version } ?? true }
        public var isSynced: Bool { clock.isSynced }

        public static func == (a: Peer, b: Peer) -> Bool {
            a.id == b.id && a.name == b.name && a.media == b.media && a.helloReceived == b.helloReceived
                && a.isSynced == b.isSynced && a.protocolVersion == b.protocolVersion
        }
    }

    public weak var delegate: SessionDelegate?
    public let localPeerID: String
    public var displayName: String
    public var appVersion: String

    /// How long this machine needs to seek and be ready. The app keeps this
    /// current from `SyncController.suggestedStartLead`.
    public var localStartLead: TimeInterval = 0.3

    /// The group's playback state, on our clock. Nil until a file is loaded or
    /// a peer tells us theirs.
    public private(set) var state: PlaybackState?

    public private(set) var localMedia: MediaInfo?

    /// Connected peers in join order.
    public private(set) var peers: [Peer] = []

    private var senders: [String: (Data, Channel) -> Void] = [:]
    private let clock: MonotonicClock
    private var highestCounter: UInt64 = 0

    public init(peerID: String = UUID().uuidString, displayName: String, appVersion: String = "dev", clock: MonotonicClock = SystemClock()) {
        self.localPeerID = peerID
        self.displayName = displayName
        self.appVersion = appVersion
        self.clock = clock
    }

    // MARK: - Transport hooks

    /// A data path to `id` is open.
    public func addPeer(id: String, send: @escaping (Data, Channel) -> Void) {
        guard id != localPeerID else { return }
        senders[id] = send
        if let i = peers.firstIndex(where: { $0.id == id }) {
            peers[i] = Peer(id: id, name: peers[i].name)
        } else {
            peers.append(Peer(id: id, name: "Guest"))
        }
        send(WireCodec.encode(.hello(makeHello())), .reliable)
        sendPing(to: id, now: clock.now())
        delegate?.sessionPeersDidChange(self)
    }

    public func removePeer(id: String) {
        senders[id] = nil
        let before = peers.count
        peers.removeAll { $0.id == id }
        if peers.count != before { delegate?.sessionPeersDidChange(self) }
    }

    public func removeAllPeers() {
        senders.removeAll()
        if !peers.isEmpty {
            peers.removeAll()
            delegate?.sessionPeersDidChange(self)
        }
    }

    public func receive(_ data: Data, from id: String) {
        let receivedAt = clock.now()
        guard let index = peers.firstIndex(where: { $0.id == id }),
              let message = WireCodec.decode(data) else { return }

        switch message {
        case let .ping(ping):
            let pong = ClockPong(id: ping.id, t0: ping.t0, t1: receivedAt, t2: clock.now(), lead: localStartLead)
            senders[id]?(WireCodec.encode(.pong(pong)), .unreliable)

        case let .pong(pong):
            let wasSynced = peers[index].clock.isSynced
            peers[index].clock.add(t0: pong.t0, t1: pong.t1, t2: pong.t2, t3: receivedAt)
            peers[index].lead = pong.lead
            if !wasSynced && peers[index].clock.isSynced {
                if let pending = peers[index].pendingState {
                    peers[index].pendingState = nil
                    adoptRemote(pending, fromPeerAt: index)
                }
                delegate?.sessionPeersDidChange(self)
            }

        case let .hello(hello):
            let before = peers[index]
            peers[index].name = hello.name
            peers[index].media = hello.media
            peers[index].helloReceived = true
            peers[index].protocolVersion = hello.protocolVersion
            if let remote = hello.state { adoptRemote(remote, fromPeerAt: index) }
            if peers[index] != before { delegate?.sessionPeersDidChange(self) }

        case let .state(remote):
            adoptRemote(remote, fromPeerAt: index)

        case let .media(media):
            peers[index].media = media
            delegate?.sessionPeersDidChange(self)

        case let .chat(message):
            delegate?.session(self, didReceiveChat: message)

        case let .reaction(reaction):
            delegate?.session(self, didReceiveReaction: reaction)
        }
    }

    /// Call every 50–100 ms. Keeps clock estimates fresh.
    public func tick() {
        let now = clock.now()
        for peer in peers {
            let interval: TimeInterval = peer.clock.samples.count < 6 ? 0.1 : 2.0
            if now - peer.lastPingSent >= interval {
                sendPing(to: peer.id, now: now)
            }
        }
    }

    // MARK: - Local actions

    /// A file was opened locally.
    public func mediaLoaded(_ media: MediaInfo) {
        let switched = localMedia != nil && localMedia?.fingerprint != media.fingerprint
        localMedia = media
        broadcast(.media(media))
        if state == nil {
            // Version zero: any state the group already has beats this one.
            state = PlaybackState(playing: false, position: 0, referenceTime: clock.now(), version: .zero)
            delegate?.sessionDidChangeState(self)
        } else if switched {
            // A different video: everyone starts it from the top, paused.
            commit(playing: false, position: 0, referenceTime: clock.now())
        }
    }

    public func play() {
        guard let state, !state.playing else { return }
        let now = clock.now()
        commit(playing: true, position: state.position(at: now), referenceTime: now + startLead(needsSeek: false))
    }

    public func pause() {
        guard let state, state.playing else { return }
        let now = clock.now()
        commit(playing: false, position: state.position(at: now), referenceTime: now)
    }

    public func togglePlayPause() {
        guard let state else { return }
        state.playing ? pause() : play()
    }

    public func seek(to position: TimeInterval) {
        guard let state else { return }
        let target = max(0, position)
        let now = clock.now()
        if state.playing {
            commit(playing: true, position: target, referenceTime: now + startLead(needsSeek: true))
        } else {
            commit(playing: false, position: target, referenceTime: now)
        }
    }

    public func seek(by delta: TimeInterval) {
        guard let state else { return }
        seek(to: state.position(at: clock.now()) + delta)
    }

    /// Where the group is right now.
    public var currentPosition: TimeInterval? {
        state?.position(at: clock.now())
    }

    @discardableResult
    public func sendChat(_ text: String) -> ChatMessage {
        let message = ChatMessage(from: localPeerID, name: displayName, text: text, mediaTime: currentPosition ?? 0)
        broadcast(.chat(message))
        return message
    }

    @discardableResult
    public func sendReaction(_ emoji: String) -> Reaction {
        let reaction = Reaction(from: localPeerID, name: displayName, emoji: emoji, mediaTime: currentPosition ?? 0)
        broadcast(.reaction(reaction))
        return reaction
    }

    public func mediaMatch(for peer: Peer) -> MediaMatch {
        MediaMatch.compare(localMedia, peer.media)
    }

    // MARK: - Internals

    /// How far ahead to schedule a start so every peer can be ready for it.
    func startLead(needsSeek: Bool) -> TimeInterval {
        let readyPeers = peers.filter { $0.helloReceived }
        guard !readyPeers.isEmpty else {
            // Alone: start right away (seeks are absorbed by the controller).
            return needsSeek ? 0 : 0.03
        }
        var lead = needsSeek ? localStartLead : 0.05
        for peer in readyPeers {
            let oneWay = peer.clock.isSynced ? peer.clock.typicalRTT / 2 : 0.15
            let prep = needsSeek ? peer.lead : 0.0
            lead = max(lead, oneWay + prep + 0.08)
        }
        return min(lead, 2.5)
    }

    private func commit(playing: Bool, position: TimeInterval, referenceTime: TimeInterval) {
        highestCounter += 1
        let newState = PlaybackState(
            playing: playing,
            position: position,
            referenceTime: referenceTime,
            rate: state?.rate ?? 1,
            version: StateVersion(counter: highestCounter, origin: localPeerID)
        )
        state = newState
        broadcast(.state(newState))
        delegate?.sessionDidChangeState(self)
    }

    private func adoptRemote(_ remote: PlaybackState, fromPeerAt index: Int) {
        highestCounter = max(highestCounter, remote.version.counter)
        if let state, remote.version <= state.version { return }
        guard peers[index].clock.isSynced else {
            if peers[index].pendingState.map({ $0.version < remote.version }) ?? true {
                peers[index].pendingState = remote
            }
            return
        }
        state = remote.shiftingClock(by: -peers[index].clock.offset)
        delegate?.sessionDidChangeState(self)
    }

    private func makeHello() -> Hello {
        Hello(
            peerID: localPeerID,
            name: displayName,
            protocolVersion: WireProtocol.version,
            appVersion: appVersion,
            media: localMedia,
            state: state.flatMap { $0.version == .zero ? nil : $0 }
        )
    }

    private func sendPing(to id: String, now: TimeInterval) {
        guard let index = peers.firstIndex(where: { $0.id == id }), let send = senders[id] else { return }
        let ping = ClockPing(id: peers[index].nextPingID, t0: now)
        peers[index].nextPingID &+= 1
        peers[index].lastPingSent = now
        send(WireCodec.encode(.ping(ping)), .unreliable)
    }

    private func broadcast(_ message: WireMessage) {
        guard !senders.isEmpty else { return }
        let data = WireCodec.encode(message)
        for peer in peers {
            senders[peer.id]?(data, .reliable)
        }
    }

    /// Re-announces our name to everyone (after a rename).
    public func announce() {
        broadcast(.hello(makeHello()))
    }
}
