import Foundation
import GroupWatchCore

/// Joins a room: signaling to find peers, WebRTC to reach them, and the
/// Session on top. Lives on the main thread.
final class RoomConnection: PeerMeshDelegate {
    enum Status: Equatable {
        case connecting
        /// On the server, nobody else here yet.
        case waiting
        case connected
        /// Lost the server; peers already connected stay connected.
        case reconnecting
        case full
    }

    let code: String
    private(set) var status: Status = .connecting {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    var onStatusChange: ((Status) -> Void)?

    private let session: Session
    private let signaling: SignalingClient
    private let mesh: PeerMesh
    /// Everyone the server says is in the room.
    private var members: Set<String> = []
    private var retryDelay: TimeInterval = 1
    private var retryWork: DispatchWorkItem?
    private var redialWork: [String: DispatchWorkItem] = [:]
    private var left = false
    private var signalingUp = false

    init(code: String, session: Session, serverURL: URL) {
        self.code = code
        self.session = session
        signaling = SignalingClient(serverURL: serverURL, room: code, peerID: session.localPeerID)
        mesh = PeerMesh(localID: session.localPeerID)
        mesh.delegate = self
        signaling.onEvent = { [weak self] in self?.handle($0) }
    }

    func start() {
        status = .connecting
        signaling.connect()
    }

    func leave() {
        left = true
        retryWork?.cancel()
        redialWork.values.forEach { $0.cancel() }
        signaling.close()
        mesh.closeAll()
        session.removeAllPeers()
    }

    var connectedCount: Int { mesh.connectedPeers.count }

    private func handle(_ event: SignalingClient.Event) {
        switch event {
        case let .welcome(peers, iceServers):
            retryDelay = 1
            signalingUp = true
            mesh.setIceServers(iceServers)
            members = Set(peers)
            // We just arrived (or came back): we call everyone we aren't already talking to.
            for peer in peers where !mesh.isConnected(peer) {
                mesh.connect(to: peer)
            }
            updateStatus()

        case let .peerJoined(peer):
            // They will call us.
            members.insert(peer)
            updateStatus()

        case let .peerLeft(peer):
            members.remove(peer)
            // A live direct link outranks the server's view; keep it until it drops.
            if !mesh.isConnected(peer) { mesh.remove(peer) }
            updateStatus()

        case let .signal(from, data):
            mesh.handleSignal(data, from: from)

        case .roomFull:
            status = .full
            signaling.close()

        case .disconnected:
            guard !left, status != .full else { return }
            signalingUp = false
            updateStatus()
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, 30)
            let work = DispatchWorkItem { [weak self] in self?.signaling.connect() }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func updateStatus() {
        if !mesh.connectedPeers.isEmpty {
            status = .connected
        } else {
            status = signalingUp ? .waiting : .reconnecting
        }
    }

    // MARK: PeerMeshDelegate

    func mesh(_ mesh: PeerMesh, send signal: [String: Any], to peer: String) {
        signaling.sendSignal(signal, to: peer)
    }

    func mesh(_ mesh: PeerMesh, didConnect peer: String) {
        redialWork[peer]?.cancel()
        session.addPeer(id: peer) { [weak mesh] data, channel in
            mesh?.send(data, to: peer, reliable: channel == .reliable)
        }
        updateStatus()
    }

    func mesh(_ mesh: PeerMesh, didDisconnect peer: String) {
        session.removePeer(id: peer)
        updateStatus()
        // If they're still in the room, the peer with the smaller ID redials.
        guard !left, members.contains(peer), session.localPeerID < peer else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.members.contains(peer), !self.mesh.isConnected(peer) else { return }
            self.mesh.connect(to: peer)
        }
        redialWork[peer]?.cancel()
        redialWork[peer] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func mesh(_ mesh: PeerMesh, didReceive data: Data, from peer: String) {
        session.receive(data, from: peer)
    }
}
