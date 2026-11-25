import GroupWatchCore
import SwiftUI

struct WelcomeView: View {
    @Bindable var model: AppModel
    @State private var code = ""
    @State private var dropHover = false

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Theme.color(0).gradient)
                Text("Group Watch")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Watch together, perfectly in sync.")
                    .foregroundStyle(.secondary)
            }

            if let hint = model.joinHint {
                Label(hint, systemImage: "person.2.fill")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.color(0).opacity(0.2), in: Capsule())
            }

            dropZone

            if let error = model.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            if let room = model.roomCode {
                partyStatus(room)
            } else {
                joinField
            }
        }
        .padding(40)
        .frame(maxWidth: 520)
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Drop a video here")
                .font(.headline)
            Button("Choose Video…") { Actions.openPanel() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(dropHover ? Theme.color(0) : .white.opacity(0.2))
        )
        .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(dropHover ? 0.06 : 0.03)))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            model.open(url)
            return true
        } isTargeted: { dropHover = $0 }
    }

    private var joinField: some View {
        HStack(spacing: 10) {
            TextField("Have an invite? Paste the link or code", text: $code)
                .textFieldStyle(.roundedBorder)
                .onSubmit(join)
            Button("Join", action: join)
                .disabled(RoomCode.parse(code) == nil)
        }
        .frame(maxWidth: 400)
    }

    private func partyStatus(_ room: String) -> some View {
        HStack(spacing: 10) {
            StatusDot(status: model.roomStatus)
            Text(statusText(room))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Leave") { model.leaveRoom() }
                .buttonStyle(.link)
        }
    }

    private func statusText(_ room: String) -> String {
        let code = RoomCode.display(room)
        switch model.roomStatus {
        case .connected: return "In party \(code)"
        case .waiting: return "Party \(code): waiting for others"
        case .reconnecting: return "Party \(code): reconnecting…"
        case .full: return "Party \(code) is full"
        default: return "Joining \(code)…"
        }
    }

    private func join() {
        guard let parsed = RoomCode.parse(code) else { return }
        model.join(code: parsed)
        code = ""
    }
}

struct StatusDot: View {
    let status: RoomConnection.Status?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch status {
        case .connected: return .green
        case .waiting, .connecting: return .yellow
        case .reconnecting, .full: return .orange
        case nil: return .gray
        }
    }
}
