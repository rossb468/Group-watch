import AppKit
import GroupWatchCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct GroupWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Group Watch", id: "main") {
            RootView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video…") { Actions.openPanel() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Party") {
                Button(model.roomCode == nil ? "Start a Party & Copy Invite" : "Copy Invite Link") { model.invite() }
                    .keyboardShortcut("i")
                Button("Join from Clipboard") { Actions.joinFromClipboard() }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                Divider()
                Button("Leave Party") { model.leaveRoom() }
                    .disabled(model.roomCode == nil)
            }
            CommandMenu("Playback") {
                Button(model.isPlaying ? "Pause" : "Play") { model.togglePlayPause() }
                    .disabled(!model.hasMedia)
                Button("Back 10 Seconds") { model.skip(by: -10) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(!model.hasMedia)
                Button("Forward 10 Seconds") { model.skip(by: 10) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(!model.hasMedia)
                Divider()
                Button("Next Subtitle Track") { model.cycleSubtitles() }
                Button("Next Audio Track") { model.cycleAudioTrack() }
                Divider()
                Button(model.chatOpen ? "Hide Chat" : "Show Chat") { model.chatOpen.toggle() }
                    .keyboardShortcut("k")
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

enum Actions {
    static func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .audiovisualContent, .video, .data]
        panel.message = "Choose the video you're watching together"
        if panel.runModal() == .OK, let url = panel.url {
            AppModel.shared.open(url)
        }
    }

    static func joinFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), let code = RoomCode.parse(text) else {
            NSSound.beep()
            return
        }
        AppModel.shared.join(code: code)
    }

    static func toggleFullScreen() {
        (NSApp.keyWindow ?? NSApp.windows.first)?.toggleFullScreen(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        _ = AppModel.shared
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            KeyHandler.handle(event) ? nil : event
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { AppModel.shared.handleOpen(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}

/// Player keyboard shortcuts, active whenever you're not typing.
enum KeyHandler {
    static let quickReactions = ["😂", "😮", "😍", "😢", "😱", "👏", "🔥", "❤️"]

    static func handle(_ event: NSEvent) -> Bool {
        let model = AppModel.shared
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty else { return false }

        let typing = NSApp.keyWindow?.firstResponder is NSTextView
        if typing {
            if event.keyCode == 53 { // esc leaves the chat field
                NSApp.keyWindow?.makeFirstResponder(nil)
                return true
            }
            return false
        }

        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 49: // space
            guard model.hasMedia else { return false }
            model.togglePlayPause()
            return true
        case 123: // left
            guard model.hasMedia else { return false }
            model.skip(by: shift ? -30 : -5)
            return true
        case 124: // right
            guard model.hasMedia else { return false }
            model.skip(by: shift ? 30 : 5)
            return true
        case 126: // up
            model.setVolume(model.volume + 5)
            return true
        case 125: // down
            model.setVolume(model.volume - 5)
            return true
        case 36: // return: talk
            model.chatOpen = true
            model.chatFocusRequest += 1
            return true
        case 53: // esc
            if model.chatOpen {
                model.chatOpen = false
                return true
            }
            if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                return true
            }
            return false
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f": Actions.toggleFullScreen()
        case "m": model.toggleMute()
        case "c": model.chatOpen.toggle()
        case "s": model.cycleSubtitles()
        case "a": model.cycleAudioTrack()
        case let key? where Int(key).map({ (1...quickReactions.count).contains($0) }) == true:
            guard model.hasMedia else { return false }
            model.react(quickReactions[Int(key)! - 1])
        default:
            return false
        }
        return true
    }
}
