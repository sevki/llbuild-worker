#!/usr/bin/env bash
# Shows whether a Swift compile's result really travels through the Worker.
# For each plugin setup (the released one CI downloads; one built from this
# checkout; that one again with remote-scope=all) it compiles one tiny file with swiftc twice against the live cache,
# the plugin's debug log on: the first compile publishes, the second starts with
# an empty local cache and should hit from the Worker. When a build of many
# files logs only misses, this says why: whether the compiler asked the plugin
# for the shared cache at all (globally=true or false), whether a publish
# happened, or whether the plugin disabled its remote. The build's own output
# never says, because a failing or unused remote is deliberately silent.
#
# Needs CAS_PLUGIN_PATH, CAS_REMOTE_URL and LLBUILD_CAS_TOKEN (set by
# Scripts/ci-compile-cache.sh and the workflow). Any arguments are passed to
# `swift build` when building the checkout's plugin (e.g. --build-system
# native). Only warns.
set -uo pipefail

: "${CAS_PLUGIN_PATH:?run Scripts/ci-compile-cache.sh first}"
: "${CAS_REMOTE_URL:?run Scripts/ci-compile-cache.sh first}"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

case "$(uname -s)" in Darwin) ext=dylib ;; *) ext=so ;; esac
# label | plugin | extra plugin option
plugins=("released|$CAS_PLUGIN_PATH|")
if swift build --package-path "$root" "$@" --product CASPlugin > "$work/build.log" 2>&1; then
    built="$(swift build --package-path "$root" "$@" --show-bin-path)/libCASPlugin.$ext"
    [ -f "$built" ] && plugins+=("checkout|$built|" "checkout, remote-scope=all|$built|remote-scope=all")
else
    echo "::warning::Could not build the checkout's plugin: $(tail -n 1 "$work/build.log" | cut -c1-200)"
fi

# What the plugin logged, as counts (a compile makes dozens of calls, most with
# globally=false, which is the compiler asking for the local cache only) plus the
# lines that say what reached the Worker.
show() {
    local text
    text="$(cat)"
    count() { grep -c -E "$1" <<<"$text" || true; }
    echo "calls the compiler made: lookups globally=true $(count 'action lookup .* globally=true'), globally=false $(count 'action lookup .* globally=false'); stores globally=true $(count 'action store .* globally=true'), globally=false $(count 'action store .* globally=false')"
    echo "reached the Worker: shared (published) $(count 'shared action'), kept local $(count 'kept action'), hit remotely $(count 'hit remotely'), objects fetched $(count 'fetched')"
    grep -E "remote disabled|cannot upload|not uploading|error|cache (hit|miss) for input" <<<"$text" | cut -c1-200 | head -n 6
}

for entry in "${plugins[@]}"; do
    IFS='|' read -r label plugin extra <<<"$entry"
    slug="${label//[^a-zA-Z0-9]/_}"
    dir="$work/$slug"
    mkdir -p "$dir"
    # A different function per run, so one's publish cannot answer the next one's first compile.
    printf 'public func triple_%s(_ x: Int) -> Int { x * 3 }\n' "$slug" > "$dir/a.swift"

    compile() { # <cas dir> <output>
        (cd "$dir" && LLBUILD_CAS_DEBUG=1 swiftc -c a.swift -module-name CheckSwiftCache -o "$2" \
            -explicit-module-build -cache-compile-job -Rcache-compile-job \
            -cas-path "$1" -cas-plugin-path "$plugin" \
            -cas-plugin-option "remote-url=$CAS_REMOTE_URL" ${extra:+-cas-plugin-option "$extra"} 2>&1)
    }

    echo "=== $label (${plugin##*/}${extra:+ with $extra})"
    echo "--- first compile (publishes):"
    first="$(compile "$dir/cas1" a1.o)"; show <<<"$first"
    echo "--- second compile (empty local cache; should hit from the Worker):"
    second="$(compile "$dir/cas2" a2.o)"; show <<<"$second"

    if grep -q "hit remotely" <<<"$second"; then
        echo "$label: the Swift result came back from the Worker."
    else
        echo "::warning::$label: a Swift compile with an empty local cache did not hit from the Worker"
    fi
    if grep -q "remote disabled" <<<"$first$second"; then
        echo "::warning::$label disabled its remote: $(grep -h 'remote disabled' <<<"$first$second" | head -n 1 | cut -c1-200)"
    fi
    if grep -q "globally=false" <<<"$first$second" && ! grep -q "globally=true" <<<"$first$second"; then
        echo "::warning::$label: the compiler only ever passed globally=false, so the shared cache was never consulted"
    fi
done
