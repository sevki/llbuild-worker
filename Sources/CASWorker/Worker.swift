import JavaScriptKit
import WorkerKitDistributed
import WorkerKit

/// Native clients connect to `/__rpc` over a WebSocket. Each connection gets
/// its own `CASGateway`, which hosts a stateless `CASService` in front of the
/// per-shard Durable Objects.
@Event(.fetch)
func fetch(req: Request, env: Env, ctx: Context) async throws -> Response {
    if req.path == "/setup" {
        return .text(setupScript, status: 200)
    }

    // Public like the page it feeds: a WebSocket that pushes counter updates.
    if req.path == "/stats/live" {
        guard env.jsObject["CASSTATS"].object != nil else { return .error("Statistics are not enabled", 404) }
        let stats = env.durableObject("CASSTATS")
        return try await stats.get(id: stats.idFromName("stats")).fetch(req)
    }

    if req.path == "/stats" || req.path == "/stats.json" {
        return await statsResponse(env: env, json: req.path == "/stats.json")
    }

    if req.path == "/" {
        return indexResponse()
    }

    guard req.path == WorkersActorSystem.gatewayPath else {
        return .error("Not Found", 404)
    }

    // Fail closed: without a configured CAS_TOKEN nobody gets in.
    guard let expected = env.secret("CAS_TOKEN"), !expected.isEmpty else {
        return .error("Service not configured", 503)
    }
    guard let presented = presentedToken(url: req.url, authorization: req.headers.get("authorization")),
          constantTimeEqual(presented, expected) else {
        return .error("Unauthorized", 401)
    }

    let gateways = env.durableObject("CASGATEWAY")
    return try await gateways.get(id: gateways.newUniqueID()).fetch(req)
}

/// The token a client presented: `Authorization: Bearer <token>` if sent,
/// otherwise the `token` query parameter. The native WebSocket client has no
/// way to add headers to its upgrade request, so it carries the token in the
/// URL. Tokens are URL-safe (hex or base64url), so no percent-decoding.
func presentedToken(url: String, authorization: String?) -> String? {
    if let authorization, authorization.hasPrefix("Bearer ") {
        return String(authorization.dropFirst("Bearer ".count))
    }
    guard let question = url.firstIndex(of: "?") else { return nil }
    let query = url[url.index(after: question)...].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
    for pair in query.split(separator: "&") {
        if pair.hasPrefix("token=") {
            return String(pair.dropFirst("token=".count))
        }
    }
    return nil
}

/// Compares without an early exit on the first differing byte.
func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let a = Array(a.utf8), b = Array(b.utf8)
    var difference = a.count ^ b.count
    for index in 0..<max(a.count, b.count) {
        difference |= Int(index < a.count ? a[index] : 0) ^ Int(index < b.count ? b[index] : 0)
    }
    return difference == 0
}
