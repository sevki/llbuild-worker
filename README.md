# llbuild-worker

A remote content-addressable store on Cloudflare Workers, written in Swift with [workers-swift](https://github.com/sevki/workers-swift). Its first client is **swiftc's compilation caching**: a CAS plugin that lets separate machines share compile results through the Worker.

Everything in the service is a distributed actor:

- **`CASService`** is the stateless front-end. Native clients (`castool`, the swiftc plugin) resolve it through `WorkersActorSystem`; it is hosted by a gateway Durable Object, one per WebSocket connection.
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

**Large objects.** Module artifacts are megabytes, so objects over 512 KiB are sent as 256 KiB chunk objects plus a manifest object, all ordinary CAS objects, and then registered; the Worker reassembles the object and recomputes its identity before accepting it. Objects up to 64 MiB are shared; anything larger stays in the local cache. Chunk bodies live in Durable Object SQLite for now, with R2 the intended home for them (workers-swift does not wrap R2 yet).

**Build the plugin in release for real use.** The debug build hashes tens of megabytes of module data unoptimized: a compile that takes about 0.3 s with `swift build -c release --product CASPlugin` takes about 10 s with the debug build.

## Xcode and SwiftPM (Swift Build)

Xcode's build engine, Swift Build, loads a CAS plugin from `COMPILATION_CACHE_PLUGIN_PATH` and gives it the value of `COMPILATION_CACHE_REMOTE_SERVICE_PATH` as the option `remote-service-path`. That setting is typed as a *path*, so point it at a small file containing the Worker's URL (or, with the same option, give the URL itself):

```sh
echo https://your-worker.example.workers.dev > ~/.config/llbuild-cas-remote
swift build -c release --product CASPlugin   # libCASPlugin.dylib on macOS, .so on Linux
```

```
COMPILATION_CACHE_ENABLE_CACHING = YES
SWIFT_ENABLE_EXPLICIT_MODULES = YES
SWIFT_USE_INTEGRATED_DRIVER = YES
COMPILATION_CACHE_ENABLE_PLUGIN = YES
COMPILATION_CACHE_PLUGIN_PATH = /path/to/libCASPlugin.dylib
COMPILATION_CACHE_REMOTE_SERVICE_PATH = /Users/you/.config/llbuild-cas-remote
```

The plugin also reads `LLBUILD_CAS_REMOTE_URL`, and `remote-url` still works for `swiftc -cas-plugin-option`.

**What was verified, and what was not.** `Scripts/test-with-swift-build.sh` runs Swift Build itself on Linux (its own tests are macOS-only, so this uses a test written for the purpose): one build populates the Worker, and a second build with a different empty local CAS gets `Cache hit` from it. That is the same build engine Xcode uses, with the same SwiftScan-driven lookups and async plugin calls, and it is what found and fixed a thread-pool starvation bug that `swiftc` alone could not show. It has **not** been run in Xcode on macOS. The likeliest problem there is code signing: Apple-signed Xcode processes may refuse to load an unsigned plugin, so sign it and expect to check that first. If macOS blocks a third-party plugin, the alternative is a local gRPC service on a Unix socket, which is the interface Apple's own plugin uses for remote caches.

## `castool`

```sh
castool <worker-url> status              # exit 2 if the service has no storage
castool <worker-url> put <file>          # prints the object's digest
castool <worker-url> get <digest> <out>
castool <worker-url> has <digest>        # exit 0 if present, 1 if not
```

## Build and test

Requires Swift 6.4 and, for the Worker, the matching Swift WebAssembly SDK.

```sh
swift test
Scripts/test-compilation-cache.sh   # swiftc miss/hit/replay through the plugin, local only

swift package --allow-writing-to-package-directory worker-build --product CASWorkerWasm
npm ci
Scripts/test-remote-cache.sh        # Worker in workerd + castool + two developers sharing a cache
Scripts/test-with-swift-build.sh    # optional, slow: Xcode's build engine against the plugin
```

`node Scripts/serve-worker.mjs` serves the built Worker in a local workerd and prints its URL.

## Design

See [docs/design.md](docs/design.md) for the storage architecture and [docs/pr12-spike.md](docs/pr12-spike.md) for the workers-swift transport notes.
