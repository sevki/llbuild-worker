#!/usr/bin/env bash
# Times one build of a Swift package in the cache states that matter, against a live
# Worker, the way CI sets the cache up (Scripts/ci-compile-cache.sh: Swift through
# SWIFT_CACHE_FLAGS, C through the clang wrapper), and shows what the Worker saw for
# each (hits, misses, connections, requests) from the scope's own counters.
#
#   nocache  no compile cache at all: the baseline
#   cold     empty local cache, empty scope: every result is a miss and is published
#   remote   empty local cache, the scope now full: every hit comes from the Worker.
#            This is a new machine or a clean CI runner, what a remote cache is for
#   warm     the local cache of the last run kept: a rebuild on one machine
#
# Every mode deletes the package's build products first and builds from the same
# directory (cache keys include paths). The scope is fresh per session, so earlier runs
# cannot answer this one. `-Rcache-compile-job` is not used: the remark slows the
# compiler several times over (issue #6) and would measure itself.
#
# CASD_ARGS passes more flags to it (--transport post|websocket).
# With CASD=/path/to/casd the plugin talks to a local cache daemon (started fresh for each
# mode, its cache wiped for cold and remote) instead of the Worker, and the time the daemon
# then needs to finish its uploads is shown as "drain": the build does not wait for it, but
# the scope is not complete until it is done.
#
#   PROJECT=/path/to/package TARGET=CASPlugin \
#   LLBUILD_CAS_PLUGIN=.../libCASPlugin.so LLBUILD_CAS_TOKEN=... \
#     Scripts/bench-build.sh [nocache] [cold] [remote] [warm]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
project="${PROJECT:-$root}"
product="${PRODUCT:-}"
target="${TARGET:-CASPlugin}"
select=(--product "${product:-$target}"); [ -n "$product" ] || select=(--target "$target")
host="${CAS_REMOTE_URL:-https://xcache.devtoo.ls}"
: "${LLBUILD_CAS_PLUGIN:?set LLBUILD_CAS_PLUGIN to the plugin to measure}"
: "${LLBUILD_CAS_TOKEN:?set LLBUILD_CAS_TOKEN}"
scope="${BENCH_SCOPE:-bench-$(date +%s)-$RANDOM}"
upstream="${host%/}/$scope"
remote="$upstream"
casd="${CASD:-}"
casd_pid=""
if [ -n "$casd" ]; then
    port="${CASD_PORT:-$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}"
    remote="http://127.0.0.1:$port/$scope"
fi
modes=("$@"); [ "${#modes[@]}" -gt 0 ] || modes=(nocache cold remote warm)

export RUNNER_TEMP="${BENCH_TEMP:-/tmp/bench-rt-$scope}"
export GITHUB_ENV="$RUNNER_TEMP/env"
mkdir -p "$RUNNER_TEMP"; : > "$GITHUB_ENV"
LLBUILD_CAS_REMOTE_URL="$remote" "$root/Scripts/ci-compile-cache.sh" > "$RUNNER_TEMP/setup.log" 2>&1 \
    || { cat "$RUNNER_TEMP/setup.log" >&2; exit 1; }
swift_flags=($(sed -n 's/^SWIFT_CACHE_FLAGS=//p' "$GITHUB_ENV" | sed 's/ -Xswiftc -Rcache-compile-job//'))
cc="$(sed -n 's/^CC=//p' "$GITHUB_ENV")"
[ "${#swift_flags[@]}" -gt 0 ] || { echo "no cache flags were set up: $(cat "$RUNNER_TEMP/setup.log")" >&2; exit 1; }
extra=(${BENCH_FLAGS:-})

start_casd() {
    [ -n "$casd" ] || return 0
    "$casd" --upstream "${host%/}" --listen "127.0.0.1:$port" --cache "$RUNNER_TEMP/casd" ${CASD_ARGS:-} \
        > "$RUNNER_TEMP/casd.log" 2>&1 &
    casd_pid=$!
    for _ in $(seq 1 50); do grep -q listening "$RUNNER_TEMP/casd.log" 2>/dev/null && return 0; sleep 0.1; done
    echo "casd did not start: $(cat "$RUNNER_TEMP/casd.log")" >&2; exit 1
}
stop_casd() {
    [ -n "$casd_pid" ] || return 0
    kill -TERM "$casd_pid" 2>/dev/null || true
    wait "$casd_pid" 2>/dev/null || true
    casd_pid=""
}
trap stop_casd EXIT

# hits misses connections actionsPut objectsGot objectsPut (all days) from the scope's stats.
stats() {
    curl -fsS -m 30 "$upstream/stats.json" 2>/dev/null | python3 -c '
import json, sys
try: d = json.load(sys.stdin)["days"]
except Exception: d = []
k = ["hits", "misses", "connections", "actionsPut", "objectsGot", "objectsPut"]
print(*[sum(day.get(x, 0) for day in d) for x in k])'
}

echo "project $project, ${select[*]}, scope $scope, C through ${cc:-no wrapper}"
printf '%-8s %8s %8s %8s %8s %8s %8s %8s %8s\n' mode "wall s" "drain s" hits misses conns actions gets puts
for mode in "${modes[@]}"; do
    rm -rf "$project/.build/x86_64-unknown-linux-gnu"
    flags=(); env_cc=()
    case "$mode" in
        nocache) ;;
        cold|remote) rm -rf "$RUNNER_TEMP/cas" "$RUNNER_TEMP/cas-c" "$RUNNER_TEMP/casd"; flags=("${swift_flags[@]}"); [ -z "$cc" ] || env_cc=(CC="$cc") ;;
        warm)        flags=("${swift_flags[@]}"); [ -z "$cc" ] || env_cc=(CC="$cc") ;;
        *) echo "unknown mode $mode" >&2; exit 2 ;;
    esac
    before=($(stats))
    start_casd
    start=$(date +%s.%N)
    ( cd "$project" && env ${env_cc[@]+"${env_cc[@]}"} swift build --build-system native "${select[@]}" ${flags[@]+"${flags[@]}"} ${extra[@]+"${extra[@]}"} ) \
        > "$RUNNER_TEMP/$mode.log" 2>&1 || { echo "$mode: build failed, see $RUNNER_TEMP/$mode.log" >&2; tail -5 "$RUNNER_TEMP/$mode.log" >&2; exit 1; }
    end=$(date +%s.%N)
    stop_casd
    drained=$(date +%s.%N)
    after=($(stats))
    printf '%-8s %8.1f %8.1f' "$mode" "$(echo "$end - $start" | bc)" "$(echo "$drained - $end" | bc)"
    for i in 0 1 2 3 4 5; do printf ' %8d' "$((${after[$i]:-0} - ${before[$i]:-0}))"; done
    echo
done
