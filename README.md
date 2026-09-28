# llbuild-worker

A remote content-addressable store on Cloudflare Workers, written in Swift with [workers-swift](https://github.com/sevki/workers-swift). Its first client is **swiftc's compilation caching**: a CAS plugin that lets separate machines share compile results through the Worker.

Everything in the service is a distributed actor:

- **`CASService`** is the stateless front-end. Native clients (`casctl`, the swiftc plugin) resolve it through `WorkersActorSystem`; it is hosted by a gateway Durable Object, one per WebSocket connection.
- **`CASShard`** is one actor per Durable Object, holding a slice of the objects and the action cache in that object's SQLite. A digest's first hex digit picks one of 16 shards.

```
swiftc ──> CASPlugin (libCASPlugin.so) ──> CASClient ──WebSocket──> CASGateway DO ──> CASService
                                                                                        │
                                                                          CASShard DO x16 (SQLite)
```

## Compilation caching

`CASPlugin` is a dynamic library exporting the LLVM CAS plugin C API (`llcas_*`) that `swift-frontend` loads:

```sh
swift build --product CASPlugin

swiftc -c main.swift -explicit-module-build -cache-compile-job \
  -cas-path ~/.cache/llbuild-cas \
  -cas-plugin-path .build/debug/libCASPlugin.so \
  -cas-plugin-option remote-url=https://your-worker.example.workers.dev \
  -Rcache-compile-job
```

- The local store under `-cas-path` is always used first. The Worker is consulted when the compiler asks for a *global* lookup, and results are published to it when a compile finishes.
- An action result is uploaded with everything it references, children first, so another machine never sees a cache entry that points at a missing object.
- The Worker is best-effort: if it is slow, down or errors, the plugin turns it off for that process and the build carries on with the local cache. Set `LLBUILD_CAS_DEBUG=1` to see what it decided.
- Without `remote-url` the plugin is a plain local CAS.
- Object identity is this service's own SHA-256 scheme (`CASIdentity`), and the Worker recomputes it on every store. It is not llbuild2's identity; see [docs/design.md](docs/design.md).

**Limit:** objects over 512 KiB stay in the local cache only. The JSON/WebSocket control plane is not a bulk data channel; the design describes the streaming path that will lift this.

## `casctl`

```sh
casctl <worker-url> status              # exit 2 if the service has no storage
casctl <worker-url> put <file>          # prints the object's digest
casctl <worker-url> get <digest> <out>
casctl <worker-url> has <digest>        # exit 0 if present, 1 if not
```

## Build and test

Requires Swift 6.4 and, for the Worker, the matching Swift WebAssembly SDK.

```sh
swift test
Scripts/test-compilation-cache.sh   # swiftc miss/hit/replay through the plugin, local only

swift package --allow-writing-to-package-directory worker-build --product CASWorkerWasm
npm ci
Scripts/test-remote-cache.sh        # Worker in workerd + casctl + two developers sharing a cache
```

`node Scripts/serve-worker.mjs` serves the built Worker in a local workerd and prints its URL.

## Design

See [docs/design.md](docs/design.md) for the storage architecture and [docs/pr12-spike.md](docs/pr12-spike.md) for the workers-swift transport notes.
