#!/usr/bin/env bash
# Makes the rest of a CI job compile through the live cache this repo builds
# (https://xcache.devtoo.ls), so CI is its own first user.
#
# Downloads the latest *released* CASPlugin - the artifact users install, not a
# build of this checkout - and exports, for later steps, SWIFT_CACHE_FLAGS (the
# Swift compiles) and, where the clang supports it, CCC_OVERRIDE_OPTIONS (the C
# compiles, which every `clang` the build runs picks up by itself). Use
# SWIFT_CACHE_FLAGS like:
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
echo "Compiling Swift through $remote with $dir/$lib"

# The C targets (swift-nio's shims, BoringSSL, ...) are compiled by clang
# itself, which takes the same plugin through its own -fcas-* options. They
# can't ride along in SWIFT_CACHE_FLAGS: SwiftPM only has -Xcc for them, and
# -Xcc also reaches swiftc's clang importer, which rejects -fdepscan ("clang
# importer creation failed"). CCC_OVERRIDE_OPTIONS edits the command line of
# every `clang` executable the build runs and never reaches the importer,
# which uses clang as a library. Each `+word` appends one argument.
#
# Not every clang takes these options (an unknown one fails the build), so
# compile a one-line file with them first and only export them if that clang
# answers with a compile-job-cache remark, proving the options were applied
# and understood. This is the same check on Linux and macOS.
clang_options=(
    +-fdepscan
    +-Rcompile-job-cache
    +-Xclang +-fcache-compile-job
    +-Xclang +-fcas-path +-Xclang "+$RUNNER_TEMP/cas-c"
    +-Xclang +-fcas-plugin-path +-Xclang "+$dir/$lib"
    +-Xclang +-fcas-plugin-option +-Xclang "+remote-url=$remote"
)

# The plugin links the Swift runtime (libswiftDistributed.so, ...). swift-frontend
# finds it through its own search path, but a bare `clang` does not, so on Linux
# it needs the toolchain's runtime directory on LD_LIBRARY_PATH (macOS resolves
# it from the system). It is the directory the build already runs against.
library_path="${LD_LIBRARY_PATH:-}"
if [ "$(uname -s)" = Linux ]; then
    swift_bin="$(dirname "$(readlink -f "$(command -v swift)")")"
    if [ -d "$swift_bin/../lib/swift/linux" ]; then
        library_path="$(cd "$swift_bin/../lib/swift/linux" && pwd)${library_path:+:$library_path}"
    fi
fi

probe="$RUNNER_TEMP/clang-probe"
mkdir -p "$probe"
printf 'int probe(void) { return 0; }\n' > "$probe/probe.c"
if output="$(LD_LIBRARY_PATH="$library_path" CCC_OVERRIDE_OPTIONS="${clang_options[*]}" \
        clang -c "$probe/probe.c" -o "$probe/probe.o" 2>&1)" \
        && grep -q "compile job cache" <<<"$output"; then
    {
        echo "CCC_OVERRIDE_OPTIONS=${clang_options[*]}"
        [ -z "$library_path" ] || echo "LD_LIBRARY_PATH=$library_path"
    } >> "$GITHUB_ENV"
    echo "Compiling C through the same cache"
else
    echo "::notice::This clang did not take the compile-cache options, so C compiles run without the cache: ${output:-no output}"
fi
