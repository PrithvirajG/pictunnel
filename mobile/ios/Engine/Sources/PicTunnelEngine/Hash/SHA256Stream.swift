import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Streaming SHA-256 for content identity (H1, H2): feed the original bytes in any number of
/// chunks, then read the lowercase hex digest. CryptoKit on Apple platforms, swift-crypto elsewhere.
public struct SHA256Stream {
    /// Read size used by the convenience helpers.
    public static let bufferSize = 1 << 20

    private var hasher = SHA256()

    public init() {}

    public mutating func update(_ bytes: [UInt8]) {
        hasher.update(data: bytes)
    }

    public mutating func update(_ bytes: ArraySlice<UInt8>) {
        hasher.update(data: bytes)
    }

    public mutating func update(_ data: Data) {
        hasher.update(data: data)
    }

    public mutating func update(_ buffer: UnsafeRawBufferPointer) {
        hasher.update(bufferPointer: buffer)
    }

    /// The lowercase hex digest of everything fed so far.
    public func finalizeHex() -> String {
        Self.hex(Array(hasher.finalize()))
    }

    /// Streams bytes from `read`, which fills the buffer and returns the byte count (0 at the end).
    public static func hex(readingWith read: (inout [UInt8]) throws -> Int) rethrows -> String {
        var stream = SHA256Stream()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let n = try read(&buffer)
            if n <= 0 { break }
            stream.update(buffer[0..<n])
        }
        return stream.finalizeHex()
    }

    /// Hashes a file without loading it whole.
    public static func hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var stream = SHA256Stream()
        while let data = try handle.read(upToCount: bufferSize), !data.isEmpty {
            stream.update(data)
        }
        return stream.finalizeHex()
    }

    private static let digits = Array("0123456789abcdef".utf8)

    private static func hex(_ bytes: [UInt8]) -> String {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
