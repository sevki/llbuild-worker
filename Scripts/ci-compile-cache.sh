#!/usr/bin/env bash
# Makes the rest of a CI job compile through the live cache this repo builds
# (https://xcache.devtoo.ls), so CI is its own first user.
#
# Downloads the latest *released* CASPlugin - the artifact users install, not a
# build of this checkout - and exports SWIFT_CACHE_FLAGS for later steps (the
# Swift compiles; C compiles are an experiment, see the end of this file). Use
# it like:
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
# OFF unless LLBUILD_CAS_CACHE_C=1. Because the override applies to every clang
# the build runs, each kind of invocation is a way to break it, and CI found
# two the probe below did not: on Linux `-fdepscan` fails to spawn for BoringSSL's
# assembly (.S) files ("clang: error: unable to execute command: posix_spawn
# failed"), and on macOS module builds fail (see the probe). A targeted
# mechanism that only touches C compile jobs is needed before this is a default.
if [ "${LLBUILD_CAS_CACHE_C:-}" != 1 ]; then
    echo "C compiles run without the cache (LLBUILD_CAS_CACHE_C=1 tries it)"
    exit 0
fi

# Not every clang takes these options (an unknown one fails the build), so
# compile a one-line file with them first and only export them if that clang
# answers with a compile-job-cache remark, proving the options were applied
# and understood. This is the same check on Linux and macOS.
clang_options=(
    +-fno-modules
    +-fdepscan
    +-Rcompile-job-cache
    +-Xclang +-fcache-compile-job
    +-Xclang +-fcas-path +-Xclang "+$RUNNER_TEMP/cas-c"
    +-Xclang +-fcas-plugin-path +-Xclang "+$dir/$lib"
    +-Xclang +-fcas-plugin-option +-Xclang "+remote-url=$remote"
)
# A leading `#` keeps clang from echoing the edit list to stderr on every
# invocation (it would, and SwiftPM turns that into a warning per package).
override="#${clang_options[*]}"

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

# SwiftPM compiles C targets with -fmodules, and clang's compile cache cannot
# do that: a file that includes <stdbool.h> makes clang build the
# _Builtin_stdbool module, which aborts clang on Linux ("unexpected call to
# lookupModuleOutput") and fails Apple's ("caching backend error: cached output
# file has unknown path ...ModuleCache/..._Builtin_stdbool.pcm"), while a plain
# file with no includes compiles through the cache fine. So the override starts
# with -fno-modules, which comes after SwiftPM's -fmodules and wins; the C
# targets here are plain C, and the object file does not depend on modules. The
# probe passes -fmodules itself to check that this really overrides it.
probe="$RUNNER_TEMP/clang-probe"
mkdir -p "$probe"
printf '#include <stdbool.h>\nbool probe(void) { return true; }\n' > "$probe/probe.c"
if output="$(LD_LIBRARY_PATH="$library_path" CCC_OVERRIDE_OPTIONS="$override" \
        clang -c "$probe/probe.c" -o "$probe/probe.o" \
        -fmodules -fmodules-cache-path="$probe/modules" 2>&1)" \
        && grep -q "compile job cache" <<<"$output"; then
    {
        echo "CCC_OVERRIDE_OPTIONS=$override"
        [ -z "$library_path" ] || echo "LD_LIBRARY_PATH=$library_path"
    } >> "$GITHUB_ENV"
    echo "Compiling C through the same cache"
else
    # First line only: a clang that aborts prints a whole backtrace.
    echo "::notice::This clang did not take the compile-cache options, so C compiles run without the cache: $(head -n 1 <<<"${output:-no output}")"
fi
