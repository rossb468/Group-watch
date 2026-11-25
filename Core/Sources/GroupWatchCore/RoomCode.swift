import Foundation

/// Six-character room codes, shown as `ABC-DEF`. The alphabet leaves out
/// look-alikes (0/O, 1/I/L) so codes survive being read aloud or retyped.
public enum RoomCode {
    public static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    public static let length = 6

    public static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
    }

    /// `ABCDEF` → `ABC-DEF`.
    public static func display(_ code: String) -> String {
        guard code.count == length else { return code }
        let mid = code.index(code.startIndex, offsetBy: length / 2)
        return "\(code[..<mid])-\(code[mid...])"
    }

    /// Pulls a room code out of whatever the user pasted: a bare code, `abc-def`,
    /// a `groupwatch://join/ABCDEF` link, or an `https://…/j/ABCDEF` link.
    public static func parse(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), url.scheme != nil {
            let parts = ([url.host ?? ""] + url.pathComponents).filter { $0 != "/" && !$0.isEmpty }
            if let last = parts.last { text = last }
        }
        let cleaned = String(text.uppercased().filter { $0.isLetter || $0.isNumber })
        guard cleaned.count == length, cleaned.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return cleaned
    }
}
