import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var server = Preferences.signalingOverride

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $model.displayName)
                Text("This is what others see in chat and reactions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Advanced") {
                TextField("Server", text: $server, prompt: Text(Preferences.signalingURL.absoluteString))
                    .onSubmit { Preferences.signalingOverride = server }
                    .onChange(of: server) { _, value in Preferences.signalingOverride = value }
                Text("Leave empty to use the built-in server. Takes effect the next time you join a party.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.syncError {
                    LabeledContent("Sync offset", value: String(format: "%+.0f ms", error * 1000))
                }
            }
            Section {
                LabeledContent("Version", value: Preferences.appVersion)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
