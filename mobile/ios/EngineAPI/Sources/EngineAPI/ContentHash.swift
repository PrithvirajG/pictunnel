import Crypto
import Foundation

/// PicTunnel content identity: SHA-256 of the original bytes as lowercase hex.
public enum ContentHash {
    static let bufferSize = 1 << 20

    /// Streams bytes from `read`, which fills the buffer and returns the byte count (0 at the end).
    public static func sha256Hex(readingWith read: (inout [UInt8]) throws -> Int) rethrows -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let n = try read(&buffer)
            if n == 0 { break }
            hasher.update(data: buffer[0..<n])
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try sha256Hex { buffer in
            guard let data = try handle.read(upToCount: buffer.count), !data.isEmpty else { return 0 }
            data.copyBytes(to: &buffer, count: data.count)
            return data.count
        }
    }
}
