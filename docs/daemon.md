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
swift-frontend ──(unchanged plugin, loopback)──▶ casd ──(one upstream connection)──▶ Worker
```

**The plugin is oblivious.** It talks to `casd` through the same address and protocol it
uses for the Worker today (`remote-url` / `remote-service-path` /
`LLBUILD_CAS_REMOTE_URL`, which can be a URL or a config file), so nothing in the plugin
changes and the daemon is optional. It serves what the plugin uses:

- WebSocket `/{scope}/__rpc`: `status`, `contains`, `actionGet`, `actionPut` (and the
  batched and trace calls below);
- `POST /{scope}/__rpc`, the same calls one request at a time;
- HTTP `GET` / `PUT /{scope}/objects/{digest}` (`PUT` with the Bearer token and `X-Cas-Refs`).

Loopback TCP, because that is the only address the plugin's client can reach, and nothing
else is accepted: `casd` refuses a non-loopback `--listen`. **It does not authenticate its
clients.** Anything on the machine that can reach the port can read and write the cache
through the token the daemon holds upstream (from `LLBUILD_CAS_TOKEN` or
`~/.config/llbuild-cas-remote-token`), so run it only where the local users are trusted.

## What it does

1. **One upstream connection.** Calls go to the Worker over one client, and objects to the
   HTTP object routes: no per-process handshake. The transport is `--transport auto|post|
   websocket`. `auto` probes for `POST /{scope}/__rpc` (a stateless call, so there is no
   connection to go stale) and uses the WebSocket if the Worker does not answer it, and
   looks again after a while. Every call has a deadline and is retried once on a new
   connection, so a connection the Worker stops answering cannot hang a build.
2. **Local object cache.** `ObjectCache`: content-addressed (an entry is never stale),
   on disk, byte-limited, LRU. A second process on the same machine, or the same process
   later, gets an object in a millisecond.
3. **Closure prefetch.** On an `actionGet` hit the daemon starts fetching the action's value
   object in the background and follows the references of what it gets, with bounded
   concurrency (32 fetches at once), puts the objects in its cache, and answers the
   plugin's next gets locally. Lookups that arrive together are batched into one
   `actionGetMany` call. (A single Worker call that returns a whole closure was considered
   and is not built; the trace below removes most of the need.)
4. **Write-behind stores.** `PUT` and `actionPut` are accepted at once and uploaded in the
   background. A stored object waits in a spool the cache's eviction cannot touch until
   it has been sent, and an acknowledged action is written to disk as a pending marker
   before the reply. The one rule is the Worker's: an action is registered only after
   every object it refers to is there, so the daemon forwards an `actionPut` only once
   its closure has been uploaded, children first.
5. **Action cache.** Keys map to values and can change, so a positive entry is kept for a
   bounded time and a miss is not cached.

## Traces: asking for the build before the compiler does

A build is a long series of dependent steps, each waiting on its own lookup and then on
its own downloads, so a remote cache's cost is round trips one after another, not bytes.
The daemon removes the waiting by remembering the build.

- **Recording.** The action keys looked up by one build, in the order they were first
  asked, form its trace. A build is a run of lookups with no pause longer than the
  session gap (five minutes by default, to outlast long compiles and linking). The trace
  is kept under each of its first eight keys (which action a build asks for first varies
  from run to run, because its compile jobs start in parallel), uploaded a short time
  after the last new lookup and when the daemon stops, and replaced by the next build
  that starts the same way.
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
- **A trace fills in over runs.** A build asks for the actions of later steps only once
  earlier ones have succeeded, so a build against an empty scope records fewer lookups
  than one that finds hits. In the measurements below the trace recorded by the first
  build held about 470 actions and the next build, finding hits, recorded about 905: the
  second remote build onwards prefetched nearly everything.

## Running it

`casd` is released with the plugin: `casd-macos-arm64.tar.gz` and `casd-linux-x86_64.tar.gz`
on each GitHub release (with `SHA256SUMS`), or `swift build -c release --product casd`. The
Linux binary has the Swift runtime and Foundation linked in (it is about 110 MB, 37 MB
compressed), so it needs no Swift toolchain; it does need `libcurl.so.4` and the usual system
libraries on the host. **It is built on Ubuntu 24.04 and needs glibc 2.38 or newer** (Ubuntu
24.04, Debian 13, Fedora 39 and later); on an older system, such as Ubuntu 22.04 or Debian 12,
it does not start, and the installer then leaves the plugin talking to the Worker directly.
The plugin's Linux build has the same requirement. Building the release on an older base image
would lower it.

```
casd --upstream https://your-worker.example.workers.dev [--listen 127.0.0.1:4170]
     [--cache ~/.cache/llbuild-casd] [--max-gb 4] [--transport auto|post|websocket]
```

- **Token.** `LLBUILD_CAS_TOKEN`, or the file `~/.config/llbuild-cas-remote-token`. The
  daemon uses it only towards the Worker.
- **Point the compiler at it** by using `http://127.0.0.1:4170/<scope>` where the Worker's
  URL was (`remote-url`, or `LLBUILD_CAS_REMOTE_URL`). One daemon serves any number of
  scopes; each scope has its own cache directory under `--cache`.
- **As a service.** `service/casd.service` (a systemd user unit) and
  `service/llbuild.casd.plist` (a launchd agent) run it at login and restart it after a
  failure. Edit the upstream URL in them. On stop (SIGTERM) the daemon waits up to 30 s for
  queued uploads and then exits; what is still unsent stays on disk and goes out the next
  time it runs. The launchd file has not been tried on a Mac by the author.
- **Diagnostics.** On exit it prints, per scope, what it asked of the Worker: lookups and
  calls, mean times, objects fetched, and the trace counters (probes, found, prefetched
  actions that hit, uploaded). `LLBUILD_CAS_DEBUG` adds per-request logging and slows
  builds noticeably.

## Bounds

The disk and memory it can use are capped, and when a count cannot be known the daemon
refuses new work instead of assuming it is zero: an object cache of `--max-gb` per scope;
a spool for unsent objects (a PUT past its quota is refused with 507); a cap on unsent
actions; at most 32 scopes open and 128 scope directories on disk (the oldest unused are
removed, never one that holds unsent writes). If a directory cannot be listed, for example
after a filesystem error, the scope does not open (503) or stops taking new records until
it can be counted.

## Measured

Building `CASPlugin` (a release plugin) in a fresh scope on the production Worker, from a
Linux sandbox with a proxied network, wall seconds. One machine and a few runs each, so
treat the figures as relative.

| | no cache | cold | remote hits | warm (local cache kept) |
|---|---|---|---|---|
| plugin → Worker directly | 83.7 | 763 | 909 | 126 |
| plugin → `casd` (WebSocket upstream) | 80.0 | 169 | 87-89 | 36 |
| `casd`, POST upstream, trace off | | | 96-105 (mean 100) | |
| `casd`, POST upstream, trace on | | 190 (first build) | 65-67 (mean 66) | |

- **Connections.** About 520 upstream connections per build became 1.
- **Trace.** Three runs each, alternating, same scope: with the trace on, every prefetched
  action hit and the foreground made 438 lookups instead of 906; both fetched the same
  2,497 objects (140 MB). With a fuller trace (later runs) the builds took about 60 s.
  Without a cache the same build compiles in about 80 s, so a remote hit is now faster
  than compiling here, where before the trace it was about on par.
- **Transport.** WebSocket and POST upstream were indistinguishable once the trace was on
  (four comparable runs: 71.2 s for each, best 60.6 and 62.4 s, with about ±20 s of
  run-to-run noise from the network). `auto` therefore prefers POST, which has no
  connection to go stale.
- Not measured: macOS (issue #6's numbers were from a Mac), and any other project.

## Failure

The plugin treats a failing remote as a miss and must not break a build. The daemon keeps
that: if the Worker is unreachable it answers from its cache or reports a miss, never an
error that stops a compile. If the daemon itself is not there, the plugin's own
connection failure does the same. Nothing is lost by a daemon crash: write-behind uploads
are retried from its on-disk queue the next time it runs, and a result that never reached
the Worker is only a later miss.

## Not in this design

The plugin choosing a transport (it still talks WebSocket to whatever it is pointed at),
a unix-socket address, a single Worker call that returns a whole closure, or Xcode's gRPC
remote-cache protocol (`COMPILATION_CACHE_REMOTE_SERVICE_PATH`). The last is a separate
front end on the same core if it is wanted.
