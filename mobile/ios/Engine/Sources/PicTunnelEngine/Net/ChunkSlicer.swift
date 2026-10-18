import Foundation

public enum ChunkSlicerError: Error, Equatable, Sendable {
    /// The offset is negative or at/after the end of the source, or the length is not positive.
    case invalidRange(offset: Int64, length: Int64, sourceSize: Int64)
    /// The source ended before the expected bytes were read.
    case shortRead
}

/// Cuts one chunk of a staged resource into its own file for a background `PATCH` (M§6): the
/// background session can only upload from files. The slice for the next chunk is cut only after
/// the previous chunk is accepted, so at most one slice per item exists at a time.
public struct ChunkSlicer: Sendable {
    /// iOS chunk size (M§4.2): 64 MiB.
    public static let chunkBytes: Int64 = 64 << 20

    public var bufferSize: Int

    public init(bufferSize: Int = 1 << 20) {
        self.bufferSize = max(1, bufferSize)
    }

    /// Copies bytes `[offset, offset + length)` of `source` (clamped to its end) to
    /// `dir/<source name>.<offset>.chunk`, replacing an older slice of the same offset, and
    /// returns that file.
    public func slice(source: URL, offset: Int64, length: Int64, into dir: URL) throws -> URL {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let size = Int64(try input.seekToEnd())
        guard offset >= 0, length > 0, offset < size else {
            throw ChunkSlicerError.invalidRange(offset: offset, length: length, sourceSize: size)
        }
        let count = min(length, size - offset)
        let target = dir.appendingPathComponent("\(source.lastPathComponent).\(offset).chunk")
        let partial = dir.appendingPathComponent("\(source.lastPathComponent).\(offset).chunk.part")

        let fm = FileManager.default
        try? fm.removeItem(at: partial)
        guard fm.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
        }
        do {
            let output = try FileHandle(forWritingTo: partial)
            defer { try? output.close() }
            try input.seek(toOffset: UInt64(offset))
            var remaining = count
            while remaining > 0 {
                let want = Int(min(Int64(bufferSize), remaining))
                guard let data = try input.read(upToCount: want), !data.isEmpty else {
                    throw ChunkSlicerError.shortRead
                }
                try output.write(contentsOf: data)
                remaining -= Int64(data.count)
            }
            try output.synchronize()
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        try? fm.removeItem(at: target)
        do {
            try fm.moveItem(at: partial, to: target)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return target
    }
}
