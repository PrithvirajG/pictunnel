import Foundation
import XCTest
@testable import EngineAPI

final class HashingVectorsTests: XCTestCase {
    private struct VectorFile: Decodable { let cases: [HashingCase] }
    private struct HashingCase: Decodable {
        let name: String
        let input: Input
        let expected_sha256: String
    }
    private struct Input: Decodable {
        let file: String?
        let inline_utf8: String?
        let generate: Generate?
    }
    private struct Generate: Decodable {
        let pattern: String
        let seed: Int?
        let length: Int
    }

    /// Tests/EngineAPITests/<file> → EngineAPI → ios → mobile → repo root → api/protocol
    private let protocolDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("api/protocol")

    func testKnownValues() {
        XCTAssertEqual(feed(Array("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(feed([]), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testAllHashingVectorsMatch() throws {
        let dir = protocolDir.appendingPathComponent("vectors/hashing")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var count = 0
        var failures: [String] = []
        for file in files {
            let vectors = try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: file))
            for c in vectors.cases {
                count += 1
                let actual = try hash(c.input)
                if actual != c.expected_sha256 {
                    failures.append("\(file.lastPathComponent)/\(c.name): expected \(c.expected_sha256), got \(actual)")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(count, 8, "hashing cases found in \(dir.path)")
        XCTAssertEqual(failures, [])
    }

    private func hash(_ input: Input) throws -> String {
        if let file = input.file {
            return try ContentHash.sha256Hex(fileAt: protocolDir.appendingPathComponent(file))
        }
        if let text = input.inline_utf8 {
            return feed(Array(text.utf8))
        }
        if let g = input.generate {
            let seed = g.seed ?? 0
            var pos = 0
            return ContentHash.sha256Hex { buffer in
                let n = min(buffer.count, g.length - pos)
                for i in 0..<n { buffer[i] = UInt8((pos + i + seed) % 256) }
                pos += n
                return n
            }
        }
        XCTFail("hashing input has no source")
        return ""
    }

    private func feed(_ bytes: [UInt8]) -> String {
        var pos = 0
        return ContentHash.sha256Hex { buffer in
            let n = min(buffer.count, bytes.count - pos)
            for i in 0..<n { buffer[i] = bytes[pos + i] }
            pos += n
            return n
        }
    }
}
