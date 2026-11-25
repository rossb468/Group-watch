import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoSurface(player: model.player)
                .ignoresSafeArea()
                .opacity(model.hasMedia ? 1 : 0)

            if model.hasMedia {
                PlayerOverlay(model: model)
            } else {
                WelcomeView(model: model)
            }
        }
        .frame(minWidth: 720, minHeight: 440)
        .preferredColorScheme(.dark)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            model.open(url)
            return true
        }
    }
}
