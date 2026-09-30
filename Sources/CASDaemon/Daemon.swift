import CASProtocol
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

/// The cache daemon: the Worker's own protocol, served on the loopback.
///
/// A client (the swiftc plugin) is pointed at `http://127.0.0.1:<port>/<scope>`
/// and cannot tell it from the Worker: `/{scope}/__rpc` upgrades to a WebSocket
/// carrying the same `{"id","identifier","arguments"}` calls, and
/// `/{scope}/objects/{digest}` answers `GET`/`PUT`. Behind it each scope has a
/// `ScopeCache` and one upstream connection that outlives every compiler process.
///
/// It listens on the loopback only and does not authenticate: anything on the
/// machine that can connect can read and write through the token it holds
/// upstream. Fine for a developer machine or CI runner, not for a shared host.
public final class CASDaemon: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var host: String
        public var port: Int
        public var directory: URL
        public var maxBytes: Int64
        public var makeUpstream: @Sendable (_ scope: String) -> any CASUpstream

        public init(
            host: String = "127.0.0.1", port: Int = 0, directory: URL, maxBytes: Int64 = 4 << 30,
            makeUpstream: @escaping @Sendable (String) -> any CASUpstream
        ) {
            self.host = host
            self.port = port
            self.directory = directory
            self.maxBytes = maxBytes
            self.makeUpstream = makeUpstream
        }
    }

    enum Connection {
        case webSocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, String)
        case http(NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>)
    }

    private let configuration: Configuration
    private let lock = NSLock()
    private var scopes: [String: Task<ScopeCache, Error>] = [:]
    private var serving: Task<Void, Never>?
    public let log: @Sendable (String) -> Void

    public init(_ configuration: Configuration, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.configuration = configuration
        self.log = log
    }

    static let scopePattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9._-]{1,64}$")

    /// `/{scope}/rest…`, or `/rest…` for the default scope. Nil for a scope name
    /// that is not a plain file name: it becomes a directory.
    static func route(_ uri: String) -> (scope: String, rest: [String])? {
        let path = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else { return nil }
        if first == "__rpc" || first == "objects" { return ("default", parts) }
        let range = NSRange(first.startIndex..., in: first)
        guard scopePattern.firstMatch(in: first, range: range) != nil, first != ".", first != ".." else { return nil }
        return (first, Array(parts.dropFirst()))
    }

    func scope(_ name: String) async throws -> ScopeCache {
        let task: Task<ScopeCache, Error> = lock.withLock {
            if let existing = scopes[name] { return existing }
            let created = Task { [configuration, log] in
                let cache = try await ScopeCache(
                    directory: configuration.directory.appendingPathComponent(name),
                    maxBytes: configuration.maxBytes, upstream: configuration.makeUpstream(name), log: log)
                await cache.resumePending()
                return cache
            }
            scopes[name] = created
            return created
        }
        return try await task.value
    }

    /// Everything acknowledged has reached upstream, or is queued on disk.
    public func drain() async {
        let tasks = lock.withLock { Array(scopes.values) }
        for task in tasks {
            if let cache = try? await task.value { await cache.drain() }
        }
    }

    // MARK: Serving

    /// Binds and starts serving; returns the port.
    public func start() async throws -> Int {
        let server = try await ServerBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: configuration.host, port: configuration.port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    let upgrader = NIOTypedWebSocketServerUpgrader<Connection>(
                        maxFrameSize: 1 << 24,
                        shouldUpgrade: { channel, head in
                            channel.eventLoop.makeSucceededFuture(
                                Self.route(head.uri)?.rest == ["__rpc"] ? HTTPHeaders() : nil)
                        },
                        upgradePipelineHandler: { channel, head in
                            channel.eventLoop.makeCompletedFuture {
                                let async = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
                                    wrappingChannelSynchronously: channel)
                                return .webSocket(async, Self.route(head.uri)?.scope ?? "default")
                            }
                        })
                    let upgrade = NIOTypedHTTPServerUpgradeConfiguration<Connection>(
                        upgraders: [upgrader],
                        notUpgradingCompletionHandler: { channel in
                            channel.eventLoop.makeCompletedFuture {
                                let async = try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(
                                    wrappingChannelSynchronously: channel)
                                return .http(async)
                            }
                        })
                    return try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                        configuration: .init(upgradeConfiguration: upgrade))
                }
            }
        let port = server.channel.localAddress?.port ?? configuration.port
        serving = Task { [self] in
            do {
                try await server.executeThenClose { inbound in
                    try await withThrowingDiscardingTaskGroup { group in
                        for try await upgraded in inbound {
                            group.addTask { await self.handle(upgraded) }
                        }
                    }
                }
            } catch {
                log("server stopped: \(error)")
            }
        }
        return port
    }

    public func stop() async {
        serving?.cancel()
        await serving?.value
        serving = nil
    }

    private func handle(_ upgraded: EventLoopFuture<Connection>) async {
        do {
            switch try await upgraded.get() {
            case .webSocket(let channel, let name):
                try await serveWebSocket(channel, scope: name)
            case .http(let channel):
                try await serveHTTP(channel)
            }
        } catch {
            log("connection ended: \(error)")
        }
    }
}
