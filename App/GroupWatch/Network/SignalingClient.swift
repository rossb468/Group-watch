import Foundation

/// WebSocket connection to the signaling server for one room.
///
/// Only used to find peers and exchange WebRTC setup messages. Once peers are
/// connected directly, this connection can drop without interrupting anything.
/// All callbacks arrive on the main thread.
final class SignalingClient: NSObject, URLSessionWebSocketDelegate {
    struct IceServer: Decodable {
        let urls: [String]
        let username: String?
        let credential: String?

        private enum CodingKeys: String, CodingKey { case urls, username, credential }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let many = try? c.decode([String].self, forKey: .urls) {
                urls = many
            } else {
                urls = [try c.decode(String.self, forKey: .urls)]
            }
            username = try c.decodeIfPresent(String.self, forKey: .username)
            credential = try c.decodeIfPresent(String.self, forKey: .credential)
        }
    }

    enum Event {
        case welcome(peers: [String], iceServers: [IceServer])
        case peerJoined(String)
        case peerLeft(String)
        case signal(from: String, data: [String: Any])
        case roomFull
        case disconnected
    }

    var onEvent: ((Event) -> Void)?

    private let url: URL
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var keepAlive: Timer?
    private var closedByUs = false

    init(serverURL: URL, room: String, peerID: String) {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/room/\(room)"
        components.queryItems = [URLQueryItem(name: "peer", value: peerID)]
        url = components.url!
        super.init()
    }

    func connect() {
        closedByUs = false
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive()
        keepAlive?.invalidate()
        keepAlive = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.sendRaw(#"{"type":"ping"}"#)
        }
    }

    func close() {
        closedByUs = true
        keepAlive?.invalidate()
        keepAlive = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func sendSignal(_ data: [String: Any], to peer: String) {
        let message: [String: Any] = ["type": "signal", "to": peer, "data": data]
        guard let json = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: json, encoding: .utf8) else { return }
        sendRaw(text)
    }

    private func sendRaw(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .success(message):
                    if case let .string(text) = message { self.handle(text) }
                    self.receive()
                case .failure:
                    self.dropped()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "welcome":
            let peers = object["peers"] as? [String] ?? []
            var servers: [IceServer] = []
            if let raw = object["iceServers"],
               let rawData = try? JSONSerialization.data(withJSONObject: raw) {
                servers = (try? JSONDecoder().decode([IceServer].self, from: rawData)) ?? []
            }
            onEvent?(.welcome(peers: peers, iceServers: servers))
        case "peer-joined":
            if let id = object["id"] as? String { onEvent?(.peerJoined(id)) }
        case "peer-left":
            if let id = object["id"] as? String { onEvent?(.peerLeft(id)) }
        case "signal":
            if let from = object["from"] as? String, let payload = object["data"] as? [String: Any] {
                onEvent?(.signal(from: from, data: payload))
            }
        case "error":
            if object["reason"] as? String == "room-full" { onEvent?(.roomFull) }
        default:
            break
        }
    }

    private func dropped() {
        guard !closedByUs, task != nil else { return }
        keepAlive?.invalidate()
        keepAlive = nil
        task = nil
        session?.invalidateAndCancel()
        session = nil
        onEvent?(.disconnected)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        dropped()
    }
}
