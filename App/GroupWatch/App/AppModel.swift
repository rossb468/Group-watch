import AppKit
import GroupWatchCore
import Observation

struct FloatingReaction: Identifiable, Equatable {
    let id: String
    let emoji: String
    let name: String
    let isMine: Bool
    /// Horizontal lane, 0…1.
    let lane: CGFloat
}

struct Toast: Identifiable, Equatable {
    let id: String
    let name: String
    let text: String
    let colorIndex: Int
}

struct PeerBadge: Identifiable, Equatable {
    let id: String
    let name: String
    let colorIndex: Int
    let synced: Bool
    let match: MediaMatch
    let mediaName: String?
    let compatible: Bool

    var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

/// The app's brain. Owns the player, the session, and the room, and runs the
/// sync loop. Everything here runs on the main thread.
@Observable
final class AppModel: SessionDelegate {
    static let shared = AppModel()

    // MARK: Observable UI state

    var hasMedia = false
    var mediaTitle = ""
    var loadError: String?
    var duration: Double = 0
    var position: Double = 0
    var isPlaying = false
    var isBuffering = false
    var volume: Double
    var muted = false
    var videoAspect: CGFloat?

    var chat: [ChatMessage] = []
    var unread = 0
    var chatOpen = false {
        didSet { if chatOpen { unread = 0; toasts.removeAll() } }
    }
    /// Bumped to ask the chat field to take focus.
    var chatFocusRequest = 0
    var toasts: [Toast] = []
    var reactions: [FloatingReaction] = []

    var peers: [PeerBadge] = []
    var roomCode: String?
    var roomStatus: RoomConnection.Status?
    var showInvite = false
    var inviteCopied = false
    var syncError: Double?
    /// When scrubbing, the UI shows this instead of the live position.
    var scrubPosition: Double?

    var displayName: String {
        didSet {
            Preferences.displayName = displayName
            session.displayName = Preferences.displayName
            session.announce()
        }
    }

    // MARK: Internals

    @ObservationIgnored let player = MPVPlayer()
    @ObservationIgnored let session: Session
    @ObservationIgnored private var controller = SyncController()
    @ObservationIgnored private var room: RoomConnection?
    @ObservationIgnored private let clock = SystemClock()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var fileLoaded = false
    @ObservationIgnored private var unpauseTimer: DispatchSourceTimer?
    @ObservationIgnored private let unpauseQueue = DispatchQueue(label: "groupwatch.unpause", qos: .userInteractive)
    @ObservationIgnored private var mediaURL: URL?
    @ObservationIgnored private var fingerprint: (hash: String, size: Int64)?
    @ObservationIgnored private var mediaAnnounced = false
    @ObservationIgnored private var playActivity: NSObjectProtocol?
    @ObservationIgnored private var nowPlaying: NowPlaying?

    private init() {
        session = Session(displayName: Preferences.displayName, appVersion: Preferences.appVersion)
        volume = Preferences.volume
        displayName = Preferences.displayName
        session.delegate = self
        player.volume = volume
        player.onEvent = { [weak self] event in self?.handle(event) }

        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        nowPlaying = NowPlaying(model: self)
    }

    func shutdown() {
        timer?.invalidate()
        room?.leave()
        player.shutdown()
    }

    // MARK: - Opening things

    func handleOpen(_ url: URL) {
        if url.isFileURL {
            open(url)
        } else if let code = RoomCode.parse(url.absoluteString) {
            join(code: code)
        }
    }

    func open(_ url: URL) {
        mediaURL = url
        hasMedia = true
        loadError = nil
        mediaTitle = url.deletingPathExtension().lastPathComponent
        duration = 0
        position = 0
        videoAspect = nil
        fileLoaded = false
        fingerprint = nil
        mediaAnnounced = false
        controller.reset()
        cancelScheduledUnpause()
        player.setPaused(true)
        player.load(url)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)

        Task.detached(priority: .userInitiated) { [weak self] in
            let result = try? MediaFingerprint.compute(for: url)
            await MainActor.run {
                guard let self, self.mediaURL == url else { return }
                self.fingerprint = result.map { (hash: $0.fingerprint, size: $0.size) } ?? (hash: url.lastPathComponent, size: 0)
                self.announceMediaIfReady()
            }
        }
    }

    func closeMedia() {
        player.setPaused(true)
        hasMedia = false
        mediaURL = nil
        fileLoaded = false
    }

    private func announceMediaIfReady() {
        guard !mediaAnnounced, let url = mediaURL, let fingerprint, duration > 0 else { return }
        mediaAnnounced = true
        session.mediaLoaded(MediaInfo(fileName: url.lastPathComponent, fileSize: fingerprint.size, duration: duration, fingerprint: fingerprint.hash))
        refreshPeers()
    }

    // MARK: - Watch party

    var inviteLink: URL? { roomCode.map(Preferences.inviteLink(for:)) }

    /// Starts a party (or shows the current one) and copies the invite link.
    func invite() {
        if room == nil { join(code: RoomCode.generate()) }
        copyInvite()
        showInvite = true
    }

    func join(code: String) {
        guard room?.code != code else { return }
        leaveRoom()
        let room = RoomConnection(code: code, session: session, serverURL: Preferences.signalingURL)
        room.onStatusChange = { [weak self] status in self?.roomStatus = status }
        self.room = room
        roomCode = code
        roomStatus = .connecting
        room.start()
    }

    func leaveRoom() {
        room?.leave()
        room = nil
        roomCode = nil
        roomStatus = nil
        showInvite = false
        refreshPeers()
    }

    func copyInvite() {
        guard let link = inviteLink else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
        inviteCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.inviteCopied = false }
    }

    // MARK: - Playback controls

    func togglePlayPause() { session.togglePlayPause() }
    func play() { session.play() }
    func pause() { session.pause() }

    func seek(to seconds: Double) {
        let limit = duration > 0 ? duration : .greatestFiniteMagnitude
        session.seek(to: min(max(0, seconds), limit))
    }

    func skip(by seconds: Double) {
        seek(to: (session.currentPosition ?? position) + seconds)
    }

    func setVolume(_ value: Double) {
        volume = max(0, min(100, value))
        player.volume = volume
        Preferences.volume = volume
        if muted && volume > 0 { toggleMute() }
    }

    func toggleMute() {
        muted.toggle()
        player.muted = muted
    }

    func cycleSubtitles() { player.cycleSubtitles() }
    func cycleAudioTrack() { player.cycleAudioTrack() }

    // MARK: - Chat & reactions

    func sendChat(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chat.append(session.sendChat(String(trimmed.prefix(2000))))
    }

    func react(_ emoji: String) {
        let reaction = session.sendReaction(emoji)
        float(reaction, mine: true)
    }

    func colorIndex(for peerID: String) -> Int {
        if peerID == session.localPeerID { return 0 }
        var hash: UInt32 = 2166136261
        for byte in peerID.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        return 1 + Int(hash % 7)
    }

    var localPeerID: String { session.localPeerID }

    private func float(_ reaction: Reaction, mine: Bool) {
        let item = FloatingReaction(id: reaction.id, emoji: reaction.emoji, name: reaction.name, isMine: mine, lane: .random(in: 0...1))
        reactions.append(item)
        if reactions.count > 40 { reactions.removeFirst(reactions.count - 40) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            self?.reactions.removeAll { $0.id == item.id }
        }
    }

    // MARK: - Sync loop

    private func tick() {
        session.localStartLead = controller.suggestedStartLead
        session.tick()
        if fileLoaded { runController() }
        tickCount += 1
        if tickCount % 5 == 0 { refreshPlaybackUI() }
    }

    private func runController() {
        let snap = player.snapshot()
        let now = clock.now()
        let observation = PlayerObservation(position: snap.position, paused: snap.paused, busy: snap.busy, speed: snap.speed, duration: snap.duration, time: now)
        let commands = controller.update(target: session.state, observed: observation, now: now)
        for command in commands { apply(command) }
    }

    private func apply(_ command: PlayerCommand) {
        switch command {
        case .pause:
            cancelScheduledUnpause()
            player.setPaused(true)
        case let .unpause(at):
            cancelScheduledUnpause()
            let delay = at - clock.now()
            if delay <= 0.001 {
                player.setPaused(false)
            } else {
                // A dedicated high-priority timer: the start must not wait on UI work.
                let timer = DispatchSource.makeTimerSource(flags: .strict, queue: unpauseQueue)
                timer.schedule(deadline: .now() + delay, leeway: .nanoseconds(0))
                timer.setEventHandler { [player] in player.setPaused(false) }
                unpauseTimer = timer
                timer.resume()
            }
        case let .seek(to):
            cancelScheduledUnpause()
            player.seek(to: to)
        case let .setSpeed(speed):
            player.setSpeed(speed)
        }
    }

    private func cancelScheduledUnpause() {
        unpauseTimer?.cancel()
        unpauseTimer = nil
    }

    private func refreshPlaybackUI() {
        var p = session.currentPosition ?? 0
        if duration > 0 { p = min(p, duration) }
        if abs(p - position) > 0.01 { position = p }
        let playing = session.state?.playing ?? false
        if playing != isPlaying { setPlaying(playing) }
        let error = controller.currentError
        if error.map({ (syncError ?? .nan) != $0 }) ?? (syncError != nil) { syncError = error }
    }

    private func setPlaying(_ playing: Bool) {
        isPlaying = playing
        // Keep the display awake while the group is watching.
        if playing, playActivity == nil {
            playActivity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Watching together")
        } else if !playing, let activity = playActivity {
            ProcessInfo.processInfo.endActivity(activity)
            playActivity = nil
        }
    }

    // MARK: - Player events

    private func handle(_ event: MPVPlayer.Event) {
        switch event {
        case .fileLoaded:
            fileLoaded = true
        case let .loadFailed(reason):
            loadError = "This file couldn't be played (\(reason))."
            hasMedia = false
            fileLoaded = false
        case let .duration(value):
            duration = value
            announceMediaIfReady()
            updateNowPlaying()
        case .paused:
            break
        case let .busy(busy):
            isBuffering = busy
        case let .videoSize(size):
            videoAspect = size.height > 0 ? size.width / size.height : nil
        }
    }

    // MARK: - SessionDelegate

    func sessionDidChangeState(_ session: Session) {
        // Act right away rather than waiting for the next tick.
        if fileLoaded { runController() }
        refreshPlaybackUI()
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        nowPlaying?.update(
            title: hasMedia ? mediaTitle : nil,
            duration: duration,
            position: session.currentPosition ?? 0,
            playing: session.state?.playing ?? false
        )
    }

    func session(_ session: Session, didReceiveChat message: ChatMessage) {
        chat.append(message)
        if !chatOpen {
            unread += 1
            let toast = Toast(id: message.id, name: message.name, text: message.text, colorIndex: colorIndex(for: message.from))
            toasts.append(toast)
            if toasts.count > 3 { toasts.removeFirst() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.toasts.removeAll { $0.id == toast.id }
            }
        }
    }

    func session(_ session: Session, didReceiveReaction reaction: Reaction) {
        float(reaction, mine: false)
    }

    func sessionPeersDidChange(_ session: Session) {
        refreshPeers()
    }

    private func refreshPeers() {
        let badges = session.peers.filter(\.helloReceived).map { peer in
            PeerBadge(
                id: peer.id,
                name: peer.name,
                colorIndex: colorIndex(for: peer.id),
                synced: peer.isSynced,
                match: session.mediaMatch(for: peer),
                mediaName: peer.media?.fileName,
                compatible: peer.isCompatible
            )
        }
        if badges != peers { peers = badges }
    }

    /// A short warning when someone has a different file, or nil.
    var mediaWarning: String? {
        guard hasMedia else { return nil }
        if let peer = peers.first(where: { $0.match == .different }) {
            return "\(peer.name) is watching a different video" + (peer.mediaName.map { " (\($0))" } ?? "")
        }
        if let peer = peers.first(where: { $0.match == .similar }) {
            return "\(peer.name) has a different copy of this video. Sync could be off if the versions differ."
        }
        if let peer = peers.first(where: { !$0.compatible }) {
            return "\(peer.name) is on a different version of Group Watch. Both of you should update."
        }
        return nil
    }

    /// What the welcome screen says when you've joined a party before opening a file.
    var joinHint: String? {
        guard !hasMedia, roomCode != nil else { return nil }
        if let peer = peers.first(where: { $0.mediaName != nil }) {
            return "\(peer.name) is watching \(peer.mediaName!). Open your copy to join in."
        }
        if let peer = peers.first {
            return "You're with \(peer.name). Open a video to start."
        }
        return nil
    }
}
