import CASProtocol
import WorkerKit
import WorkerKitDistributed

/// The largest call body accepted. A chunk is 256 KiB, which base64 and the JSON
/// envelope grow to well under this; a bigger body is not a call this service makes.
let maxRPCBodyBytes = 2 << 20

/// `POST /__rpc`: one call in the same `{"id","identifier","arguments",...}` JSON
/// the WebSocket carries, answered with the `{"id","result"}` or `{"id","error"}`
/// reply, served by the Worker itself. The service is stateless, so a request
/// needs no Durable Object of its own, no upgrade and no connection that can
/// hibernate; a client pays one round trip per call and nothing per connection.
/// Authentication happens before this, as for the WebSocket; `scope` is the one
/// the request was addressed under (`/{scope}/__rpc`), so a call only ever sees
/// that scope's store.
///
/// The body is only read once its declared length is known to be within
/// `maxRPCBodyBytes`, because reading it materializes all of it: a call with no
/// length (chunked) or an oversized one is refused up front.
func rpcResponse(_ req: Request, env: Env, scope: String) async -> Response {
    guard let declared = req.headers.get("content-length"), let length = Int64(declared), length >= 0 else {
        return .error("A Content-Length is required", 411)
    }
    guard length <= Int64(maxRPCBodyBytes) else {
        return .error("The call is larger than \(maxRPCBodyBytes) bytes", 413)
    }
    guard let body = try? await req.text(), !body.isEmpty else {
        return .error("Expected a JSON call in the request body", 400)
    }
    guard body.utf8.count <= maxRPCBodyBytes else {
        return .error("The call is larger than \(maxRPCBodyBytes) bytes", 413)
    }
    let hosted = hostCASService(env: env, scope: scope)
    let reply = await hosted.system.receiveJSON(body)
    return Response.text(reply, status: 200).withHeader("content-type", "application/json")
}
