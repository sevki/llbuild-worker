import JavaScriptKit
import WorkerKitDistributed
import WorkerKit

/// Native clients connect to `/__rpc` over a WebSocket. Each connection gets
/// its own `CASGateway`, which hosts a stateless `CASService` in front of the
/// per-shard Durable Objects.
@Event(.fetch)
func fetch(req: Request, env: Env, ctx: Context) async throws -> Response {
    guard req.path == WorkersActorSystem.gatewayPath else {
        return .error("Not Found", 404)
    }

    let gateways = env.durableObject("CASGATEWAY")
    return try await gateways.get(id: gateways.newUniqueID()).fetch(req)
}
