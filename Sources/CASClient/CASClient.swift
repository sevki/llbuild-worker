import CASProtocol
import Distributed
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import WorkerKitDistributed

public struct CASClientError: Error, CustomStringConvertible {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// Native client for a llbuild-worker CAS: resolves the distributed
/// `CASService` over `WorkersActorSystem` and checks everything that comes
/// back. The service is not trusted for identity: a fetched object must hash
/// to the digest it was requested under, and a stored one must come back
/// under the digest computed locally.
public final class CASClient: @unchecked Sendable {
    private let system: WorkersActorSystem
    private let service: CASService
    /// The authenticated worker URL (its path is the scope, e.g. `/prod`):
    /// object bodies live at `<scheme>://<host>/<scope>/objects/<digest>`, a
    /// plain-HTTP sibling of the WebSocket control plane at
    /// `.../<scope>/__rpc`.
    private let workerURL: URL
    /// The bearer token for `PUT`, pulled back out of `workerURL`'s `token`
    /// query item. `GET` needs none: the digest alone is the credential.
    private let token: String?
    private let session: URLSession

    /// Where the shared token lives when the URL doesn't carry one, next to
    /// the remote-URL file `/setup` writes.
    public static let defaultTokenPath = "\(NSHomeDirectory())/.config/llbuild-cas-remote-token"

    /// `workerURL` with the Worker's access token attached as its `token`
    /// query parameter, which is how the WebSocket client authenticates (it
    /// can't set headers on the upgrade request). A token already in the URL
    /// wins, then `LLBUILD_CAS_TOKEN`, then the file at `tokenPath`. Without
    /// any, the URL is returned unchanged and the Worker will refuse it.
    public static func authenticated(
        _ workerURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        tokenPath: String = defaultTokenPath
    ) -> URL {
        guard var components = URLComponents(url: workerURL, resolvingAgainstBaseURL: false),
              !(components.queryItems ?? []).contains(where: { $0.name == "token" }) else {
            return workerURL
        }
        var token = environment["LLBUILD_CAS_TOKEN"] ?? ""
        if token.isEmpty, let data = FileManager.default.contents(atPath: tokenPath) {
            token = String(decoding: data, as: UTF8.self)
        }
        token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return workerURL }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "token", value: token)]
        return components.url ?? workerURL
    }

    public init(workerURL: URL) throws {
        let authenticatedURL = Self.authenticated(workerURL)
        system = WorkersActorSystem(worker: authenticatedURL)
        service = try CASService.resolve(id: "cas-service", using: system)
        self.workerURL = authenticatedURL
        token = presentedToken(url: authenticatedURL.absoluteString, authorization: nil)
        session = URLSession(configuration: .ephemeral)
    }

    public func status() async throws -> CASServiceStatus {
        try await service.status()
    }

    public func contains(_ digest: CASDigest) async throws -> Bool {
        try await service.contains(digest: digest.hex)
    }

    /// `<scheme>://<host>/<scope>/objects/<digest>` for `workerURL`'s scope.
    private func objectURL(_ digest: CASDigest) -> URL {
        var components = URLComponents(url: workerURL, resolvingAgainstBaseURL: false)!
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + "/objects/" + digest.hex
        components.query = nil
        return components.url!
    }

    /// Stores an object of any size up to `CASLimits.maxHTTPObjectBytes`, as
    /// one streamed `PUT` — no client-side chunking: the service accepts a
    /// full body directly, since a plain HTTP request has no WebSocket
    /// message-size ceiling to work around.
    @discardableResult
    public func put(_ blob: CASBlob) async throws -> CASDigest {
        let digest = blob.digest
        guard blob.data.count <= CASLimits.maxHTTPObjectBytes else {
            throw CASServiceError.objectTooLarge(size: blob.data.count, limit: CASLimits.maxHTTPObjectBytes)
        }
        var request = URLRequest(url: objectURL(digest))
        request.httpMethod = "PUT"
        request.httpBody = Data(blob.data)
        request.setValue(blob.refs.map(\.hex).joined(separator: ","), forHTTPHeaderField: "X-Cas-Refs")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CASClientError("PUT \(digest.hex) failed with status \(status)")
        }
        return digest
    }

    /// Fetches an object over plain HTTP, unauthenticated: the digest is the
    /// only credential a CAS entry has ever needed, since it is an
    /// unguessable hash of the content it names.
    public func get(_ digest: CASDigest) async throws -> CASBlob? {
        var request = URLRequest(url: objectURL(digest))
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CASClientError("GET \(digest.hex): no HTTP response")
        }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw CASClientError("GET \(digest.hex) failed with status \(http.statusCode)")
        }
        let refsHeader = http.value(forHTTPHeaderField: "X-Cas-Refs") ?? ""
        let refs = try refsHeader.isEmpty ? [] : refsHeader.split(separator: ",").map { part -> CASDigest in
            guard let parsed = CASDigest(hex: String(part)) else {
                throw CASClientError("object \(digest.hex) has invalid ref \(part)")
            }
            return parsed
        }
        let blob = CASBlob(refs: refs, data: [UInt8](data))
        guard blob.digest == digest else {
            throw CASClientError("object \(digest.hex) does not match its digest")
        }
        return blob
    }

    public func actionGet(_ key: CASDigest) async throws -> CASDigest? {
        guard let value = try await service.actionGet(key: key.hex) else { return nil }
        guard let parsed = CASDigest(hex: value) else {
            throw CASClientError("action \(key.hex) has invalid value \(value)")
        }
        return parsed
    }

    /// `actionGet` for many keys in one round trip; answers are in the keys' order.
    public func actionGetMany(_ keys: [CASDigest]) async throws -> [CASDigest?] {
        let replies = try await service.actionGetMany(keys: keys.map(\.hex))
        guard replies.count == keys.count else {
            throw CASClientError("asked for \(keys.count) actions, got \(replies.count) answers")
        }
        return try zip(keys, replies).map { key, reply in
            guard let reply else { return nil }
            guard let parsed = CASDigest(hex: reply) else {
                throw CASClientError("action \(key.hex) has invalid value \(reply)")
            }
            return parsed
        }
    }

    public func actionPut(_ key: CASDigest, value: CASDigest) async throws {
        try await service.actionPut(key: key.hex, value: value.hex)
    }

    public func close() async {
        system.close()
        await system.wait()
    }
}
