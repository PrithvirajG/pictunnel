import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum PinningError: Error, Equatable, Sendable {
    case malformedCertificate
}

/// The pinning rule (P§6.3, M§4.4): a chain the system trusts that matches the host is accepted.
/// Otherwise the leaf's SPKI SHA-256 must equal the stored pin, compared as unpadded base64url.
///
/// The SPKI is read from the certificate DER with a minimal DER walker rather than a certificate
/// library: it only has to find `tbsCertificate.subjectPublicKeyInfo`, and doing it by hand keeps
/// the hash identical on Linux (where `Security` is absent) and on Apple platforms, and matches
/// `openssl x509 -pubkey | openssl pkey -pubin -outform DER | sha256` and Java's
/// `PublicKey.getEncoded()` used by the Android engine and the pairing `fp`.
public enum Pinning {
    /// base64url (unpadded) SHA-256 of the certificate's DER-encoded SubjectPublicKeyInfo.
    public static func spkiSHA256(fromDERCertificate der: Data) throws -> String {
        let spki = try subjectPublicKeyInfo(der)
        return base64url(Data(SHA256.hash(data: spki)))
    }

    /// The decision once the system's verdict is known.
    public static func accept(systemTrusted: Bool, leafDER: Data?, pin: String?) -> Bool {
        if systemTrusted { return true }
        guard let pin = pin.map(normalize), !pin.isEmpty, let leafDER,
              let actual = try? spkiSHA256(fromDERCertificate: leafDER) else { return false }
        return constantTimeEquals(actual, pin)
    }

    #if canImport(Security)
    /// Evaluates `trust` for `host` with the SSL policy, then applies the pinning rule.
    public static func evaluate(_ trust: SecTrust, host: String, pin: String?) -> Bool {
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        var error: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &error)
        var leaf: Data?
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let first = chain.first {
            leaf = SecCertificateCopyData(first) as Data
        }
        return accept(systemTrusted: trusted, leafDER: leaf, pin: pin)
    }
    #endif

    // MARK: - helpers

    static func normalize(_ pin: String) -> String {
        var p = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        while p.hasSuffix("=") { p.removeLast() }
        return p.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    static func base64url(_ data: Data) -> String {
        normalize(data.base64EncodedString())
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    /// Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
    /// TBSCertificate ::= SEQUENCE { [0] version OPTIONAL, serialNumber, signature, issuer,
    ///                               validity, subject, subjectPublicKeyInfo, ... }
    static func subjectPublicKeyInfo(_ der: Data) throws -> Data {
        let b = [UInt8](der)
        let cert = try element(b, at: 0, limit: b.count, tag: 0x30)
        let tbs = try element(b, at: cert.body, limit: cert.end, tag: 0x30)
        var p = tbs.body
        var e = try element(b, at: p, limit: tbs.end)
        if e.tag == 0xA0 { // explicit version
            p = e.end
            e = try element(b, at: p, limit: tbs.end)
        }
        guard e.tag == 0x02 else { throw PinningError.malformedCertificate } // serialNumber
        p = e.end
        for _ in 0..<4 { // signature, issuer, validity, subject
            p = try element(b, at: p, limit: tbs.end, tag: 0x30).end
        }
        let spki = try element(b, at: p, limit: tbs.end, tag: 0x30)
        // SubjectPublicKeyInfo ::= SEQUENCE { algorithm AlgorithmIdentifier, subjectPublicKey BIT STRING }
        let alg = try element(b, at: spki.body, limit: spki.end, tag: 0x30)
        let key = try element(b, at: alg.end, limit: spki.end, tag: 0x03)
        guard key.end == spki.end else { throw PinningError.malformedCertificate }
        return Data(b[spki.start..<spki.end])
    }

    private struct Element {
        let tag: UInt8
        let start: Int
        let body: Int
        let end: Int
    }

    /// One DER TLV at `i` (single-byte tags, definite lengths up to 4 bytes), within `limit`.
    private static func element(_ b: [UInt8], at i: Int, limit: Int, tag expected: UInt8? = nil) throws -> Element {
        guard i >= 0, i + 2 <= limit, limit <= b.count else { throw PinningError.malformedCertificate }
        let tag = b[i]
        if let expected, tag != expected { throw PinningError.malformedCertificate }
        guard tag & 0x1F != 0x1F else { throw PinningError.malformedCertificate }
        var p = i + 1
        let first = b[p]
        p += 1
        var length = 0
        if first < 0x80 {
            length = Int(first)
        } else {
            let n = Int(first & 0x7F)
            guard (1...4).contains(n), p + n <= limit else { throw PinningError.malformedCertificate }
            for _ in 0..<n {
                length = (length << 8) | Int(b[p])
                p += 1
            }
        }
        let end = p + length
        guard end <= limit else { throw PinningError.malformedCertificate }
        return Element(tag: tag, start: i, body: p, end: end)
    }
}

/// The session delegate that enforces `Pinning` on every TLS handshake of the engine's sessions
/// (M§4.4). A refused certificate cancels the challenge, so the request fails with
/// `URLError.cancelled` before any request body is sent.
///
/// On Linux (no `Security`), FoundationNetworking does not expose server trust, so the delegate
/// leaves the default handling in place; the Linux engine build is for tests only.
public final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let pin: @Sendable () -> String?
    private let lock = NSLock()
    private var _rejectedHosts: [String] = []

    /// `pin` is read on every handshake, so a re-pair takes effect without a new session.
    public init(pin: @escaping @Sendable () -> String?) {
        self.pin = pin
    }

    public convenience init(store: CredentialStore) {
        self.init { (try? store.load())?.pinSpki }
    }

    /// Hosts whose certificate was refused, oldest first.
    public var rejectedHosts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _rejectedHosts
    }

    #if canImport(Security)
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if Pinning.evaluate(trust, host: space.host, pin: pin()) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            lock.lock()
            _rejectedHosts.append(space.host)
            lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    #endif
}
