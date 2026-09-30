# The cache daemon

A process on the developer's machine (or CI runner) that sits between the compiler
processes and the Worker, so that a build pays for the network once, not once per
process and per object.

## Why

Measured against the live Worker (issue #6, `Scripts/bench-build.sh`):

- Every `swift-frontend` the compiler starts loads the plugin, which opens its own
  connection: about 1 s for a WebSocket upgrade, about 0.14 s for a POST (TLS included).
- A cached compile result is a tree of objects, fetched one round trip at a time.
- Stores are uploaded in the compiler's critical path.

## Shape

```
swift-frontend ──(unchanged plugin, loopback)──▶ casd ──(one warm HTTP/2 connection)──▶ Worker
```

**The plugin is oblivious.** It talks to `casd` through the same address and protocol it
uses for the Worker today (`remote-url` / `remote-service-path` /
`LLBUILD_CAS_REMOTE_URL`, which can be a URL or a config file), so nothing in the plugin
changes and the daemon is optional. It serves what the plugin uses:

- WebSocket `/{scope}/__rpc`: `status`, `contains`, `actionGet`, `actionPut`;
- HTTP `GET` / `PUT /{scope}/objects/{digest}` (`PUT` with the Bearer token and `X-Cas-Refs`).

Loopback TCP, because that is the only address the plugin's client can reach. The token
is the one the plugin already holds: the daemon checks it and uses its own for the
upstream, so there is no second secret.

## What it does

1. **One upstream connection.** Calls go to `POST /{scope}/__rpc` and objects to the HTTP
   object routes over one persistent connection: no per-process handshake, no Durable
   Object per connection, nothing that hibernates.
2. **Local object cache.** `ObjectCache`: content-addressed (an entry is never stale),
   on disk, byte-limited, LRU. A second process on the same machine, or the same process
   later, gets an object in a millisecond.
3. **Closure prefetch.** On `actionGet` the daemon asks the Worker for the action's whole
   result (value and every object reachable from it) in one request, puts the objects in
   its cache, and answers the plugin's next gets locally. A remote hit then costs about two
   round trips however deep the tree is.
4. **Write-behind stores.** `PUT` and `actionPut` are accepted into the local cache at
   once and uploaded in the background. The one rule is the Worker's: an action is
   registered only after every object it refers to is there, so the daemon forwards an
   `actionPut` only once its closure has been uploaded.
5. **Action cache.** Keys map to values and can change, so a positive entry is kept for a
   bounded time and a miss is not cached.

## Traces: asking for the build before the compiler does

A build is a long series of dependent steps, each waiting on its own lookup and then on
its own downloads, so a remote cache's cost is round trips one after another, not bytes.
The daemon removes the waiting by remembering the build.

- **Recording.** The action keys looked up by one build, in the order they were first
  asked, form its trace. A build is a run of lookups with no pause longer than the
  session gap (five minutes by default, to outlast long compiles and linking). The trace
  is kept under its first key, uploaded a short time after the last new lookup and when
  the daemon stops, and replaced by the next build that starts the same way.
- **Using it.** When a build starts, the daemon asks the Worker for the trace kept under
  its first key. If there is one, every key in it is looked up at once (256 per call, a
  few calls in flight) and the objects behind each hit are fetched, in build order and
  with bounded concurrency. By the time the compiler asks, the answer is in memory and
  the objects are on disk or on their way. A key that misses is remembered as a miss.
- **Why on the Worker.** The machine that benefits most is a new one with nothing
  cached, so a trace only on the daemon's own disk would never be there when it is
  needed. `traceGet`/`tracePut` on the service keep it, as a small mutable record per
  first key (the newest 32 per shard), because action keys are immutable and a trace is
  a hint about the latest build, not a fact about content.
- **Cost of a wrong trace.** A stale or different project's trace costs lookups and
  downloads that are not needed, nothing else: the lookups are batched and the fetches
  bounded. A Worker without the calls makes the daemon carry on without traces.
- **Stats.** Prefetched lookups count as hits and misses in the Worker's stats, as any
  lookup does.

## Failure

The plugin treats a failing remote as a miss and must not break a build. The daemon keeps
that: if the Worker is unreachable it answers from its cache or reports a miss, never an
error that stops a compile. If the daemon itself is not there, the plugin's own
connection failure does the same. Nothing is lost by a daemon crash: write-behind uploads
are retried from its on-disk queue the next time it runs, and a result that never reached
the Worker is only a later miss.

## Not in this design

The plugin choosing a transport, a unix-socket address, or Xcode's gRPC remote-cache
protocol (`COMPILATION_CACHE_REMOTE_SERVICE_PATH`). The last is a separate front end on
the same core if it is wanted.
