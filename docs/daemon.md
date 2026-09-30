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
