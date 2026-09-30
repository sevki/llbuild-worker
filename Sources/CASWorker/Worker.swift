import CASProtocol
import JavaScriptKit
import WorkerKitDistributed
import WorkerKit

/// Splits `/scope/rest...` into its leading path segment and everything
/// after it, e.g. `/prod/stats` -> `("prod", "/stats")`. `fetch(_:_:_:)` uses
/// this to let a scope isolate its own store (shards, gateway and stats)
/// from every other one under the same deployment — `xcache.devtoo.ls/prod`
/// and `/dev` never share objects, actions or traffic counters.
func splitScope(_ path: String) -> (scope: String, rest: String)? {
    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    guard let first = parts.first, isValidScope(first) else { return nil }
    return (String(first), "/" + parts.dropFirst().joined(separator: "/"))
}

private func isValidScope<S: StringProtocol>(_ scope: S) -> Bool {
    !scope.isEmpty && scope.count <= 63
        && scope.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
}

/// The scope `path` addresses `WorkersActorSystem.gatewayPath` under: bare
/// `/__rpc` (no scope segment, what `WorkersActorSystem(worker:)` builds for
/// a `workerURL` with no path) resolves to `"default"`, exactly like
/// `route(...)`'s own default-scope attempt — a bare `splitScope(path)` here
/// would instead misread `/__rpc`'s own path component as the scope name.
/// `CASGateway.fetch(_:)` uses this so it can never drift from `route(...)`'s
/// resolution of the same request.
func gatewayScope(_ path: String) -> String? {
    if path == WorkersActorSystem.gatewayPath { return "default" }
    if let (scope, rest) = splitScope(path), rest == WorkersActorSystem.gatewayPath { return scope }
    return nil
}

/// `scheme://host` from an absolute URL string, dropping its path and query.
func origin(of url: String) -> String {
    guard let schemeEnd = url.range(of: "://") else { return url }
    let afterScheme = url[schemeEnd.upperBound...]
    let hostEnd = afterScheme.firstIndex(of: "/") ?? afterScheme.endIndex
    return String(url[..<schemeEnd.upperBound]) + String(afterScheme[..<hostEnd])
}

/// How many gateway Durable Objects share the `/__rpc` connections. A compiler
/// starts a short-lived process per source file, each opening its own connection,
/// and a brand-new Durable Object per connection cost about 1.4 s to start (a
/// median 1.59 s upgrade against 0.22 s for a route that touches none). A few
/// long-lived ones stay warm instead; the gateway keeps no per-connection state,
/// so connections can share one, and several spread the message handling.
let gatewayCount = 8

/// Native clients connect to `/{scope}/__rpc` over a WebSocket. Each
/// connection gets its own `CASGateway`, which hosts a stateless `CASService`
/// in front of the per-shard Durable Objects. Object bodies instead travel
/// over the plain-HTTP `/{scope}/objects/{digest}` sibling: see
/// `objectsResponse(req:env:scope:digest:)` in Shard.swift.
///
/// A request with no scope segment (`/__rpc`, `/stats`, ...) is handled as
/// scope `"default"`, so a deployment that never opts into multiple scopes
/// keeps working exactly as it did before scopes existed.
@Event(.fetch)
func fetch(req: Request, env: Env, ctx: Context) async throws -> Response {
    if req.path == "/" {
        return indexResponse()
    }

    if let response = try await route(req: req, env: env, path: req.path, scope: "default") {
        return response
    }
    if let (scope, rest) = splitScope(req.path),
       let response = try await route(req: req, env: env, path: rest, scope: scope) {
        return response
    }
    return .error("Not Found", 404)
}

/// Matches `path` against every route this Worker serves within `scope`, or
/// returns `nil` for no match so the caller can retry after splitting off a
/// scope segment.
private func route(req: Request, env: Env, path: String, scope: String) async throws -> Response? {
    if path == "/setup" {
        return .text(setupScript(scope: scope, remoteURL: origin(of: req.url) + "/" + scope), status: 200)
    }

    // Public like the page it feeds: a WebSocket that pushes counter updates.
    if path == "/stats/live" {
        guard env.jsObject["CASSTATS"].object != nil else { return .error("Statistics are not enabled", 404) }
        let stats = env.durableObject("CASSTATS")
        return try await stats.get(id: stats.idFromName("stats/\(scope)")).fetch(req)
    }

    if path == "/stats" || path == "/stats.json" {
        return await statsResponse(env: env, scope: scope, json: path == "/stats.json")
    }

    if path.hasPrefix("/objects/") {
        return try await objectsResponse(
            req: req, env: env, scope: scope, digest: String(path.dropFirst("/objects/".count)))
    }

    guard path == WorkersActorSystem.gatewayPath else {
        return nil
    }

    // Fail closed: without a configured CAS_TOKEN nobody gets in.
    guard let expected = env.secret("CAS_TOKEN"), !expected.isEmpty else {
        return .error("Service not configured", 503)
    }
    guard let presented = presentedToken(url: req.url, authorization: req.headers.get("authorization")),
          constantTimeEqual(presented, expected) else {
        return .error("Unauthorized", 401)
    }

    // A plain request carries one call; only the WebSocket needs a gateway.
    if req.method == "POST" {
        return await rpcResponse(req, env: env, scope: scope)
    }

    let gateways = env.durableObject("CASGATEWAY")
    let gateway = "gateway-\(Int.random(in: 0..<gatewayCount))"
    return try await gateways.get(id: gateways.idFromName(gateway)).fetch(req)
}
