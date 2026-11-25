import SwiftUI

enum Theme {
    /// Index 0 is you; the rest are assigned to peers by ID.
    static let peerColors: [Color] = [
        Color(red: 0.04, green: 0.52, blue: 1.00), // blue (you)
        Color(red: 1.00, green: 0.27, blue: 0.47), // pink
        Color(red: 1.00, green: 0.62, blue: 0.04), // orange
        Color(red: 0.19, green: 0.82, blue: 0.35), // green
        Color(red: 0.69, green: 0.32, blue: 0.87), // purple
        Color(red: 0.25, green: 0.78, blue: 0.88), // teal
        Color(red: 1.00, green: 0.80, blue: 0.00), // yellow
        Color(red: 1.00, green: 0.42, blue: 0.27), // coral
    ]

    static func color(_ index: Int) -> Color { peerColors[index % peerColors.count] }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// A circle with someone's initials.
struct Avatar: View {
    let initials: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
    }
}

/// A round icon button for the control bar.
struct BarButton: View {
    let systemName: String
    var size: CGFloat = 15
    var help: String = ""
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Circle())
                .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .onHover { hovering = $0 }
        .help(help)
    }
}
