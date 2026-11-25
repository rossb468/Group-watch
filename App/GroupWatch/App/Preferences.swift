import Foundation

enum Preferences {
    private static let defaults = UserDefaults.standard

    /// Your name as others see it. Defaults to your first name from macOS.
    static var displayName: String {
        get {
            if let saved = defaults.string(forKey: "displayName"), !saved.trimmingCharacters(in: .whitespaces).isEmpty {
                return saved
            }
            let full = NSFullUserName()
            return full.split(separator: " ").first.map(String.init) ?? (full.isEmpty ? "Guest" : full)
        }
        set { defaults.set(newValue, forKey: "displayName") }
    }

    /// Override for the signaling server (advanced). Empty uses the built-in one.
    static var signalingOverride: String {
        get { defaults.string(forKey: "signalingURL") ?? "" }
        set { defaults.set(newValue, forKey: "signalingURL") }
    }

    static var signalingURL: URL {
        if let url = URL(string: signalingOverride), url.scheme != nil { return url }
        let builtIn = Bundle.main.object(forInfoDictionaryKey: "GWSignalingURL") as? String ?? ""
        return URL(string: builtIn) ?? URL(string: "https://groupwatch.groupwatch-signaling.workers.dev")!
    }

    /// Public link for an invite: opens the app through the server's join page.
    static func inviteLink(for code: String) -> URL {
        signalingURL.appendingPathComponent("j").appendingPathComponent(code)
    }

    static var volume: Double {
        get { defaults.object(forKey: "volume") as? Double ?? 100 }
        set { defaults.set(newValue, forKey: "volume") }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
