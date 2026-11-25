import Foundation
import WebRTC

protocol PeerMeshDelegate: AnyObject {
    func mesh(_ mesh: PeerMesh, send signal: [String: Any], to peer: String)
    func mesh(_ mesh: PeerMesh, didConnect peer: String)
    func mesh(_ mesh: PeerMesh, didDisconnect peer: String)
    func mesh(_ mesh: PeerMesh, didReceive data: Data, from peer: String)
}

/// Direct WebRTC links to every other peer in the room.
///
/// Each link carries two pre-negotiated data channels: a reliable, ordered one
/// for state and chat, and an unordered, no-retransmit one for clock pings.
/// All delegate calls arrive on the main thread; call into it from main only.
final class PeerMesh {
    weak var delegate: PeerMeshDelegate?
    let localID: String

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    private var iceServers: [RTCIceServer] = [RTCIceServer(urlStrings: ["stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"])]
    private var links: [String: PeerLink] = [:]

    init(localID: String) {
        self.localID = localID
    }

    func setIceServers(_ servers: [SignalingClient.IceServer]) {
        guard !servers.isEmpty else { return }
        iceServers = servers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
    }

    func isConnected(_ peer: String) -> Bool { links[peer]?.isOpen ?? false }

    func hasLink(_ peer: String) -> Bool { links[peer] != nil }

    var connectedPeers: [String] { links.values.filter(\.isOpen).map(\.remoteID) }

    /// Starts a connection to `peer`, with us as the offerer.
    func connect(to peer: String) {
        guard peer != localID else { return }
        drop(peer, notify: true)
        guard let link = makeLink(to: peer) else { return }
        link.makeOffer()
    }

    func handleSignal(_ data: [String: Any], from peer: String) {
        switch data["kind"] as? String {
        case "offer":
            guard let sdp = data["sdp"] as? String else { return }
            if let existing = links[peer], existing.isOffering {
                // Both sides offered at once. The peer with the smaller ID keeps its offer.
                if localID < peer { return }
            }
            drop(peer, notify: true)
            guard let link = makeLink(to: peer) else { return }
            link.acceptOffer(sdp)
        case "answer":
            guard let sdp = data["sdp"] as? String else { return }
            links[peer]?.acceptAnswer(sdp)
        case "candidate":
            guard let sdp = data["candidate"] as? String else { return }
            let index = (data["sdpMLineIndex"] as? NSNumber)?.int32Value ?? 0
            let mid = data["sdpMid"] as? String
            links[peer]?.addRemoteCandidate(RTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: mid))
        default:
            break
        }
    }

    func send(_ data: Data, to peer: String, reliable: Bool) {
        links[peer]?.send(data, reliable: reliable)
    }

    func remove(_ peer: String) {
        drop(peer, notify: true)
    }

    func closeAll() {
        for peer in Array(links.keys) { drop(peer, notify: true) }
    }

    // MARK: - Internals

    private func makeLink(to peer: String) -> PeerLink? {
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        let link = PeerLink(remoteID: peer, mesh: self)
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = PeerMesh.factory.peerConnection(with: config, constraints: constraints, delegate: link) else {
            return nil
        }
        link.attach(connection)
        links[peer] = link
        return link
    }

    private func drop(_ peer: String, notify: Bool) {
        guard let link = links.removeValue(forKey: peer) else { return }
        let wasOpen = link.isOpen
        link.close()
        if notify && wasOpen { delegate?.mesh(self, didDisconnect: peer) }
    }

    fileprivate func linkSignal(_ link: PeerLink, _ data: [String: Any]) {
        guard links[link.remoteID] === link else { return }
        delegate?.mesh(self, send: data, to: link.remoteID)
    }

    fileprivate func linkOpened(_ link: PeerLink) {
        guard links[link.remoteID] === link else { return }
        delegate?.mesh(self, didConnect: link.remoteID)
    }

    fileprivate func linkFailed(_ link: PeerLink) {
        guard links[link.remoteID] === link else { return }
        drop(link.remoteID, notify: true)
    }

    fileprivate func linkReceived(_ link: PeerLink, _ data: Data) {
        guard links[link.remoteID] === link, link.isOpen else { return }
        delegate?.mesh(self, didReceive: data, from: link.remoteID)
    }
}

/// One RTCPeerConnection. WebRTC calls its delegate methods on its own
/// thread; everything is forwarded to the main thread.
private final class PeerLink: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    let remoteID: String
    private weak var mesh: PeerMesh?
    private var connection: RTCPeerConnection?
    private var reliable: RTCDataChannel?
    private var unreliable: RTCDataChannel?
    private var pendingCandidates: [RTCIceCandidate] = []
    private var hasRemoteDescription = false
    private var disconnectTimer: DispatchWorkItem?
    private var isMakingOffer = false
    /// Local candidates wait until our offer or answer has gone out, so they never arrive first.
    private var descriptionSent = false
    private var outgoingCandidates: [[String: Any]] = []
    private(set) var isOpen = false

    var isOffering: Bool { isMakingOffer || connection?.signalingState == .haveLocalOffer }

    init(remoteID: String, mesh: PeerMesh) {
        self.remoteID = remoteID
        self.mesh = mesh
    }

    func attach(_ connection: RTCPeerConnection) {
        self.connection = connection
        reliable = makeChannel(on: connection, label: "control", id: 0, ordered: true, maxRetransmits: nil)
        unreliable = makeChannel(on: connection, label: "clock", id: 1, ordered: false, maxRetransmits: 0)
    }

    private func makeChannel(on connection: RTCPeerConnection, label: String, id: Int32, ordered: Bool, maxRetransmits: Int32?) -> RTCDataChannel? {
        let config = RTCDataChannelConfiguration()
        config.isNegotiated = true
        config.channelId = id
        config.isOrdered = ordered
        if let maxRetransmits { config.maxRetransmits = maxRetransmits }
        let channel = connection.dataChannel(forLabel: label, configuration: config)
        channel?.delegate = self
        return channel
    }

    func makeOffer() {
        guard let connection else { return }
        isMakingOffer = true
        connection.offer(for: Self.noConstraints) { [weak self] sdp, _ in
            guard let self, let sdp else { return }
            connection.setLocalDescription(sdp) { _ in
                DispatchQueue.main.async {
                    self.isMakingOffer = false
                    self.signal(["kind": "offer", "sdp": sdp.sdp])
                    self.flushCandidates()
                }
            }
        }
    }

    func acceptOffer(_ sdp: String) {
        guard let connection else { return }
        connection.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { [weak self] error in
            guard let self, error == nil else { return }
            DispatchQueue.main.async { self.remoteDescriptionApplied() }
            connection.answer(for: Self.noConstraints) { answer, _ in
                guard let answer else { return }
                connection.setLocalDescription(answer) { _ in
                    DispatchQueue.main.async {
                        self.signal(["kind": "answer", "sdp": answer.sdp])
                        self.flushCandidates()
                    }
                }
            }
        }
    }

    func acceptAnswer(_ sdp: String) {
        guard let connection else { return }
        connection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] error in
            guard let self, error == nil else { return }
            DispatchQueue.main.async { self.remoteDescriptionApplied() }
        }
    }

    func addRemoteCandidate(_ candidate: RTCIceCandidate) {
        if hasRemoteDescription {
            connection?.add(candidate) { _ in }
        } else {
            pendingCandidates.append(candidate)
        }
    }

    private func remoteDescriptionApplied() {
        hasRemoteDescription = true
        for candidate in pendingCandidates { connection?.add(candidate) { _ in } }
        pendingCandidates.removeAll()
    }

    func send(_ data: Data, reliable useReliable: Bool) {
        let channel = useReliable ? reliable : (unreliable?.readyState == .open ? unreliable : reliable)
        guard let channel, channel.readyState == .open else { return }
        channel.sendData(RTCDataBuffer(data: data, isBinary: true))
    }

    func close() {
        disconnectTimer?.cancel()
        isOpen = false
        reliable?.delegate = nil
        unreliable?.delegate = nil
        reliable?.close()
        unreliable?.close()
        connection?.delegate = nil
        connection?.close()
        connection = nil
    }

    private func signal(_ data: [String: Any]) {
        mesh?.linkSignal(self, data)
    }

    private func flushCandidates() {
        descriptionSent = true
        outgoingCandidates.forEach(signal)
        outgoingCandidates.removeAll()
    }

    private static let noConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

    // MARK: RTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        DispatchQueue.main.async {
            let open = self.reliable?.readyState == .open
            if open && !self.isOpen {
                self.isOpen = true
                self.mesh?.linkOpened(self)
            } else if !open && self.isOpen {
                self.mesh?.linkFailed(self)
            }
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        DispatchQueue.main.async { self.mesh?.linkReceived(self, data) }
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        var data: [String: Any] = ["kind": "candidate", "candidate": candidate.sdp, "sdpMLineIndex": candidate.sdpMLineIndex]
        if let mid = candidate.sdpMid { data["sdpMid"] = mid }
        DispatchQueue.main.async {
            if self.descriptionSent { self.signal(data) } else { self.outgoingCandidates.append(data) }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        DispatchQueue.main.async {
            switch newState {
            case .failed, .closed:
                self.mesh?.linkFailed(self)
            case .disconnected:
                // Often transient (Wi-Fi blip). Give ICE a moment to recover.
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.connection?.iceConnectionState == .disconnected else { return }
                    self.mesh?.linkFailed(self)
                }
                self.disconnectTimer?.cancel()
                self.disconnectTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
            case .connected, .completed:
                self.disconnectTimer?.cancel()
            default:
                break
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
