import AppKit
import Libmpv
import QuartzCore

/// A thin wrapper over libmpv.
///
/// mpv renders straight into `layer` (a CAMetalLayer, through MoltenVK) with
/// VideoToolbox hardware decoding, so frames never touch the main thread.
/// Property reads (`observation`) are synchronous and cheap; property changes
/// mpv pushes (pause, seeking, duration…) arrive through `onEvent` on the
/// main thread.
final class MPVPlayer {
    enum Event {
        case fileLoaded
        case loadFailed(String)
        case duration(Double)
        case paused(Bool)
        case busy(Bool)
        case videoSize(CGSize)
    }

    let layer = MPVMetalLayer()
    var onEvent: ((Event) -> Void)?

    private var handle: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "groupwatch.mpv.events", qos: .userInitiated)
    private var seeking = false
    private var pausedForCache = false

    init() {
        layer.backgroundColor = NSColor.black.cgColor
        layer.framebufferOnly = true
        layer.pixelFormat = .bgra8Unorm

        guard let mpv = mpv_create() else {
            NSLog("mpv_create failed")
            return
        }
        handle = mpv

        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        check(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid))

        let options: [(String, String)] = [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"),
            // Start paused; the sync controller decides when to play.
            ("pause", "yes"),
            // Stay on the last frame at the end instead of unloading.
            ("keep-open", "yes"),
            // Exact (frame-accurate) seeks.
            ("hr-seek", "yes"),
            ("hr-seek-framedrop", "yes"),
            // Smooth speed changes keep pitch.
            ("audio-pitch-correction", "yes"),
            ("audio-client-name", "Group Watch"),
            // We own all input and UI.
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("input-media-keys", "no"),
            ("osc", "no"),
            ("osd-level", "0"),
            ("load-scripts", "no"),
            ("ytdl", "no"),
            ("config", "no"),
            ("terminal", "no"),
            // Subtitles: pick up matching files next to the video, prefer the OS language.
            ("sub-auto", "fuzzy"),
            ("subs-match-os-language", "yes"),
            ("subs-fallback", "yes"),
            ("screenshot-directory", "~~desktop/"),
        ]
        for (name, value) in options {
            check(mpv_set_option_string(mpv, name, value), name)
        }
        #if DEBUG
        mpv_request_log_messages(mpv, "warn")
        #endif

        check(mpv_initialize(mpv), "initialize")

        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "seeking", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "dwidth", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 0, "dheight", MPV_FORMAT_INT64)

        mpv_set_wakeup_callback(mpv, { context in
            guard let context else { return }
            let player = Unmanaged<MPVPlayer>.fromOpaque(context).takeUnretainedValue()
            player.eventQueue.async { player.drainEvents() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Stops mpv. Call once, at quit.
    func shutdown() {
        guard let mpv = handle else { return }
        handle = nil
        mpv_set_wakeup_callback(mpv, nil, nil)
        eventQueue.sync {}
        mpv_terminate_destroy(mpv)
    }

    // MARK: - Commands

    func load(_ url: URL) {
        seeking = false
        pausedForCache = false
        command(["loadfile", url.isFileURL ? url.path : url.absoluteString, "replace"])
    }

    /// Thread-safe: also called from the precise unpause timer.
    func setPaused(_ paused: Bool) {
        setFlag("pause", paused)
    }

    func seek(to seconds: Double) {
        command(["seek", String(format: "%.6f", max(0, seconds)), "absolute+exact"])
    }

    func setSpeed(_ speed: Double) {
        setDouble("speed", speed)
    }

    var volume: Double {
        get { getDouble("volume") ?? 100 }
        set { setDouble("volume", max(0, min(100, newValue))) }
    }

    var muted: Bool {
        get { getFlag("mute") ?? false }
        set { setFlag("mute", newValue) }
    }

    func cycleSubtitles() { command(["cycle", "sub"]) }
    func cycleAudioTrack() { command(["cycle", "audio"]) }

    /// What the player is doing right now. Cheap enough to call every tick.
    func snapshot() -> (position: Double, paused: Bool, busy: Bool, speed: Double, duration: Double?) {
        (
            position: getDouble("time-pos") ?? 0,
            paused: getFlag("pause") ?? true,
            busy: seeking || pausedForCache,
            speed: getDouble("speed") ?? 1,
            duration: getDouble("duration")
        )
    }

    // MARK: - Events

    private func drainEvents() {
        while let mpv = handle, let event = mpv_wait_event(mpv, 0) {
            let id = event.pointee.event_id
            if id == MPV_EVENT_NONE { break }
            switch id {
            case MPV_EVENT_FILE_LOADED:
                emit(.fileLoaded)

            case MPV_EVENT_END_FILE:
                if let data = event.pointee.data {
                    let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    if end.reason == MPV_END_FILE_REASON_ERROR {
                        emit(.loadFailed(String(cString: mpv_error_string(end.error))))
                    }
                }

            case MPV_EVENT_PROPERTY_CHANGE:
                guard let data = event.pointee.data else { break }
                let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                handleProperty(property)

            case MPV_EVENT_LOG_MESSAGE:
                if let data = event.pointee.data {
                    let msg = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                    NSLog("mpv [%@] %@", String(cString: msg.prefix), String(cString: msg.text))
                }

            case MPV_EVENT_SHUTDOWN:
                return

            default:
                break
            }
        }
    }

    private var pendingWidth: Int64 = 0
    private var pendingHeight: Int64 = 0

    private func handleProperty(_ property: mpv_event_property) {
        let name = String(cString: property.name)
        let flag: Bool? = property.format == MPV_FORMAT_FLAG ? property.data.map { $0.load(as: Int32.self) != 0 } : nil
        switch name {
        case "pause":
            if let flag { emit(.paused(flag)) }
        case "seeking":
            seeking = flag ?? false
            emit(.busy(seeking || pausedForCache))
        case "paused-for-cache":
            pausedForCache = flag ?? false
            emit(.busy(seeking || pausedForCache))
        case "duration":
            if property.format == MPV_FORMAT_DOUBLE, let data = property.data {
                emit(.duration(data.load(as: Double.self)))
            }
        case "dwidth", "dheight":
            guard property.format == MPV_FORMAT_INT64, let data = property.data else { break }
            let value = data.load(as: Int64.self)
            if name == "dwidth" { pendingWidth = value } else { pendingHeight = value }
            if pendingWidth > 0, pendingHeight > 0 {
                emit(.videoSize(CGSize(width: Double(pendingWidth), height: Double(pendingHeight))))
            }
        default:
            break
        }
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    // MARK: - Property helpers

    private func command(_ args: [String]) {
        guard let mpv = handle else { return }
        var cStrings = args.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var argv: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
        argv.append(nil)
        check(mpv_command(mpv, &argv), args.first ?? "")
    }

    private func getDouble(_ name: String) -> Double? {
        guard let mpv = handle else { return nil }
        var value = 0.0
        return mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard let mpv = handle else { return }
        var v = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &v)
    }

    private func getFlag(_ name: String) -> Bool? {
        guard let mpv = handle else { return nil }
        var value: Int32 = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &value) >= 0 ? value != 0 : nil
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let mpv = handle else { return }
        var v: Int32 = value ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &v)
    }

    private func check(_ status: Int32, _ context: String = "") {
        if status < 0 {
            NSLog("mpv error (%@): %@", context, String(cString: mpv_error_string(status)))
        }
    }
}

/// CAMetalLayer with the MoltenVK workarounds mpv needs on macOS.
final class MPVMetalLayer: CAMetalLayer {
    // MoltenVK sometimes sets a 1x1 drawable to force presentation, which flickers.
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    // EDR mode must be toggled on the main thread to take effect.
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                DispatchQueue.main.sync { super.wantsExtendedDynamicRangeContent = newValue }
            }
        }
    }
}
