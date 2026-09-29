# WorkerKit transport spike

This repository consumes the `WorkerKitDistributed` product from WorkerKit: the native transport merged in PR #12 plus [PR #13](https://github.com/sevki/WorkerKit/pull/13)'s client frame-size fix, pinned at its merge commit `aaad96f185eaf30e74f8e817d683c10511de7a7b`.

## What this branch proves

- A distributed actor declaration can be shared by a native executable and a Worker Wasm target.
- A Durable Object can host that actor locally (`CASGateway`) and reach per-shard actors in other Durable Objects.
- A native executable can resolve the actor and call it through `WorkersActorSystem(worker:)` over the WebSocket gateway.
- CI builds and tests all of it, including a workerd end-to-end run.

## How storage reaches the actor

`RPCGateway` relays each call to the Worker's `@RPC` entry point, which has no `env`, so an actor hosted there cannot reach a Durable Object namespace. This repository therefore uses its own gateway, `CASGateway`, a Durable Object that accepts the WebSocket itself and hosts the `CASService` locally through `WorkersActorSystem.receiveJSON(_:)`. Being a Durable Object it receives `env`, so the service can call the per-shard `CASShard` actors (`WorkersActorSystem(durableObjects:)`, one actor per Durable Object id, the pattern WorkerKit's Fork/Philosopher example uses).

## Transport limits found while building this

- The native client's WebSocket frame limit defaulted to 16 KiB, so any reply over about 12 KB of payload closed the connection with 1009 even though the message limit was 1 MiB. Fixed in [WorkerKit#13](https://github.com/sevki/WorkerKit/pull/13), which this repository now pins.
- With that fixed, the practical ceiling is the 1 MiB message limit. Base64 inflates payloads by a third, so `CASLimits.maxObjectBytes` is 512 KiB.
- `WorkersActorSystem` hosts one actor per system, so the service is one actor (objects and action cache together) and the sharding actors sit behind it.

Before implementing llbuild2's `putKnown`, pin llbuild2 and add identity conformance vectors. An llbuild2 adapter must implement `FXTypedCASDatabase<DataID, CASObject>` (or `FXCASDatabase` for `FXDataID` / `FXCASObject`), including `supportedFeatures`, `contains`, `get`, `identify`, `put`, and `put(knownID:)`.

## CI

The workflow has separate native and Worker Wasm jobs. The native job runs the tests and `Scripts/test-compilation-cache.sh` (real swiftc miss/hit/replay through the plugin). The Worker job installs the matching Swift Wasm SDK, builds the bundle, and runs `Scripts/test-remote-cache.sh`, which serves it in workerd and exercises `castool` and two developers sharing a compile cache.
