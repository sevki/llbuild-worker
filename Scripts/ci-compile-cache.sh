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
# importer creation failed"). So SwiftPM is pointed, through CC, at a small
# wrapper that adds the cache options to the invocations that can take them
# and runs every other one untouched. (Editing every clang with
# CCC_OVERRIDE_OPTIONS instead cannot tell invocations apart, and broke both
# platforms.) Two things clang's compile cache cannot do, both reproduced:
#
#  - Assembly. `-fdepscan` on a .S file fails ("gcc: error: language
#    response-file not recognized" here, "posix_spawn failed" on the CI runner;
#    BoringSSL has .S files). Assembly, and anything that is not a compile
#    (a link, a preprocess-only run), goes straight to clang.
#  - Modules. SwiftPM passes -fmodules, and a file that includes <stdbool.h>
#    then aborts clang on Linux ("unexpected call to lookupModuleOutput") and
#    fails Apple's ("cached output file has unknown path ...ModuleCache/
#    ..._Builtin_stdbool.pcm"). The wrapper appends -fno-modules, which comes
#    after SwiftPM's -fmodules and wins, and the module-map flags are dropped
#    too (a target that includes another's header, like swift-nio-ssl's
#    CNIOBoringSSLShims, otherwise fails loading the include tree); these are
#    plain C targets, and the object file does not depend on modules. Objective-C, which may @import,
#    is left alone, and so are WebAssembly compiles (the Worker build).
clang="$(command -v clang || true)"
wrapper="$RUNNER_TEMP/clang-cached"
if [ -z "$clang" ]; then
    echo "::notice::No clang on PATH, so C compiles run without the cache"
    exit 0
fi

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

cat > "$wrapper" <<WRAPPER
#!/bin/sh
export LD_LIBRARY_PATH="$library_path"
compile=0
for arg in "\$@"; do
    case "\$arg" in
        -c) compile=1 ;;
        *.S|*.s|*.sx|*.m|*.mm|-E|-S|-M|-MM|-emit-ast|-###|objective-c*|-fobjc*|*wasm*) exec "$clang" "\$@" ;;
    esac
done
[ "\$compile" = 1 ] || exec "$clang" "\$@"
# Module maps make the include tree name modules, which -fno-modules cannot
# load back ("failed to find module 'CNIOBoringSSL'"): keep includes textual.
# A few of these also come with the operand as the next argument, which has to
# go with the option.
skip=0
for arg; do
    shift
    if [ "\$skip" = 1 ]; then skip=0; continue; fi
    case "\$arg" in
        -fmodules-user-build-path|-fmodule-map-file|-fmodule-name) skip=1 ;;
        -fmodules|-fmodules-*|-fmodule-map-file=*|-fmodule-name=*|-fbuiltin-module-map|-fimplicit-module-maps) ;;
        *) set -- "\$@" "\$arg" ;;
    esac
done
exec "$clang" "\$@" -fno-modules -Wno-unused-command-line-argument \\
    -fdepscan -Rcompile-job-cache -Xclang -fcache-compile-job \\
    -Xclang -fcas-path -Xclang "$RUNNER_TEMP/cas-c" \\
    -Xclang -fcas-plugin-path -Xclang "$dir/$lib" \\
    -Xclang -fcas-plugin-option -Xclang "remote-url=$remote"
WRAPPER
chmod +x "$wrapper"

# Not every clang takes these options (an unknown one fails the build), so
# compile a file that includes a system header, the way SwiftPM does (with
# -fmodules), through the wrapper first, and export it only if that clang
# answers with a compile-job-cache remark, proving the options were applied
# and understood. The same check on Linux and macOS.
probe="$RUNNER_TEMP/clang-probe"
mkdir -p "$probe"
printf '#include <stdbool.h>\nbool probe(void) { return true; }\n' > "$probe/probe.c"
if output="$("$wrapper" -c "$probe/probe.c" -o "$probe/probe.o" \
        -fmodules -fmodules-cache-path="$probe/modules" 2>&1)" \
        && grep -q "compile job cache" <<<"$output"; then
    echo "CC=$wrapper" >> "$GITHUB_ENV"
    echo "Compiling C through the same cache ($wrapper)"
else
    # First line only: a clang that aborts prints a whole backtrace.
    echo "::notice::This clang did not take the compile-cache options, so C compiles run without the cache: $(head -n 1 <<<"${output:-no output}")"
fi
