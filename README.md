# llbuild-worker

A remote content-addressable storage service for Apple llbuild2, implemented as a Cloudflare Worker with Swift and [workers-swift](https://github.com/sevki/workers-swift).

## Current slice

This branch is a transport and service-contract spike based on [workers-swift PR #12](https://github.com/sevki/workers-swift/pull/12):

- `CASProtocol` defines Codable CAS identity/object types and a shared distributed `CASService` actor.
- `CASWorkerWasm` hosts the actor and routes `/__rpc` to PR #12's `RPCGateway`.
- `casctl <worker-url> status` calls the Worker natively through `WorkersActorSystem`.

The status call is an end-to-end control-plane check. CAS persistence and object operations are not implemented yet; `casctl status` exits with status 2 when the service reports storage is not configured. The Worker currently reports that state deliberately.

## Build

Requires Swift 6.4 for the pinned workers-swift PR revision.

```sh
swift test
swift build --product casctl
swift package worker-build --product CASWorkerWasm
```

For local Worker development, install the matching Swift WebAssembly SDK, run the worker build, then use `wrangler dev` with `wrangler.jsonc`:

```sh
swift package --allow-writing-to-package-directory worker-build --product CASWorkerWasm
npx wrangler dev
casctl http://127.0.0.1:8787 status
```

## Design

See [docs/design.md](docs/design.md) for the storage architecture, llbuild2 identity requirements, large-object transfer path, and implementation milestones.
