import Foundation
import XCTest
@testable import PicTunnelEngine

final class StoreTests: XCTestCase {
    private var dir: URL!
    private var db: EngineDB!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try EngineDB(path: dir.appendingPathComponent("engine.sqlite").path)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func item(_ id: String, takenAtMs: Int64, state: ItemState = .discovered) -> Item {
        Item(localId: id, size: 100, modifiedAtMs: 1, takenAtMs: takenAtMs, mime: "image/jpeg",
             kind: .photo, filename: "\(id).jpg", state: state)
    }

    func testUpsertRoundTripsAndReplaces() throws {
        var a = item("a", takenAtMs: 10)
        a.sha256 = String(repeating: "f", count: 64)
        a.pairRole = .liveVideo
        a.uploadOffset = 42
        try db.upsert(a)
        XCTAssertEqual(try db.item(localId: "a"), a)

        a.state = .backedUp
        a.assetId = "asset-1"
        try db.upsert(a)
        XCTAssertEqual(try db.item(localId: "a"), a)
        XCTAssertNil(try db.item(localId: "missing"))
    }

    func testPageOrdersByTakenThenLocalIdDescendingWithExclusiveKey() throws {
        try db.upsertAll([
            item("a", takenAtMs: 100), item("b", takenAtMs: 300), item("c", takenAtMs: 200),
            item("d", takenAtMs: 200), item("e", takenAtMs: 50),
        ])
        let first = try db.page(after: nil, limit: 2)
        XCTAssertEqual(first.map(\.localId), ["b", "d"])

        let key = try XCTUnwrap(PageKey(first.last!))
        XCTAssertEqual(key.description, "200|d")
        let second = try db.page(after: key, limit: 2)
        XCTAssertEqual(second.map(\.localId), ["c", "a"])

        let third = try db.page(after: PageKey(parsing: "100|a"), limit: 10)
        XCTAssertEqual(third.map(\.localId), ["e"])
        XCTAssertEqual(try db.page(after: PageKey(parsing: "50|e"), limit: 10), [])
    }

    func testPageKeyParsing() {
        XCTAssertEqual(PageKey(parsing: "1700000000000|ABC/L0/001"),
                       PageKey(takenAtMs: 1_700_000_000_000, localId: "ABC/L0/001"))
        XCTAssertEqual(PageKey(parsing: "5|a|b")?.localId, "a|b")
        XCTAssertNil(PageKey(parsing: "nope"))
        XCTAssertNil(PageKey(parsing: "x|a"))
    }

    func testCountsByState() throws {
        try db.upsertAll([
            item("a", takenAtMs: 1, state: .backedUp), item("b", takenAtMs: 2, state: .backedUp),
            item("c", takenAtMs: 3, state: .queued),
        ])
        let counts = try db.counts()
        XCTAssertEqual(counts[.backedUp], 2)
        XCTAssertEqual(counts[.queued], 1)
        XCTAssertEqual(counts[.paused], 0)
        XCTAssertEqual(counts.total, 3)
    }

    func testSetStateAndByStateAndDelete() throws {
        try db.upsertAll([item("a", takenAtMs: 1), item("b", takenAtMs: 2)])
        XCTAssertTrue(try db.setState(localId: "a", state: .queued, attempts: 3, nextAttemptAtMs: 9, lastError: "x"))
        XCTAssertFalse(try db.setState(localId: "zz", state: .queued, attempts: 0, nextAttemptAtMs: nil, lastError: nil))
        let a = try XCTUnwrap(db.item(localId: "a"))
        XCTAssertEqual(a.state, .queued)
        XCTAssertEqual(a.attempts, 3)
        XCTAssertEqual(a.nextAttemptAtMs, 9)
        XCTAssertEqual(a.lastError, "x")
        XCTAssertEqual(try db.items(in: [.queued, .hashed], limit: 10).map(\.localId), ["a"])
        XCTAssertEqual(try db.delete(localIds: ["a", "zz"]), 1)
        XCTAssertEqual(try db.counts().total, 1)
    }

    func testHashCacheHitsOnlyOnSameFingerprint() throws {
        let sha = String(repeating: "a", count: 64)
        try db.putHash(localId: "a", modifiedAtMs: 10, size: 5, sha256: sha)
        XCTAssertEqual(try db.cachedHash(localId: "a", modifiedAtMs: 10, size: 5), sha)
        XCTAssertNil(try db.cachedHash(localId: "a", modifiedAtMs: 11, size: 5))
        XCTAssertNil(try db.cachedHash(localId: "a", modifiedAtMs: 10, size: 6))
        try db.putHash(localId: "a", modifiedAtMs: 11, size: 5, sha256: sha)
        XCTAssertNil(try db.cachedHash(localId: "a", modifiedAtMs: 10, size: 5))
    }

    func testScanStateActivityAndSettings() throws {
        XCTAssertNil(try db.scanToken(scope: "library"))
        try db.setScanToken(scope: "library", token: Data([1, 2, 3]))
        XCTAssertEqual(try db.scanToken(scope: "library"), Data([1, 2, 3]))
        try db.setScanToken(scope: "library", token: nil)
        XCTAssertNil(try db.scanToken(scope: "library"))

        for i in 0..<5 { try db.addActivity(atMs: Int64(i), kind: "info", localId: nil, message: "m\(i)") }
        XCTAssertEqual(try db.latestActivity(limit: 2).map(\.message), ["m4", "m3"])
        try db.trimActivity(keep: 3)
        XCTAssertEqual(try db.latestActivity(limit: 10).map(\.message), ["m4", "m3", "m2"])

        XCTAssertNil(try db.setting("wifi_only"))
        try db.setSetting("wifi_only", "true")
        try db.setSetting("wifi_only", "false")
        XCTAssertEqual(try db.setting("wifi_only"), "false")
        XCTAssertEqual(try db.allSettings(), ["wifi_only": "false"])
    }

    func testReopenKeepsDataAndMigrationsAreIdempotent() throws {
        try db.upsert(item("a", takenAtMs: 1))
        let path = dir.appendingPathComponent("engine.sqlite").path
        db = nil
        let reopened = try EngineDB(path: path)
        XCTAssertEqual(try reopened.item(localId: "a")?.localId, "a")
    }
}

final class BackoffTests: XCTestCase {
    private struct MaxRNG: RandomNumberGenerator {
        mutating func next() -> UInt64 { .max }
    }

    func testCeilingDoublesFromTwoSecondsAndCapsAtFifteenMinutes() {
        var rng = MaxRNG()
        XCTAssertEqual(backoffDelay(attempt: 1, rng: &rng), 2, accuracy: 0.01)
        XCTAssertEqual(backoffDelay(attempt: 2, rng: &rng), 4, accuracy: 0.01)
        XCTAssertEqual(backoffDelay(attempt: 5, rng: &rng), 32, accuracy: 0.01)
        XCTAssertEqual(backoffDelay(attempt: 20, rng: &rng), 900, accuracy: 0.01)
        XCTAssertEqual(backoffDelay(attempt: 10_000, rng: &rng), 900, accuracy: 0.01)
    }

    func testFullJitterStaysInRange() {
        var rng = SystemRandomNumberGenerator()
        for attempt in 1...12 {
            let d = backoffDelay(attempt: attempt, rng: &rng)
            XCTAssertGreaterThanOrEqual(d, 0)
            XCTAssertLessThanOrEqual(d, min(900, 2 * pow(2, Double(attempt - 1))))
        }
    }

    func testTenthFailureEscalatesToNeedsAttention() {
        let g = Given(flow: .backup, itemState: .uploading, lastAction: .appendUpload,
                      item: ItemFlags(kind: .photo, attempts: 9, hasUploadId: true))
        let d = Decide.decide(g, ServerOutcome(status: 500, body: .object(["code": .string("internal")])))
        XCTAssertEqual(d, Decision(nextState: .needsAttention, action: .markNeedsAttention, attemptsDelta: 1))

        let offline = Decide.decide(g, ServerOutcome(transport: .offline))
        XCTAssertEqual(offline.action, .waitForNetwork)
    }
}
