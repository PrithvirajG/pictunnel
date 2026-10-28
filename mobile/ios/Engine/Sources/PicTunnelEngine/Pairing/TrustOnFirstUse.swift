import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

/// A server as manual setup shows it before pairing (P§6.3 step 5): the user compares `fp16`
/// with the server's admin page, and pairing then pins `fpFull`.
public struct ServerFingerprint: Equatable, Sendable {
    public var serverId: String
    public var name: String
    /// base64url SHA-256 of the leaf certificate's SubjectPublicKeyInfo (the QR `fp`).
    public var fpFull: String
    public var url: String

    public init(serverId: String, name: String, fpFull: String, url: String) {
        self.serverId = serverId
        self.name = name
        self.fpFull = fpFull
        self.url = url
    }

    /// The first 16 characters, what the server's mDNS TXT `fp16` and admin page show.
    public var fp16: String { String(fpFull.prefix(16)) }
}

/// Trust on first use for manual setup: one public `GET /api/v1/server/info` that accepts whatever
/// certificate the server presents and reports its SPKI fingerprint. Nothing secret is sent; the
/// connection is only trusted later, by pinning the fingerprint the user confirmed.
public enum TrustOnFirstUse {
    public static func probe(serverUrl: String, clientHeader: String, timeout: TimeInterval = 10) async throws -> ServerFingerprint {
        let trimmed = serverUrl.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("https://") else { throw PairingError(PairURIError.insecureEndpoint.rawValue) }
        let endpoints = Endpoints([trimmed])
        guard let base = endpoints.urls.first, let url = URL(string: base.absoluteString + "/api/v1/server/info") else {
            throw PairingError(PairURIError.missingEndpoint.rawValue)
        }
        #if canImport(Security)
        let capture = CertificateCapture()
        let session = URLSession(configuration: .ephemeral, delegate: capture, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let http = EngineHTTP(session: session, clientHeader: clientHeader)
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let data: Data
        let resp: HTTPURLResponse
        do {
            (data, resp) = try await http.send(req)
        } catch {
            throw Pairer.transportError(error)
        }
        guard (200...299).contains(resp.statusCode), let info = try? JSONDecoder().decode(ServerInfo.self, from: data) else {
            throw PairingError("not_pictunnel", "The server at \(trimmed) did not answer as a PicTunnel server")
        }
        guard let leaf = capture.leaf, let fp = try? Pinning.spkiSHA256(fromDERCertificate: leaf) else {
            throw PairingError(PairingError.unreachable)
        }
        return ServerFingerprint(serverId: info.serverId, name: info.name ?? "PicTunnel", fpFull: fp,
                                 url: base.absoluteString)
        #else
        _ = url
        throw PairingError("unsupported", "Trust on first use needs the Security framework")
        #endif
    }
}

#if canImport(Security)
/// Accepts any server certificate and keeps the leaf, for `TrustOnFirstUse` only.
private final class CertificateCapture: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _leaf: Data?

    var leaf: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _leaf
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let first = chain.first {
            let der = SecCertificateCopyData(first) as Data
            lock.lock()
            _leaf = der
            lock.unlock()
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
#endif
