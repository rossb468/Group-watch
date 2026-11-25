import AppKit
import GroupWatchCore
import SwiftUI

/// Everything drawn over the video: controls, chat, reactions, notices.
/// Controls fade out after a few seconds of stillness while playing.
struct PlayerOverlay: View {
    @Bindable var model: AppModel
    @State private var controlsVisible = true
    @State private var activity = 0
    @State private var overControls = false

    private var showControls: Bool { controlsVisible || !model.isPlaying || model.showInvite }

    var body: some View {
        ZStack {
            ClickCatcher(
                onClick: { model.togglePlayPause() },
                onDoubleClick: {
                    model.togglePlayPause() // undo the first click's toggle
                    Actions.toggleFullScreen()
                }
            )

            ReactionsLayer(reactions: model.reactions)
                .allowsHitTesting(false)

            if model.isBuffering {
                ProgressView()
                    .controlSize(.large)
                    .allowsHitTesting(false)
            }

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    TopBar(model: model)
                        .opacity(showControls ? 1 : 0)
                    notices
                    Spacer(minLength: 0)
                    ToastStack(toasts: model.toasts)
                    ControlBar(model: model)
                        .opacity(showControls ? 1 : 0)
                        .onHover { overControls = $0 }
                }
                if model.chatOpen {
                    ChatPanel(model: model)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: showControls)
        .animation(.spring(duration: 0.3), value: model.chatOpen)
        .onContinuousHover { _ in poke() }
        .task(id: activity) {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, !overControls, model.isPlaying else { return }
            controlsVisible = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        .onChange(of: model.isPlaying) { _, _ in poke() }
    }

    private func poke() {
        if !controlsVisible { controlsVisible = true }
        activity &+= 1
    }

    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 8) {
            if let warning = model.mediaWarning {
                Notice(text: warning, systemImage: "exclamationmark.triangle.fill", tint: .orange)
            }
            switch model.roomStatus {
            case .waiting:
                Notice(text: "Waiting for others to join…", systemImage: "hourglass", tint: .yellow)
            case .reconnecting:
                Notice(text: "Reconnecting…", systemImage: "wifi.exclamationmark", tint: .orange)
            case .full:
                Notice(text: "That party is full.", systemImage: "person.3.fill", tint: .orange)
            default:
                EmptyView()
            }
        }
        .padding(.top, 4)
        .allowsHitTesting(false)
    }
}

private struct Notice: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.5)))
    }
}

/// Clicks on the video itself. AppKit gives us click counts without the
/// delay SwiftUI adds when single and double taps coexist.
struct ClickCatcher: NSViewRepresentable {
    let onClick: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
    }

    final class CatcherView: NSView {
        var onClick: (() -> Void)?
        var onDoubleClick: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(nil)
            if event.clickCount == 2 { onDoubleClick?() } else if event.clickCount == 1 { onClick?() }
        }

        override var mouseDownCanMoveWindow: Bool { false }
    }
}

struct TopBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Text(model.mediaTitle)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .shadow(radius: 4)
            Spacer()
            Participants(model: model)
            InviteButton(model: model)
        }
        .padding(.leading, 84) // window buttons
        .padding(.trailing, 16)
        .padding(.top, 10)
        .padding(.bottom, 24)
        .background(
            LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }
}

struct Participants: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: -6) {
            ForEach(model.peers) { peer in
                Avatar(initials: peer.initials, color: Theme.color(peer.colorIndex))
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(peer.synced ? Color.green : Color.yellow)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                    }
                    .help(peer.synced ? "\(peer.name) · in sync" : "\(peer.name) · syncing…")
            }
        }
    }
}

struct InviteButton: View {
    @Bindable var model: AppModel

    var body: some View {
        Button {
            model.invite()
        } label: {
            Label(model.roomCode.map(RoomCode.display) ?? "Invite", systemImage: model.roomCode == nil ? "person.badge.plus" : "person.2.fill")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(model.roomCode == nil ? AnyShapeStyle(Theme.color(0)) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .popover(isPresented: $model.showInvite, arrowEdge: .bottom) {
            InvitePopover(model: model)
        }
        .help("Invite someone to watch with you")
    }
}

struct InvitePopover: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("Watch together")
                    .font(.title3.bold())
                Text(model.inviteCopied ? "Invite link copied. Paste it in a message." : "Send this link. Opening it joins your party.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let link = model.inviteLink {
                HStack(spacing: 8) {
                    Text(link.absoluteString)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    Button(model.inviteCopied ? "Copied" : "Copy") { model.copyInvite() }
                }
                ShareLink(item: link, subject: Text("Watch with me"), message: Text("Join me on Group Watch")) {
                    Label("Send with Messages, Mail…", systemImage: "square.and.arrow.up")
                }
            }

            if let code = model.roomCode {
                VStack(spacing: 2) {
                    Text(RoomCode.display(code))
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Text("or they can type this code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                StatusDot(status: model.roomStatus)
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Leave", role: .destructive) { model.leaveRoom() }
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private var statusText: String {
        switch model.roomStatus {
        case .connected:
            let names = model.peers.map(\.name)
            return names.isEmpty ? "Connected" : "With " + ListFormatter.localizedString(byJoining: names)
        case .waiting: return "Waiting for someone to join…"
        case .reconnecting: return "Reconnecting…"
        case .full: return "Party is full"
        default: return "Connecting…"
        }
    }
}
