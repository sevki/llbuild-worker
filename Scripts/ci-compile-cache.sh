#!/usr/bin/env bash
# Makes the rest of a CI job compile Swift through the live cache this repo
# builds (https://xcache.devtoo.ls), so CI is its own first user.
#
# Downloads the latest *released* CASPlugin - the artifact users install, not a
# build of this checkout - and exports SWIFT_CACHE_FLAGS for later steps:
#
#   swift test ${SWIFT_CACHE_FLAGS:+--build-system native $SWIFT_CACHE_FLAGS}
#   swift package worker-build ... -- ${SWIFT_CACHE_FLAGS:+--build-system native $SWIFT_CACHE_FLAGS}
#
# (`--build-system native` is the backend the flags were verified with.) The
# job must have the Worker's access token in LLBUILD_CAS_TOKEN.
#
# Best effort, like the plugin itself: with no token (a pull request from a
# fork gets no secrets), an unsupported runner, or no release to download, it
# leaves SWIFT_CACHE_FLAGS unset and the job builds without the cache.
#
# Cache keys include absolute paths, so results are only shared between builds
# that run from the same directory; a job's workspace path is stable.
set -euo pipefail

: "${GITHUB_ENV:?run this from a GitHub Actions step}"
: "${RUNNER_TEMP:?run this from a GitHub Actions step}"
remote="${LLBUILD_CAS_REMOTE_URL:-https://xcache.devtoo.ls}"

if [ -z "${LLBUILD_CAS_TOKEN:-}" ]; then
    echo "::notice::No XCACHE_TOKEN (a pull request from a fork?): building without the compile cache"
    exit 0
fi

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) asset=CASPlugin-linux-x86_64; lib=libCASPlugin.so ;;
    Darwin-arm64) asset=CASPlugin-macos-arm64; lib=libCASPlugin.dylib ;;
    *)
        echo "::notice::No released CASPlugin for $(uname -s) $(uname -m): building without the compile cache"
        exit 0
        ;;
esac

dir="$RUNNER_TEMP/cas-plugin"
mkdir -p "$dir"
if ! curl -fsSL "https://github.com/${GITHUB_REPOSITORY:-sevki/llbuild-worker}/releases/latest/download/$asset.tar.gz" \
        | tar -xz -C "$dir" || [ ! -f "$dir/$lib" ]; then
    echo "::warning::Could not download $asset from the latest release: building without the compile cache"
    exit 0
fi

# -explicit-module-build is what makes compile jobs cacheable; -Rcache-compile-job
# leaves a hit or miss line per compile in the log.
flags=(
    -Xswiftc -cache-compile-job
    -Xswiftc -explicit-module-build
    -Xswiftc -cas-path -Xswiftc "$RUNNER_TEMP/cas"
    -Xswiftc -cas-plugin-path -Xswiftc "$dir/$lib"
    -Xswiftc -cas-plugin-option -Xswiftc "remote-url=$remote"
    -Xswiftc -Rcache-compile-job
)
echo "SWIFT_CACHE_FLAGS=${flags[*]}" >> "$GITHUB_ENV"
echo "Compiling through $remote with $dir/$lib"
