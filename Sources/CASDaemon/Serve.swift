import CASProtocol
import Foundation
import NIOCore
import NIOHTTP1
import NIOWebSocket

/// The largest object body accepted over HTTP, as at the Worker.
private let maxBodyBytes = CASLimits.maxHTTPObjectBytes + 1024

extension CASDaemon {
    // MARK: WebSocket: the control plane

    func serveWebSocket(_ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, scope name: String) async throws {
        let cache = try await scope(name)
        try await channel.executeThenClose { inbound, outbound in
            try await withThrowingTaskGroup(of: Void.self) { group in
                var message = ByteBuffer()
                for try await frame in inbound {
                    switch frame.opcode {
                    case .ping:
                        try await outbound.write(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData))
                    case .connectionClose:
                        try await outbound.write(WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.unmaskedData))
                        group.cancelAll()
                        return
                    case .text, .continuation:
                        var chunk = frame.unmaskedData
                        message.writeBuffer(&chunk)
                        guard frame.fin else { continue }
                        let text = String(buffer: message)
                        message = ByteBuffer()
                        // Calls run concurrently and are told apart by `id`, as
                        // at the Worker.
                        group.addTask {
                            let reply = await self.call(text, in: cache)
                            try? await outbound.write(
                                WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: reply)))
                        }
                    default:
                        break
                    }
                }
            }
        }
    }

    /// One `{"id","identifier","arguments"}` call, answered `{"id","result"}`.
    /// Only what a cache client asks is served. The caches never answer with an
    /// error for trouble upstream: a lookup that fails is a miss, a write is
    /// acknowledged and retried behind the client.
    func call(_ text: String, in cache: ScopeCache) async -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let identifier = object["identifier"] as? String else {
            return Self.reply(id: nil, error: "malformed call: missing identifier")
        }
        let id = object["id"]
        let arguments = object["arguments"] as? [Any] ?? []
        func digest(_ index: Int) -> CASDigest? {
            guard index < arguments.count, let text = arguments[index] as? String else { return nil }
            return Self.fullDigest(text)
        }
        // Mangled names end in the method's name and labels: `8contains6digest…`.
        if identifier.contains("8contains6digest") {
            guard let d = digest(0) else { return Self.reply(id: id, error: "invalid digest") }
            return Self.reply(id: id, result: await cache.contains(d))
        }
        if identifier.contains("9actionGet3key") {
            guard let k = digest(0) else { return Self.reply(id: id, error: "invalid digest") }
            return Self.reply(id: id, result: await cache.actionGet(k)?.hex ?? NSNull())
        }
        if identifier.contains("9actionPut3key5value") {
            guard let k = digest(0), let v = digest(1) else { return Self.reply(id: id, error: "invalid digest") }
            // The Worker refuses an action whose value it does not hold; so does
            // this, so a client cannot tell the difference.
            guard await cache.contains(v) else { return Self.reply(id: id, error: "object \(v.hex) is not stored") }
            do {
                try await cache.actionPut(k, value: v)
            } catch {
                return Self.reply(id: id, error: "the daemon could not record the action: \(error)")
            }
            return Self.reply(id: id, result: nil)
        }
        if identifier.contains("6status") {
            return Self.reply(id: id, result: [
                "service": "llbuild-worker-daemon", "protocolVersion": "0.3.0", "storageConfigured": true,
            ] as [String: Any])
        }
        return Self.reply(id: id, error: "the cache daemon does not serve \(identifier)")
    }

    static func reply(id: Any?, result: Any?) -> String {
        var body: [String: Any] = [:]
        if let id { body["id"] = id }
        if let result { body["result"] = result }
        return serialize(body)
    }

    static func reply(id: Any?, error: String) -> String {
        var body: [String: Any] = ["error": error]
        if let id { body["id"] = id }
        return serialize(body)
    }

    private static func serialize(_ body: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func fullDigest(_ text: String) -> CASDigest? {
        guard let parsed = CASDigest(hex: text), parsed.bytes.count == CASIdentity.digestSize else { return nil }
        return parsed
    }

    // MARK: HTTP: objects

    func serveHTTP(_ channel: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>) async throws {
        try await channel.executeThenClose { inbound, outbound in
            var head: HTTPRequestHead?
            var body = ByteBuffer()
            var tooLarge = false
            for try await part in inbound {
                switch part {
                case .head(let request):
                    head = request
                    body = ByteBuffer()
                    tooLarge = false
                case .body(var chunk):
                    if body.readableBytes + chunk.readableBytes > maxBodyBytes {
                        tooLarge = true
                    } else if !tooLarge {
                        body.writeBuffer(&chunk)
                    }
                case .end:
                    guard let request = head else { continue }
                    let response = tooLarge
                        ? Response(status: .payloadTooLarge)
                        : await self.respond(to: request, body: body)
                    var headers = HTTPHeaders()
                    headers.add(name: "content-length", value: "\(response.body.readableBytes)")
                    for (name, value) in response.headers { headers.add(name: name, value: value) }
                    let keepAlive = request.isKeepAlive && !tooLarge
                    if !keepAlive { headers.add(name: "connection", value: "close") }
                    try await outbound.write(.head(HTTPResponseHead(version: request.version, status: response.status, headers: headers)))
                    if request.method != .HEAD, response.body.readableBytes > 0 {
                        try await outbound.write(.body(.byteBuffer(response.body)))
                    }
                    try await outbound.write(.end(nil))
                    if !keepAlive { return }
                    head = nil
                }
            }
        }
    }

    struct Response {
        var status: HTTPResponseStatus
        var headers: [(String, String)] = []
        var body = ByteBuffer()
    }

    func respond(to request: HTTPRequestHead, body: ByteBuffer) async -> Response {
        guard let (scopeName, rest) = Self.route(request.uri), let cache = try? await scope(scopeName) else {
            return Response(status: .notFound)
        }
        switch (request.method, rest.count) {
        case (.GET, 2), (.HEAD, 2):
            guard rest[0] == "objects", let digest = Self.fullDigest(rest[1]) else { return Response(status: .notFound) }
            guard let blob = await cache.get(digest) else { return Response(status: .notFound) }
            return Response(
                status: .ok,
                headers: [
                    ("content-type", "application/octet-stream"),
                    ("x-cas-refs", blob.refs.map(\.hex).joined(separator: ",")),
                ],
                body: ByteBuffer(bytes: blob.data))
        case (.PUT, 2):
            guard rest[0] == "objects", let digest = Self.fullDigest(rest[1]) else { return Response(status: .notFound) }
            let header = request.headers.first(name: "x-cas-refs") ?? ""
            var refs: [CASDigest] = []
            for part in header.split(separator: ",") {
                guard let ref = Self.fullDigest(String(part)) else { return Response(status: .badRequest) }
                refs.append(ref)
            }
            let blob = CASBlob(refs: refs, data: Array(body.readableBytesView))
            guard blob.digest == digest else { return Response(status: .badRequest) }
            do {
                try await cache.put(blob)
            } catch {
                return Response(status: .badGateway)
            }
            return Response(status: .created)
        case (.POST, 1):
            guard rest[0] == "__rpc" else { return Response(status: .notFound) }
            let reply = await call(String(buffer: body), in: cache)
            return Response(
                status: .ok, headers: [("content-type", "application/json")], body: ByteBuffer(string: reply))
        default:
            return Response(status: .notFound)
        }
    }
}
