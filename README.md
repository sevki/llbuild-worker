# llbuild-worker

A remote content-addressable store on Cloudflare Workers, written in Swift with [WorkerKit](https://github.com/sevki/WorkerKit). Its first client is **swiftc's compilation caching**: a CAS plugin that lets separate machines share compile results through the Worker. This repo's own CI and CASPlugin release builds run through a deployed instance at **xcache.devtoo.ls** (see [Quick start](#quick-start)); its `/stats` page shows live traffic.

Everything in the service is a distributed actor:

- **`CASService`** is the stateless front-end. Native clients (`castool`, the swiftc plugin) resolve it through `WorkersActorSystem`; it is hosted by a gateway Durable Object, one per WebSocket connection. Every call except `/`, `/setup` and `/stats*` requires a bearer/query token matching the Worker's `CAS_TOKEN` secret (see [Access token](#access-token)).
- **`CASShard`** is one actor per Durable Object, holding a slice of the objects and the action cache in that object's SQLite. Bodies of 32 KiB and up (every chunk of a large object) are stored in R2 under `obj/<digest>`; SQLite keeps the references and small bodies. A digest's first hex digit picks one of 16 shards.
- **`CASStatsObject`** is one Durable Object counting daily hits/misses/puts across all shards, behind the public `/stats`, `/stats.json` and `/stats/live` (WebSocket) routes.

```
swiftc ──> CASPlugin (libCASPlugin.so) ──> CASClient ──WebSocket──> CASGateway DO ──> CASService
                                                                                        │
                                                                          CASShard DO x16 (SQLite)
```

## Quick start

Against a deployed instance (this repo's own is xcache.devtoo.ls), install the released `CASPlugin` and wire it up in one step:

```sh
curl --proto '=https' --tlsv1.2 -sSf https://xcache.devtoo.ls/setup | sh
```

This downloads the prebuilt plugin published by `.github/workflows/release.yml` (macOS arm64 or Linux x86_64 only — for anything else, or to build from source, see [Compilation caching](#compilation-caching) below), verifies its checksum, installs it to `~/.cache/llbuild-cas/plugin/`, writes `~/.config/llbuild-cas-remote` for Xcode/Swift Build, and prompts for an access token (see below). It prints the exact `swiftc` flags and Xcode build settings to use afterwards.

### Access token

The Worker refuses every request to `/__rpc` (used by `castool` and the compiler plugin) without a token matching its `CAS_TOKEN` secret; `/`, `/setup` and the `/stats*` routes stay public. Clients (`castool`, `CASPlugin` via `CASClient.authenticated(_:)`) resolve a token in this order: already present in the URL, then the `LLBUILD_CAS_TOKEN` environment variable, then `~/.config/llbuild-cas-remote-token` — the file `/setup` writes if you give it one. Deploying your own instance needs `wrangler secret put CAS_TOKEN`.

## Compilation caching

`CASPlugin` is a dynamic library exporting the LLVM CAS plugin C API (`llcas_*`) that `swift-frontend` loads. `/setup` above installs a release build of it; to build it yourself instead:

```sh
swift build --product CASPlugin

swiftc -c main.swift -explicit-module-build -cache-compile-job \
  -cas-path ~/.cache/llbuild-cas \
  -cas-plugin-path .build/debug/libCASPlugin.so \
  -cas-plugin-option remote-url=https://your-worker.example.workers.dev \
  -Rcache-compile-job
```

- The local store under `-cas-path` is always used first. The Worker is consulted when the compiler asks for a *global* lookup, and results are published to it when a compile finishes.
- Whether the Worker is used is the compiler's call, per request (`globally`). Clang and Swift 6.4's `swiftc` ask for it; **Apple's Swift 6.3 `swiftc` never does** (measured on a macOS CI runner: every one of its 17 lookups and 7 stores in a compile was local-only), so with a Worker configured its Swift results stay local. `-cas-plugin-option remote-scope=all` makes the plugin use the Worker for every request whatever the compiler says. The default is `remote-scope=requested`. Set `LLBUILD_CAS_DEBUG=1` and the plugin logs each lookup and store with the value it was given.
- An action result is uploaded with everything it references, children first, so another machine never sees a cache entry that points at a missing object.
- The Worker is best-effort: if it is slow, down or errors, the plugin turns it off for that process and the build carries on with the local cache. Set `LLBUILD_CAS_DEBUG=1` to see what it decided.
- Without `remote-url` the plugin is a plain local CAS.
- The remote tier authenticates the same way `castool` does; see [Access token](#access-token).
- Object identity is this service's own SHA-256 scheme (`CASIdentity`), and the Worker recomputes it on every store. It is not llbuild2's identity; see [docs/design.md](docs/design.md).

**Large objects.** Module artifacts are megabytes, so objects over 512 KiB are sent as 256 KiB chunk objects plus a manifest object, all ordinary CAS objects, and then registered; the Worker reassembles the object and recomputes its identity before accepting it. Objects up to 64 MiB are shared; anything larger stays in the local cache. Chunk bodies live in R2 (binding `CASBLOBS`, see `wrangler.jsonc`; create the bucket with `wrangler r2 bucket create llbuild-cas-blobs`). Without that binding the Worker still runs and keeps every body in SQLite. Locally, `Scripts/serve-worker.mjs` backs the binding with a small in-memory stand-in (`Scripts/r2-service.mjs`), since raw workerd has no R2 emulator; the deployed instance uses real R2, exercised continuously by this repo's own CI and CASPlugin release builds against xcache.devtoo.ls.

**Build the plugin in release for real use.** The debug build hashes tens of megabytes of module data unoptimized: a compile that takes about 0.3 s with `swift build -c release --product CASPlugin` takes about 10 s with the debug build.

## Xcode and SwiftPM (Swift Build)

Xcode's build engine, Swift Build, loads a CAS plugin from `COMPILATION_CACHE_PLUGIN_PATH` and gives it the value of `COMPILATION_CACHE_REMOTE_SERVICE_PATH` as the option `remote-service-path`. That setting is typed as a *path*, so point it at a small file containing the Worker's URL (or, with the same option, give the URL itself). `/setup` (see [Quick start](#quick-start)) already writes this file to `~/.config/llbuild-cas-remote`; to do it by hand:

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

`castool` resolves an access token the same way the plugin does; see [Access token](#access-token). `Scripts/serve-worker.mjs` prints its local dev token in the URL it prints (`READY http://127.0.0.1:<port>?token=<token>`) — pass that straight as `<worker-url>`.

## Usage statistics

`/stats` is a public dashboard (also `/stats.json`, and `/stats/live` for a WebSocket push feed) showing daily hits, misses, puts and storage totals across all 16 shards, backed by the `CASStatsObject` Durable Object (`CASSTATS` binding). It needs no token and works even on a deployment without R2 configured.

## Releases

`.github/workflows/release.yml` builds `CASPlugin` in release mode for macOS arm64 and Linux x86_64 on tag push (`v*`) or manual dispatch, and publishes `CASPlugin-<platform>.tar.gz` plus a `SHA256SUMS` to a GitHub Release. `/setup` downloads from the *latest* release; `Scripts/ci-compile-cache.sh` does the same to make this repo's own CI compile through xcache.devtoo.ls (see [Build and test](#build-and-test)).

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

`node Scripts/serve-worker.mjs` (or `npm run serve`) serves the built Worker in a local workerd and prints its URL.

CI (`.github/workflows/ci.yml`) runs `swift test`/`swift build`/the Worker build through the live cache at xcache.devtoo.ls rather than uncached: `Scripts/ci-compile-cache.sh` downloads the latest released `CASPlugin` and exports `SWIFT_CACHE_FLAGS`, needing the `XCACHE_TOKEN` secret (best-effort — a fork PR without secrets, or a runner with no released plugin, just builds uncached). `Scripts/check-c-cache.sh` is a diagnostic that confirms C compiles (via a `CC` wrapper `ci-compile-cache.sh` writes) are actually going through the same cache.

## Design

See [docs/design.md](docs/design.md) for the storage architecture and [docs/pr12-spike.md](docs/pr12-spike.md) for the WorkerKit transport notes.
