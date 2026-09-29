#!/usr/bin/env bash
# Runs Swift Build, the build engine behind Xcode, against CASPlugin and a
# local Worker: one "machine" builds and publishes, a second one with an empty
# local CAS gets a cache hit from the Worker. This is the closest check to
# Xcode that runs without a Mac. It compiles Swift Build's whole test suite,
# so the first run takes a long time (tens of minutes) and is not part of CI.
#
#   SWIFT_BUILD_CHECKOUT  where to keep the Swift Build checkout
#                         (default: .build/swift-build-checkout)
set -euo pipefail

SWIFT_BUILD_REVISION=96738a4ea719569905422fab7ef65c6d1aa68bee

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
checkout="${SWIFT_BUILD_CHECKOUT:-$root/.build/swift-build-checkout}"

if [ ! -d "$checkout/.git" ]; then
    git clone --filter=blob:none https://github.com/swiftlang/swift-build "$checkout"
fi
git -C "$checkout" fetch --depth 1 origin "$SWIFT_BUILD_REVISION"
git -C "$checkout" checkout --quiet "$SWIFT_BUILD_REVISION"
cp Tests/SwiftBuildIntegration/LlbuildWorkerCASPluginTests.swift \
    "$checkout/Tests/SWBBuildSystemTests/"

[ -f build/worker/worker.mjs ] || swift package --allow-writing-to-package-directory \
    worker-build --product CASWorkerWasm --configuration release
[ -d node_modules/workerd ] || npm ci --no-audit --no-fund
swift build --product CASPlugin
plugin="$(swift build --show-bin-path)/libCASPlugin.so"

work="$(mktemp -d)"
server_pid=""
cleanup() {
    [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

node Scripts/serve-worker.mjs > "$work/serve.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 120); do
    grep -q '^READY ' "$work/serve.log" && break
    kill -0 "$server_pid" 2>/dev/null || { cat "$work/serve.log" >&2; exit 1; }
    sleep 1
done
sed -n 's/^READY //p' "$work/serve.log" > "$work/remote.cfg"
[ -s "$work/remote.cfg" ] || { echo "Worker did not start" >&2; exit 1; }

cd "$checkout"
LLBUILD_CAS_PLUGIN="$plugin" LLBUILD_CAS_REMOTE="$work/remote.cfg" LLBUILD_CAS_DEBUG=1 \
    swift test --filter LlbuildWorkerCASPluginTests
