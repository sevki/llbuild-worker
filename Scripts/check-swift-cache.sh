#!/usr/bin/env bash
# Shows whether a Swift compile's result really travels through the Worker.
# Compiles one tiny file with swiftc twice against the live cache, the plugin's
# debug log on: the first compile publishes, the second starts with an empty
# local cache and should hit from the Worker. When a build of many files logs
# only misses, this says why (a publish that failed, a lookup that missed, the
# plugin disabling its remote), which the build's own output never does
# because a failing remote is deliberately silent.
#
# Needs CAS_PLUGIN_PATH, CAS_REMOTE_URL and LLBUILD_CAS_TOKEN (set by
# Scripts/ci-compile-cache.sh and the workflow). Only warns.
set -uo pipefail

: "${CAS_PLUGIN_PATH:?run Scripts/ci-compile-cache.sh first}"
: "${CAS_REMOTE_URL:?run Scripts/ci-compile-cache.sh first}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"
# The source is fixed on purpose: later runs on the same paths can hit it too.
printf 'public func triple(_ x: Int) -> Int { x * 3 }\n' > a.swift

compile() { # <cas dir> <output>
    LLBUILD_CAS_DEBUG=1 swiftc -c a.swift -module-name CheckSwiftCache -o "$2" \
        -explicit-module-build -cache-compile-job -Rcache-compile-job \
        -cas-path "$1" -cas-plugin-path "$CAS_PLUGIN_PATH" \
        -cas-plugin-option "remote-url=$CAS_REMOTE_URL" 2>&1
}

show() { grep -E "remote|shared action|kept action|fetched|hit remotely|cannot upload|not uploading|error|cache (hit|miss)" | cut -c1-220 | head -n "$1"; }

echo "--- first compile (publishes):"
first="$(compile "$work/cas1" a1.o)"; show 12 <<<"$first"
echo "--- second compile (empty local cache; should hit from the Worker):"
second="$(compile "$work/cas2" a2.o)"; show 12 <<<"$second"

if grep -q "hit remotely" <<<"$second" || grep -q "cache hit" <<<"$second"; then
    echo "The Swift result came back from the Worker."
else
    echo "::warning::A Swift compile with an empty local cache did not hit from the Worker"
fi
if grep -q "remote disabled" <<<"$first$second"; then
    echo "::warning::The plugin disabled its remote: $(grep -h 'remote disabled' <<<"$first$second" | head -n 1 | cut -c1-200)"
fi
