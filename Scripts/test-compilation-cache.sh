#!/usr/bin/env bash
# End-to-end check that swiftc's compilation caching works through CASPlugin:
# a first compile misses, an identical second compile hits and replays the same
# object, and a changed source misses again.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# BUILD_FLAGS lets CI pick a backend (macOS builds need --build-system native).
# shellcheck disable=SC2086
swift build ${BUILD_FLAGS:-} --package-path "$root" --product CASPlugin
case "$(uname -s)" in Darwin) ext=dylib ;; *) ext=so ;; esac
# shellcheck disable=SC2086
plugin="$(swift build ${BUILD_FLAGS:-} --package-path "$root" --show-bin-path)/libCASPlugin.$ext"
[ -f "$plugin" ] || { echo "plugin not found: $plugin" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"
printf 'public func add(_ a: Int, _ b: Int) -> Int { a + b }\n' > a.swift

compile() {
    swiftc -c "$1" -module-name M -o "$2" \
        -explicit-module-build -cache-compile-job \
        -cas-path "$work/cas" -cas-plugin-path "$plugin" \
        -Rcache-compile-job 2>&1
}

expect() { # <output> <pattern> <label>
    if ! grep -q "$2" <<<"$1"; then
        echo "FAIL: expected '$2' ($3). Output:" >&2
        echo "$1" >&2
        exit 1
    fi
    echo "ok: $3"
}

expect "$(compile a.swift first.o)" "cache miss" "first compile misses"
second="$(compile a.swift second.o)"
# Apple's compiler words a hit as "replay output file"; the open-source one
# also says "cache hit". Either way the object below must match the first.
expect "$second" "cache hit\|replay output file" "second compile hits"
cmp first.o second.o && echo "ok: replayed object is identical"

printf 'public func add(_ a: Int, _ b: Int) -> Int { a + b + 0 }\n' > a.swift
expect "$(compile a.swift third.o)" "cache miss" "changed source misses"
echo "compilation cache through CASPlugin: OK"
