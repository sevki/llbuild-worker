/// The POSIX `sh` installer served at `/setup` (see `fetch(_:_:_:)` in
/// Worker.swift), meant to be run as
/// `curl --proto '=https' --tlsv1.2 -sSf https://xcache.devtoo.ls/setup | sh`.
///
/// It downloads the prebuilt CASPlugin published by
/// `.github/workflows/release.yml`.
let setupScript = #"""
#!/bin/sh
# xcache installer: downloads libCASPlugin and points it at the remote cache.
set -eu

REPO="sevki/llbuild-worker"
REMOTE_URL="https://xcache.devtoo.ls"
INDEX_URL="$REMOTE_URL/"
BASE_URL="https://github.com/$REPO/releases/latest/download"
PLUGIN_DIR="$HOME/.cache/llbuild-cas/plugin"
CONFIG_FILE="$HOME/.config/llbuild-cas-remote"

err() {
    echo "error: $*" >&2
    exit 1
}

unsupported() {
    echo "error: unsupported platform: $(uname -s) $(uname -m)" >&2
    echo "Prebuilt plugins exist for macOS arm64 and Linux x86_64 only." >&2
    echo "See the manual instructions at $INDEX_URL" >&2
    exit 1
}

case "$(uname -s)/$(uname -m)" in
    Darwin/arm64)
        platform=macos-arm64
        ext=dylib
        ;;
    Linux/x86_64)
        platform=linux-x86_64
        ext=so
        ;;
    *)
        unsupported
        ;;
esac

if command -v sha256sum >/dev/null 2>&1; then
    sha256() { sha256sum "$1" | cut -d ' ' -f 1; }
elif command -v shasum >/dev/null 2>&1; then
    sha256() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
else
    err "need sha256sum or shasum to verify the download"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

archive="CASPlugin-$platform.tar.gz"

echo "Downloading $archive..."
curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp/$archive" "$BASE_URL/$archive" \
    || err "could not download $BASE_URL/$archive"
curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp/SHA256SUMS" "$BASE_URL/SHA256SUMS" \
    || err "could not download $BASE_URL/SHA256SUMS"

expected=$(awk -v f="$archive" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHA256SUMS")
[ -n "$expected" ] || err "no checksum listed for $archive"
actual=$(sha256 "$tmp/$archive")
[ "$expected" = "$actual" ] || err "checksum mismatch for $archive"

mkdir -p "$PLUGIN_DIR" "$(dirname "$CONFIG_FILE")"
tar -xzf "$tmp/$archive" -C "$tmp"
plugin="$PLUGIN_DIR/libCASPlugin.$ext"
mv -f "$tmp/libCASPlugin.$ext" "$plugin"

echo "$REMOTE_URL" > "$CONFIG_FILE"

cat <<EOF

Installed $plugin
Wrote $CONFIG_FILE

swiftc:

  swiftc -c main.swift -explicit-module-build -cache-compile-job \\
    -cas-path ~/.cache/llbuild-cas \\
    -cas-plugin-path $plugin \\
    -cas-plugin-option remote-url=$REMOTE_URL \\
    -Rcache-compile-job

Xcode / Swift Build settings:

  COMPILATION_CACHE_ENABLE_CACHING = YES
  SWIFT_ENABLE_EXPLICIT_MODULES = YES
  SWIFT_USE_INTEGRATED_DRIVER = YES
  COMPILATION_CACHE_ENABLE_PLUGIN = YES
  COMPILATION_CACHE_PLUGIN_PATH = $plugin
  COMPILATION_CACHE_REMOTE_SERVICE_PATH = $CONFIG_FILE
EOF

"""#
