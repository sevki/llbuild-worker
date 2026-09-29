#!/usr/bin/env bash
# End-to-end test of the distributed CAS: builds the Worker, serves it in a
# local workerd, and checks
#   1. castool reaches the CASService actor and stores/fetches objects through
#      the shard actors, including at the control-plane size limit;
#   2. two developers with separate empty local caches share compile results:
#      the first misses and publishes, the second hits from the Worker alone;
#   3. an unreachable Worker never breaks a build.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

[ -f build/worker/worker.mjs ] || swift package --allow-writing-to-package-directory \
    worker-build --product CASWorkerWasm --configuration release
[ -d node_modules/workerd ] || npm ci --no-audit --no-fund
# SwiftPM honors only the last --product flag, so build each on its own.
swift build --product CASPlugin
swift build --product castool
bin="$(swift build --show-bin-path)"
plugin="$bin/libCASPlugin.so"
castool="$bin/castool"

work="$(mktemp -d)"
server_pid=""
cleanup() {
    [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

DEBUG_WORKERD=1 node Scripts/serve-worker.mjs > "$work/serve.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 120); do
    grep -q '^READY ' "$work/serve.log" && break
    kill -0 "$server_pid" 2>/dev/null || { cat "$work/serve.log" >&2; fail "Worker exited"; }
    sleep 1
done
url="$(sed -n 's/^READY //p' "$work/serve.log")"
[ -n "$url" ] || { cat "$work/serve.log" >&2; fail "Worker did not start"; }
echo "Worker at $url"

# 1. The service and its shard actors.
"$castool" "$url" status | grep -q '"storageConfigured" : true' || fail "storage not configured"
echo "ok: CASService reports storage configured"

for size in 1000 200000 524288 524289 3000000; do
    head -c "$size" /dev/urandom > "$work/blob-$size"
    digest="$("$castool" "$url" put "$work/blob-$size")"
    "$castool" "$url" has "$digest" || fail "has $size-byte object"
    "$castool" "$url" get "$digest" "$work/out-$size"
    cmp "$work/blob-$size" "$work/out-$size" || fail "$size-byte round trip differs"
    echo "ok: $size-byte object round-trips through the shard actors"
done
echo "ok: objects over 512 KiB go up as chunks and come back verified"

# Bodies of 32 KiB and up live in R2; the 1000-byte object and manifests stay
# in the shard's SQLite. The stand-in bucket logs each put it receives.
grep -q '^R2PUT obj/[0-9a-f]* 262144$' "$work/serve.log" || fail "chunk bodies did not reach R2"
if grep -q '^R2PUT obj/[0-9a-f]* 1000$' "$work/serve.log"; then fail "a small object went to R2"; fi
echo "ok: chunk bodies are stored in R2, small objects stay in SQLite"

# The largest logical object is 64 MiB; the client refuses more before uploading.
head -c 67108865 /dev/urandom > "$work/too-big"
if "$castool" "$url" put "$work/too-big" 2> "$work/too-big.err"; then
    fail "object over the limit was accepted"
fi
grep -q "exceeds" "$work/too-big.err" || fail "over-limit error not reported: $(cat "$work/too-big.err")"
rm "$work/too-big"
echo "ok: object over the maximum size is rejected"

if "$castool" "$url" has "$(printf '%064d' 0)"; then fail "missing object reported present"; fi
echo "ok: missing object is not found"

# The async entry points, called the way Swift Build calls them: from many
# Swift-concurrency tasks at once. A blocking implementation starves the pool.
LLBUILD_CAS_TEST_URL="$url" swift test --filter RemoteIntegrationTests \
    || fail "concurrent async loads from the cooperative pool"
echo "ok: many concurrent async loads complete (no thread-pool starvation)"

# 2. Two developers, one Worker.
mkdir "$work/src"
cd "$work/src"
printf 'public func mul(_ a: Int, _ b: Int) -> Int { a * b }\n' > a.swift

# Xcode passes the plugin `remote-service-path`, from the
# COMPILATION_CACHE_REMOTE_SERVICE_PATH build setting, which is a path; so
# developer B configures the Worker the way Xcode would, with a config file.
printf '%s\n' "$url" > "$work/remote.cfg"

compile() { # <cas dir> <output> <plugin option>
    LLBUILD_CAS_DEBUG=1 swiftc -c a.swift -module-name M -o "$2" \
        -explicit-module-build -cache-compile-job \
        -cas-path "$1" -cas-plugin-path "$plugin" \
        -cas-plugin-option "$3" -Rcache-compile-job 2>&1
}

first="$(compile "$work/casA" a.o "remote-url=$url")"
grep -q "cache miss" <<<"$first" || fail "developer A should miss: $first"
grep -q "shared action" <<<"$first" || fail "developer A should publish: $first"
# Module artifacts are megabytes; none of the results may be kept local.
if grep -q "kept action" <<<"$first"; then fail "developer A kept a result local: $first"; fi
echo "ok: developer A misses and publishes to the Worker"

second="$(compile "$work/casB" b.o "remote-service-path=$work/remote.cfg")"
grep -q "cache hit" <<<"$second" || fail "developer B should hit from the Worker: $second"
grep -q "fetched" <<<"$second" || fail "developer B should fetch from the Worker: $second"
if grep -q "cache miss" <<<"$second"; then fail "developer B rebuilt something: $second"; fi
cmp a.o b.o || fail "replayed object differs"
echo "ok: developer B (Xcode-style remote-service-path), with an empty local cache, hits from the Worker"

# 3. A dead Worker must never fail a build.
kill "$server_pid"; wait "$server_pid" 2>/dev/null || true; server_pid=""
third="$(compile "$work/casC" c.o "remote-url=$url")" || fail "compile failed with the Worker down: $third"
grep -q "cache miss" <<<"$third" || fail "expected a plain miss with the Worker down: $third"
[ -s c.o ] || fail "no object produced with the Worker down"
echo "ok: an unreachable Worker does not break the build"
echo "distributed CAS end to end: OK"
