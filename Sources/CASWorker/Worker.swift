import CASProtocol
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
