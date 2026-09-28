import CASProtocol
import Distributed
import JavaScriptKit
import WorkersDistributed
import WorkersSwift

private let actorSystem = WorkersActorSystem()

private let casService: CASService = {
    let service = CASService(actorSystem: actorSystem)
    actorSystem.host(service)
    return service
}()

/// PR #12's fixed entry point. RPCGateway relays native WebSocket calls here.
@RPC
func __workersSwiftDistributedCall(
    _ identifier: String,
    _ arguments: JSValue,
    _ genericSubstitutions: [String]
) async throws -> JSValue {
    _ = casService
    return try await actorSystem.receive(
        identifier: identifier,
        arguments: arguments,
        genericSubstitutions: genericSubstitutions
    )
}

@Event(.fetch)
func fetch(req: Request, env: Env, ctx: Context) async throws -> Response {
    guard req.path == WorkersActorSystem.gatewayPath else {
        return .error("Not Found", 404)
    }

    let gateways = env.durableObject("RPCGATEWAY")
    return try await gateways.get(id: gateways.newUniqueID()).fetch(req)
}
