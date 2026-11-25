import CryptoKit
import Foundation

enum MediaFingerprint {
    /// Hashes the file size plus its first and last 4 MB. Fast on any file
    /// size, and identical copies always match.
    static func compute(for url: URL) throws -> (fingerprint: String, size: Int64) {
        let chunk = 4 * 1024 * 1024
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = Int64(try handle.seekToEnd())
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }

        try handle.seek(toOffset: 0)
        if let head = try handle.read(upToCount: chunk) { hasher.update(data: head) }
        if size > Int64(chunk * 2) {
            try handle.seek(toOffset: UInt64(size - Int64(chunk)))
            if let tail = try handle.read(upToCount: chunk) { hasher.update(data: tail) }
        }

        let digest = hasher.finalize().prefix(16)
        return (digest.map { String(format: "%02x", $0) }.joined(), size)
    }
}
