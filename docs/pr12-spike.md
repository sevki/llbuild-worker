# workers-swift transport spike

This repository consumes the `WorkersDistributed` product from the merged workers-swift PR #12 at revision `2db5bab408d8a2aeae720cd123a92b32e2d73c43`.

## What this branch proves

- A distributed actor declaration can be shared by a native executable and a Worker Wasm target.
- The Worker can host that actor at the `__workersSwiftDistributedCall` entry point.
- A native executable can resolve the actor and call it through `WorkersActorSystem(worker:)`, the per-connection `RPCGateway`, and the Worker `SELF` binding.
- CI is configured to build the native client, run protocol type tests, and compile the Worker bundle.

`casctl status` deliberately reports that storage is not configured and exits with code 2. That is the honest result for this slice: it validates the service route and CLI without pretending volatile Worker memory is durable CAS storage.

## Why CAS operations are not in this transport slice

The native transport is JSON over WebSocket and its gateway relays to a Worker-hosted actor. It is well suited to control calls, but large CAS payloads need a streaming data path. More importantly, an actor hosted as a Worker singleton cannot directly capture a Durable Object namespace binding from the gateway's `@RPC` entry point. Durable storage must be designed with the Worker request and Durable Object routing model in mind.

The next service increment should add a Worker HTTP data plane that routes by CAS ID to durable shard objects, with the actor protocol coordinating status and bounded metadata calls. Before implementing `putKnown`, pin llbuild2 and add identity conformance vectors. The adapter must implement `FXTypedCASDatabase<DataID, CASObject>` (or `FXCASDatabase` for `FXDataID` / `FXCASObject`), including `supportedFeatures`, `contains`, `get`, `identify`, `put`, and `put(knownID:)`.

## CI

The workflow has separate native and Worker Wasm jobs. Native tests cover Codable wire types and the CLI is compiled. The Worker job installs the matching Swift Wasm SDK and runs workers-swift's command plugin. There is not yet an end-to-end deployment test because this slice does not implement object storage.
