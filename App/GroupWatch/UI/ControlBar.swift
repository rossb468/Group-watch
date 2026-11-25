import SwiftUI

struct ControlBar: View {
    @Bindable var model: AppModel
    @State private var showReactions = false

    private var shownPosition: Double { model.scrubPosition ?? model.position }

    var body: some View {
        HStack(spacing: 6) {
            BarButton(systemName: model.isPlaying ? "pause.fill" : "play.fill", size: 18, help: "Play/Pause (Space)") {
                model.togglePlayPause()
            }
            BarButton(systemName: "gobackward.10", help: "Back 10 seconds (←)") { model.skip(by: -10) }
            BarButton(systemName: "goforward.10", help: "Forward 10 seconds (→)") { model.skip(by: 10) }

            Text(Theme.time(shownPosition))
                .font(.callout.monospacedDigit())
                .frame(minWidth: 54, alignment: .trailing)

            ScrubBar(
                position: shownPosition,
                duration: model.duration,
                onScrub: { model.scrubPosition = $0 },
                onCommit: { value in
                    model.seek(to: value)
                    model.scrubPosition = nil
                }
            )
            .frame(height: 24)
            .padding(.horizontal, 6)

            Text("-" + Theme.time(max(0, model.duration - shownPosition)))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .frame(minWidth: 60, alignment: .leading)

            VolumeControl(model: model)

            BarButton(systemName: "face.smiling", help: "React (1–8)") { showReactions.toggle() }
                .popover(isPresented: $showReactions, arrowEdge: .top) {
                    ReactionPalette { emoji in
                        model.react(emoji)
                    }
                }

            BarButton(systemName: model.chatOpen ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right", help: "Chat (Return)") {
                model.chatOpen.toggle()
            }
            .overlay(alignment: .topTrailing) {
                if model.unread > 0 {
                    Text("\(min(model.unread, 99))")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Color.red, in: Capsule())
                        .offset(x: 2, y: -2)
                        .allowsHitTesting(false)
                }
            }

            BarButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Full screen (F)") {
                Actions.toggleFullScreen()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .environment(\.colorScheme, .dark)
    }
}

/// A timeline you can click or drag. Seeks commit on release.
struct ScrubBar: View {
    let position: Double
    let duration: Double
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let fraction = duration > 0 ? min(1, max(0, position / duration)) : 0
            let height: CGFloat = hovering || dragging ? 6 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                    .frame(height: height)
                Capsule().fill(.white)
                    .frame(width: max(height, geo.size.width * fraction), height: height)
                Circle().fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(radius: 2)
                    .offset(x: geo.size.width * fraction - 7)
                    .opacity(hovering || dragging ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        onScrub(seconds(at: value.location.x, width: geo.size.width))
                    }
                    .onEnded { value in
                        dragging = false
                        onCommit(seconds(at: value.location.x, width: geo.size.width))
                    }
            )
            .animation(.easeOut(duration: 0.12), value: height)
        }
    }

    private func seconds(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0, duration > 0 else { return 0 }
        return Double(min(1, max(0, x / width))) * duration
    }
}

struct VolumeControl: View {
    @Bindable var model: AppModel
    @State private var hovering = false

    private var icon: String {
        if model.muted || model.volume == 0 { return "speaker.slash.fill" }
        if model.volume < 34 { return "speaker.wave.1.fill" }
        if model.volume < 67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        HStack(spacing: 2) {
            BarButton(systemName: icon, help: "Mute (M)") { model.toggleMute() }
            if hovering {
                Slider(value: Binding(get: { model.muted ? 0 : model.volume }, set: { model.setVolume($0) }), in: 0...100)
                    .controlSize(.small)
                    .frame(width: 80)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .onHover { over in withAnimation(.easeOut(duration: 0.15)) { hovering = over } }
    }
}

struct ReactionPalette: View {
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(KeyHandler.quickReactions.enumerated()), id: \.offset) { index, emoji in
                Button { onPick(emoji) } label: {
                    Text(emoji).font(.system(size: 26))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .help("Press \(index + 1)")
            }
        }
        .padding(8)
    }
}
