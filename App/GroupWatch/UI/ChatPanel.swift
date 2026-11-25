import GroupWatchCore
import SwiftUI

struct ChatPanel: View {
    @Bindable var model: AppModel
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chat").font(.headline)
                Spacer()
                BarButton(systemName: "xmark", size: 12, help: "Close (Esc)") { model.chatOpen = false }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.chat.isEmpty {
                        Text("Say something about what you're watching. Messages show the moment they were sent.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                    ForEach(model.chat) { message in
                        ChatBubble(message: message, mine: message.from == model.localPeerID, color: Theme.color(model.colorIndex(for: message.from)))
                            .id(message.id)
                    }
                }
                .padding(12)
            }
            .defaultScrollAnchor(.bottom)

            HStack(spacing: 4) {
                ForEach(KeyHandler.quickReactions.prefix(6), id: \.self) { emoji in
                    Button { model.react(emoji) } label: { Text(emoji).font(.system(size: 20)) }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($fieldFocused)
                .onSubmit(send)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .padding([.horizontal, .bottom], 12)
        }
        .frame(width: 300)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .onAppear { fieldFocused = true }
        .onChange(of: model.chatFocusRequest) { _, _ in fieldFocused = true }
    }

    private func send() {
        model.sendChat(draft)
        draft = ""
        fieldFocused = true
    }
}

struct ChatBubble: View {
    let message: ChatMessage
    let mine: Bool
    let color: Color

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            HStack(spacing: 6) {
                if !mine {
                    Text(message.name).font(.caption.weight(.semibold)).foregroundStyle(color)
                }
                Text("at " + Theme.time(message.mediaTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(mine ? AnyShapeStyle(Theme.color(0)) : AnyShapeStyle(.white.opacity(0.12)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }
}

/// Incoming messages while the chat panel is closed.
struct ToastStack: View {
    let toasts: [Toast]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(toasts) { toast in
                HStack(alignment: .top, spacing: 8) {
                    Text(toast.name).font(.callout.weight(.semibold)).foregroundStyle(Theme.color(toast.colorIndex))
                    Text(toast.text).font(.callout).lineLimit(3)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .animation(.spring(duration: 0.35), value: toasts)
        .allowsHitTesting(false)
        .environment(\.colorScheme, .dark)
    }
}

/// Emoji that float up from the bottom of the screen.
struct ReactionsLayer: View {
    let reactions: [FloatingReaction]

    var body: some View {
        GeometryReader { geo in
            ForEach(reactions) { reaction in
                FloatingEmoji(reaction: reaction)
                    .position(x: geo.size.width * (0.55 + 0.4 * reaction.lane), y: geo.size.height - 110)
            }
        }
    }
}

private struct FloatingEmoji: View {
    let reaction: FloatingReaction
    @State private var risen = false

    var body: some View {
        VStack(spacing: 2) {
            Text(reaction.emoji).font(.system(size: 54))
            Text(reaction.isMine ? "You" : reaction.name)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.4), in: Capsule())
        }
        .scaleEffect(risen ? 1 : 0.4)
        .offset(y: risen ? -260 : 0)
        .opacity(risen ? 0 : 1)
        .onAppear {
            withAnimation(.easeOut(duration: 3.2)) { risen = true }
        }
    }
}
