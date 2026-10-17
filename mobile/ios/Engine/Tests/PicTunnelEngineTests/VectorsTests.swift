import Foundation
import XCTest
@testable import PicTunnelEngine

/// Runs the shared protocol vectors (P§10): every client-decision case of the engine flows
/// (`backup`, `auth`, `free_up_space`), plus all hashing and pairing cases. The vectors are the
/// spec; a failure here is an engine bug, never a reason to edit them.
final class VectorsTests: XCTestCase {
    /// Tests/PicTunnelEngineTests/<file> → Engine → ios → mobile → repo root → api/protocol
    private static let protocolDir: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url = url.deletingLastPathComponent() }
        return url.appendingPathComponent("api/protocol")
    }()

    private static let engineFlows: Set<String> = ["backup", "auth", "free_up_space"]

    private func cases(in dir: String) throws -> [(file: String, value: JSONValue)] {
        let url = Self.protocolDir.appendingPathComponent("vectors/\(dir)")
        let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var out: [(String, JSONValue)] = []
        for file in files {
            let doc = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
            for c in doc["cases"]?.arrayValue ?? [] { out.append((file.lastPathComponent, c)) }
        }
        return out
    }

    // MARK: - Client decisions

    func testClientDecisionVectors() throws {
        var perFlow: [String: Int] = [:]
        var failures: [String] = []
        for (file, c) in try cases(in: "client-decisions") {
            let name = "\(file)/\(c["name"]?.stringValue ?? "?")"
            guard let given = c["given"], let flowName = given["flow"]?.stringValue,
                  Self.engineFlows.contains(flowName) else { continue }
            perFlow[flowName, default: 0] += 1

            let g = try XCTUnwrap(Self.given(given), name)
            let s = Self.outcome(try XCTUnwrap(c["server"], name))
            let d = Decide.decide(g, s)
            let expect = try XCTUnwrap(c["expect"], name)

            if let action = expect["action"]?.stringValue, d.action.rawValue != action {
                failures.append("\(name): action \(d.action.rawValue), want \(action)")
            }
            if let state = expect["next_state"]?.stringValue, d.nextState?.rawValue != state {
                failures.append("\(name): next_state \(d.nextState?.rawValue ?? "nil"), want \(state)")
            }
            if let delta = expect["attempts_delta"]?.intValue, d.attemptsDelta != delta {
                failures.append("\(name): attempts_delta \(d.attemptsDelta), want \(delta)")
            }
        }
        print("client-decision vectors run per flow: \(perFlow.sorted { $0.key < $1.key })")
        XCTAssertGreaterThanOrEqual(perFlow["backup"] ?? 0, 38)
        XCTAssertGreaterThanOrEqual(perFlow["auth"] ?? 0, 2)
        XCTAssertGreaterThanOrEqual(perFlow["free_up_space"] ?? 0, 5)
        XCTAssertEqual(failures, [])
    }

    private static func given(_ v: JSONValue) -> Given? {
        guard let flow = v["flow"]?.stringValue.flatMap(Flow.init(rawValue:)),
              let last = v["last_action"]?.stringValue.flatMap(LastAction.init(rawValue:)) else { return nil }
        let item = v["item"]
        return Given(
            flow: flow,
            itemState: v["item_state"]?.stringValue.flatMap(ItemState.init(rawValue:)),
            lastAction: last,
            item: ItemFlags(
                kind: item?["kind"]?.stringValue.flatMap(ItemKind.init(rawValue:)),
                attempts: item?["attempts"]?.intValue ?? 0,
                hasUploadId: item?["has_upload_id"]?.boolValue,
                fingerprintChanged: item?["fingerprint_changed"]?.boolValue ?? false
            )
        )
    }

    /// `server.problem: "<code>"` expands to the problem body of P§10.5.
    private static func outcome(_ v: JSONValue) -> ServerOutcome {
        if let t = v["transport"]?.stringValue {
            return ServerOutcome(transport: Transport(rawValue: t))
        }
        let status = v["status"]?.intValue
        var headers: [String: String] = [:]
        if case let .object(h)? = v["headers"] {
            for (k, value) in h { headers[k] = value.stringValue }
        }
        var body = v["json"]
        if let code = v["problem"]?.stringValue {
            body = .object([
                "type": .string("urn:pictunnel:problem:\(code)"),
                "title": .string(code),
                "status": status.map { .number(Double($0)) } ?? .null,
                "code": .string(code),
            ])
        }
        return ServerOutcome(status: status, headers: headers, body: body)
    }

    // MARK: - Hashing

    func testHashingVectors() throws {
        var count = 0
        var failures: [String] = []
        for (file, c) in try cases(in: "hashing") {
            count += 1
            let name = "\(file)/\(c["name"]?.stringValue ?? "?")"
            let input = try XCTUnwrap(c["input"], name)
            let want = try XCTUnwrap(c["expected_sha256"]?.stringValue, name)
            let got: String
            if let path = input["file"]?.stringValue {
                got = try SHA256Stream.hex(fileAt: Self.protocolDir.appendingPathComponent(path))
            } else if let text = input["inline_utf8"]?.stringValue {
                var h = SHA256Stream()
                h.update(Array(text.utf8))
                got = h.finalizeHex()
            } else if let gen = input["generate"] {
                let seed = gen["seed"]?.intValue ?? 0
                let length = try XCTUnwrap(gen["length"]?.intValue, name)
                var pos = 0
                got = SHA256Stream.hex { buffer in
                    let n = min(buffer.count, length - pos)
                    for i in 0..<n { buffer[i] = UInt8(truncatingIfNeeded: pos + i + seed) }
                    pos += n
                    return n
                }
            } else {
                XCTFail("\(name): hashing input has no source")
                continue
            }
            if got != want { failures.append("\(name): got \(got), want \(want)") }
        }
        print("hashing vectors run: \(count)")
        XCTAssertGreaterThanOrEqual(count, 11)
        XCTAssertEqual(failures, [])
    }

    // MARK: - Pairing

    func testPairingVectors() throws {
        var count = 0
        var failures: [String] = []
        for (file, c) in try cases(in: "pairing") {
            count += 1
            let name = "\(file)/\(c["name"]?.stringValue ?? "?")"
            let uri = try XCTUnwrap(c["uri"]?.stringValue, name)
            let expect = try XCTUnwrap(c["expect"], name)
            let result = PairURI.parse(uri)

            switch (expect["parse"]?.stringValue, result) {
            case let ("ok", .success(info)):
                if let sid = expect["server_id"]?.stringValue, sid != info.serverId {
                    failures.append("\(name): server_id \(info.serverId)")
                }
                if let code = expect["code"]?.stringValue, code != info.code {
                    failures.append("\(name): code \(info.code)")
                }
                if let fp = expect["fingerprint"]?.stringValue, fp != info.fingerprint {
                    failures.append("\(name): fingerprint \(info.fingerprint)")
                }
                if let eps = expect["endpoints"]?.arrayValue?.compactMap(\.stringValue), eps != info.endpoints {
                    failures.append("\(name): endpoints \(info.endpoints)")
                }
                if let conn = c["connection"], let want = expect["accept_connection"]?.boolValue {
                    let got = PairURI.acceptConnection(
                        systemTrusted: conn["system_trusted"]?.boolValue ?? false,
                        spkiSha256: conn["spki_sha256"]?.stringValue ?? "",
                        pin: info.fingerprint
                    )
                    if got != want { failures.append("\(name): accept_connection \(got), want \(want)") }
                }
            case let ("error", .failure(error)):
                if let want = expect["error"]?.stringValue, error.rawValue != want {
                    failures.append("\(name): error \(error.rawValue), want \(want)")
                }
            default:
                failures.append("\(name): got \(result), want parse=\(expect["parse"]?.stringValue ?? "?")")
            }
        }
        print("pairing vectors run: \(count)")
        XCTAssertGreaterThanOrEqual(count, 12)
        XCTAssertEqual(failures, [])
    }
}
