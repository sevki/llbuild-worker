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
public struct CASDaemonError: Error, CustomStringConvertible {
    public var description: String
    init(_ description: String) { self.description = description }
}

public final class CASDaemon: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var host: String
        public var port: Int
        public var directory: URL
        public var maxBytes: Int64
        /// Most action records kept on disk per scope; the oldest go first.
        public var maxActions: Int
        /// How often actions still waiting for the Worker are tried again.
        public var retryInterval: Duration
        /// Most scopes held open at once; beyond it the one unused for longest is
        /// retired to make room, and if every one has work pending a new one is refused.
        public var maxScopes: Int
        /// Most bytes of acknowledged-but-unsent objects a scope keeps; a PUT that would pass
        /// it is refused (507). Defaults to `maxBytes`, and at least 64 MiB.
        public var maxSpoolBytes: Int64?
        /// Most acknowledged actions waiting for the Worker per scope; a new one past it is
        /// refused until some have been sent.
        public var maxPendingActions: Int
        /// Most scope directories kept on disk, open or not: beyond it the ones unused
        /// for longest are deleted, so the disk the daemon can use is bounded by this
        /// times `maxBytes` (plus what is spooled and recorded per scope).
        public var maxScopeDirectories: Int
        /// A pause this long in a scope's lookups ends one build's trace and begins another's; it has to outlast the quiet stretches inside a build (long compiles, linking).
        public var sessionGap: Duration
        /// How long after the last new lookup a build's trace is uploaded.
        public var traceDebounce: Duration
        public var makeUpstream: @Sendable (_ scope: String) -> any CASUpstream

        public init(
            host: String = "127.0.0.1", port: Int = 0, directory: URL, maxBytes: Int64 = 4 << 30,
            maxActions: Int = 1_000_000, retryInterval: Duration = .seconds(60), maxScopes: Int = 32, maxScopeDirectories: Int = 128, maxSpoolBytes: Int64? = nil, maxPendingActions: Int = 100_000,
            sessionGap: Duration = .seconds(300), traceDebounce: Duration = .seconds(20),
            makeUpstream: @escaping @Sendable (String) -> any CASUpstream
        ) {
            self.host = host
            self.port = port
            self.directory = directory
            self.maxBytes = maxBytes
            self.maxActions = maxActions
            self.retryInterval = retryInterval
            self.maxScopes = maxScopes
            self.maxSpoolBytes = maxSpoolBytes
            self.maxPendingActions = maxPendingActions
            self.maxScopeDirectories = maxScopeDirectories
            self.sessionGap = sessionGap
            self.traceDebounce = traceDebounce
            self.makeUpstream = makeUpstream
        }
    }

    enum Connection {
        case webSocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, String)
        case http(NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>)
    }

    private let configuration: Configuration
    private let lock = NSLock()
    private var scopes: [String: (task: Task<ScopeCache, Error>, used: ContinuousClock.Instant)] = [:]
    private var serving: Task<Void, Never>?
    public let log: @Sendable (String) -> Void

    public init(_ configuration: Configuration, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.configuration = configuration
        self.log = log
    }

    /// The scope names the Worker accepts (`isValidScope` in Worker.swift): ASCII letters and
    /// digits, `-` and `_`, up to 63 of them. A scope the Worker would not route could be
    /// cached here but never reach it.
    static let scopePattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{1,63}$")

    /// `/{scope}/rest…`, or `/rest…` for the default scope. Nil for a scope name
    /// that is not a plain file name: it becomes a directory.
    static func route(_ uri: String) -> (scope: String, rest: [String])? {
        let path = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else { return nil }
        // The default scope's own routes: `/__rpc` and `/objects/{digest}`. Anything longer is a scope
        // that happens to be called `__rpc` or `objects`, as the Worker reads it.
        if (first == "__rpc" && parts.count == 1) || (first == "objects" && parts.count == 2) { return ("default", parts) }
        let range = NSRange(first.startIndex..., in: first)
        guard scopePattern.firstMatch(in: first, range: range) != nil else { return nil }
        return (first, Array(parts.dropFirst()))
    }

    /// The scope's directory name. File systems that ignore case (macOS's default)
    /// would give `Prod` and `prod` one directory, so a capital is written as `_` and
    /// its lower-case letter, and a literal `_` as `__`: different names never meet.
    static func directoryName(for scope: String) -> String {
        var name = ""
        for character in scope {
            if character == "_" {
                name += "__"
            } else if character.isUppercase {
                name += "_" + character.lowercased()
            } else {
                name.append(character)
            }
        }
        return name
    }

    /// Serializes the admission of new scopes, so that the room made and the scope
    /// added are one step and a burst cannot overshoot `maxScopes`.
    private let admission = AsyncSemaphore(1)

    /// The scope, marked in use: it is not retired until `release` is called. A caller
    /// that cannot go on holding it (it failed to open) gets the error.
    func acquire(_ name: String) async throws -> ScopeCache {
        for _ in 0..<4 {
            let cache = try await scope(name)
            if await cache.beginUse() { return cache }
            // Retired just now: wait for the admission that is replacing it, then look again.
            await admission.acquire()
            await admission.release()
        }
        throw CASDaemonError("scope \(name) is being retired")
    }

    /// Runs `body` with the scope held open: one that is in use is never retired.
    func withScope<T: Sendable>(_ name: String, _ body: @Sendable (ScopeCache) async throws -> T) async throws -> T {
        let cache = try await acquire(name)
        do {
            let result = try await body(cache)
            await cache.endUse()
            return result
        } catch {
            await cache.endUse()
            throw error
        }
    }

    func scope(_ name: String) async throws -> ScopeCache {
        if let existing = lock.withLock({ () -> Task<ScopeCache, Error>? in
            scopes[name]?.used = .now
            return scopes[name]?.task
        }) {
            return try await opened(name, existing)
        }
        await admission.acquire()
        do {
            let cache = try await admit(name)
            await admission.release()
            return cache
        } catch {
            await admission.release()
            throw error
        }
    }

    /// Whether the scope directory holds objects a client was told were stored but that
    /// no action has claimed yet: their only copy is in the spool, until the spool's
    /// own expiry (a day), and deleting the directory would lose them.
    static func holdsRecentSpool(_ scopeDirectory: URL) -> Bool {
        let cutoff = Date().addingTimeInterval(-ScopeCache.spoolMaxAge)
        let spool = scopeDirectory.appendingPathComponent("spool")
        guard FileManager.default.fileExists(atPath: spool.path) else { return false }
        // A spool that exists but cannot be read through is protected: what is in it is unknown.
        var unreadable = false
        guard let files = FileManager.default.enumerator(
            at: spool, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            errorHandler: { _, _ in unreadable = true; return true }) else { return true }
        while let file = files.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return true }
            if values.isRegularFile == true, (values.contentModificationDate ?? .distantPast) > cutoff { return true }
        }
        if unreadable { return true }
        return false
    }

    /// Deletes the scope directories used longest ago until `maxScopeDirectories`
    /// remain (counting the one about to be opened). Never one that is open, and never
    /// one that still holds acknowledged writes waiting for the Worker: those are
    /// retried when the scope is next opened, and deleting them would lose them.
    /// False if the cap cannot be met without doing either.
    private func pruneDirectories(keeping name: String) -> Bool {
        let root = configuration.directory
        let open = Set(lock.withLock { scopes.keys.map(Self.directoryName(for:)) })
        let protected = open.union([Self.directoryName(for: name)])
        // A root that is not there yet has nothing to prune; one that is there but cannot be
        // listed is not "empty", and nothing may be admitted without being able to count.
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])
        } catch {
            guard !FileManager.default.fileExists(atPath: root.path) else { return false }
            entries = []
        }
        var directories = entries.compactMap { url -> (url: URL, used: Date)? in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            return (url, values?.contentModificationDate ?? .distantPast)
        }
        let isNew = !directories.contains { $0.url.lastPathComponent == Self.directoryName(for: name) }
        let room = configuration.maxScopeDirectories - (isNew ? 1 : 0)
        guard directories.count > room else { return true }
        directories.sort { $0.used < $1.used }
        var excess = directories.count - room
        for directory in directories where excess > 0 && !protected.contains(directory.url.lastPathComponent) {
            // Only a pending directory that is absent counts as empty; one that cannot be
            // listed may hold acknowledged writes and protects its scope.
            let pendingPath = directory.url.appendingPathComponent("pending").path
            let pending: [String]
            if FileManager.default.fileExists(atPath: pendingPath) {
                guard let listed = try? FileManager.default.contentsOfDirectory(atPath: pendingPath) else { continue }
                pending = listed
            } else {
                pending = []
            }
            guard pending.isEmpty, !Self.holdsRecentSpool(directory.url) else { continue }
            // Only a directory that is gone makes room: one that could not be removed (a
            // stuck file, a transient error) leaves the cap unmet.
            do {
                try FileManager.default.removeItem(at: directory.url)
                excess -= 1
            } catch {
                continue
            }
        }
        return excess <= 0
    }

    /// One new scope, with room made for it, as a single step (see `admission`).
    private func admit(_ name: String) async throws -> ScopeCache {
        if let existing = lock.withLock({ scopes[name]?.task }) { return try await opened(name, existing) }
        try await makeRoom()
        guard pruneDirectories(keeping: name) else {
            throw CASDaemonError("too many scope directories hold writes not yet sent to the Worker (\(configuration.maxScopeDirectories))")
        }
        let task: Task<ScopeCache, Error> = lock.withLock {
            if let existing = scopes[name] { return existing.task }
            let created = Task { [configuration, log] in
                let cache = try await ScopeCache(
                    directory: configuration.directory.appendingPathComponent(Self.directoryName(for: name)),
                    maxBytes: configuration.maxBytes, upstream: configuration.makeUpstream(name),
                    maxSpoolBytes: configuration.maxSpoolBytes, maxPendingActions: configuration.maxPendingActions, maxActions: configuration.maxActions, retryInterval: configuration.retryInterval,
                    sessionGap: configuration.sessionGap, traceDebounce: configuration.traceDebounce, log: log)
                await cache.resumePending()
                return cache
            }
            scopes[name] = (created, .now)
            return created
        }
        return try await opened(name, task)
    }

    /// The scope a task opens; if it could not be opened (a full or unwritable disk,
    /// say) the entry is dropped, so the failure is not kept and does not take a place.
    private func opened(_ name: String, _ task: Task<ScopeCache, Error>) async throws -> ScopeCache {
        do {
            return try await task.value
        } catch {
            lock.withLock { if scopes[name]?.task == task { scopes[name] = nil } }
            throw error
        }
    }

    /// Keeps the number of open scopes within `maxScopes`: the one used longest ago
    /// that has nothing pending is retired. If none can be, a new scope is refused.
    private func makeRoom() async throws {
        while true {
            let oldest = lock.withLock { () -> [(String, Task<ScopeCache, Error>)]? in
                guard scopes.count >= configuration.maxScopes else { return nil }
                return scopes.sorted { $0.value.used < $1.value.used }.map { ($0.key, $0.value.task) }
            }
            guard let candidates = oldest else { return }
            var freed = false
            for (name, task) in candidates {
                guard let cache = try? await task.value, await cache.retire() else { continue }
                lock.withLock { _ = scopes.removeValue(forKey: name) }
                freed = true
                break
            }
            guard freed else {
                throw CASDaemonError("too many scopes open (\(configuration.maxScopes)), all with work pending")
            }
        }
    }

    /// How many scopes are open right now.
    var openScopeCount: Int { lock.withLock { scopes.count } }

    /// One line per scope about what it asked upstream.
    public func summaries() async -> [String] {
        let tasks = lock.withLock { scopes.map { ($0.key, $0.value.task) } }
        var lines: [String] = []
        for (name, task) in tasks {
            if let cache = try? await task.value { lines.append("\(name): \(await cache.summary)") }
        }
        return lines
    }

    /// Everything acknowledged has reached upstream, or is queued on disk.
    public func drain() async {
        let tasks = lock.withLock { scopes.values.map(\.task) }
        for task in tasks {
            if let cache = try? await task.value { await cache.drain() }
        }
    }

    // MARK: Serving

    /// A cache size given in gigabytes, as bytes: finite, positive and small enough to hold
    /// as a byte count (`nil` otherwise, which is a usage error, not a crash).
    public static func cacheBytes(gigabytes text: String) -> Int64? {
        guard let gigabytes = Double(text), gigabytes.isFinite, gigabytes > 0 else { return nil }
        let bytes = gigabytes * 1_073_741_824
        guard bytes >= 1, bytes < Double(Int64.max) / 2 else { return nil }
        return Int64(bytes)
    }

    /// `host:port`, `[v6]:port` or a bare v6 address followed by `:port`: the port is after
    /// the last colon, and a v6 host may be bracketed.
    public static func parseListenAddress(_ text: String) -> (host: String, port: Int)? {
        guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]),
              (0...65535).contains(port) else { return nil }
        var host = String(text[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host.isEmpty ? nil : (host, port)
    }

    /// Whether `host` is an address only this machine can reach.
    static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy { UInt8($0) != nil }
    }

    /// Binds and starts serving; returns the port. Only a loopback address is
    /// accepted: the daemon does not authenticate, and holds the upstream token.
    public func start() async throws -> Int {
        guard Self.isLoopback(configuration.host) else {
            throw CASDaemonError("refusing to listen on \(configuration.host): the daemon does no authentication, so it only serves the loopback")
        }
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
