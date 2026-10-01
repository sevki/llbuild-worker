/// The POSIX `sh` installer served at `/{scope}/setup` (see `route(...)` in
/// Worker.swift), meant to be run as
/// `curl --proto '=https' --tlsv1.2 -sSf https://xcache.devtoo.ls/setup | sh`
/// (or `.../prod/setup`, `.../dev/setup`, ... for a non-default scope).
///
/// It downloads the prebuilt CASPlugin and `casd` (the local cache daemon, see
/// docs/daemon.md) published by `.github/workflows/release.yml`, starts `casd` as a user
/// service, and writes the URL the plugin should use into the client's config: `casd`'s
/// loopback address for this scope once it answers, else `remoteURL` (this scope's own
/// `origin/scope`, computed from the request that fetched this script), so a daemon
/// that could not be installed or started never leaves the plugin talking to nothing.
func setupScript(scope: String, remoteURL: String) -> String {
    #"""
#!/bin/sh
# xcache installer: downloads libCASPlugin and the local cache daemon (casd), starts the
# daemon, and points the plugin at it (or, if that is not possible, at the remote cache).
#
#   LLBUILD_CAS_TOKEN=...   the access token (otherwise asked for on the terminal)
#   LLBUILD_CAS_NO_DAEMON=1 install the plugin only, and point it at the Worker directly
#   LLBUILD_CASD_PORT=4170  the loopback port the daemon listens on
set -eu

REPO="sevki/llbuild-worker"
REMOTE_URL="\#(remoteURL)"
INDEX_URL="$REMOTE_URL/"
BASE_URL="${LLBUILD_CAS_RELEASE_URL:-https://github.com/$REPO/releases/latest/download}"
PLUGIN_DIR="$HOME/.cache/llbuild-cas/plugin"
CONFIG_FILE="$HOME/.config/llbuild-cas-remote"
TOKEN_FILE="$HOME/.config/llbuild-cas-remote-token"
CASD_BIN="$HOME/.local/bin/casd"
CASD_PORT="${LLBUILD_CASD_PORT:-4170}"
UPSTREAM="${REMOTE_URL%/*}"
CACHE_URL="$REMOTE_URL"
daemon_note=""

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

# Downloads $1 (an archive name) from the release and checks it against SHA256SUMS.
fetch() {
    curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp/$1" "$BASE_URL/$1" \
        || { echo "could not download $BASE_URL/$1" >&2; return 1; }
    expected=$(awk -v f="$1" '$2 == f || $2 == "*" f { print $1 }' "$tmp/SHA256SUMS")
    [ -n "$expected" ] || { echo "no checksum listed for $1" >&2; return 1; }
    actual=$(sha256 "$tmp/$1")
    [ "$expected" = "$actual" ] || { echo "checksum mismatch for $1" >&2; return 1; }
}

archive="CASPlugin-$platform.tar.gz"

echo "Downloading $archive..."
curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp/SHA256SUMS" "$BASE_URL/SHA256SUMS" \
    || err "could not download $BASE_URL/SHA256SUMS"
fetch "$archive" || err "could not fetch $archive"

mkdir -p "$PLUGIN_DIR" "$(dirname "$CONFIG_FILE")"
tar -xzf "$tmp/$archive" -C "$tmp"
plugin="$PLUGIN_DIR/libCASPlugin.$ext"
mv -f "$tmp/libCASPlugin.$ext" "$plugin"

# casd is what makes the cache fast: the plugin starts a process per source file, and each
# would open its own connection to the Worker. The daemon keeps one, and the plugin talks to
# it on the loopback. It listens on the loopback only and does not authenticate its clients.
start_casd_service() {
    case "$(uname -s)" in
        Darwin)
            agents="$HOME/Library/LaunchAgents"
            plist="$agents/llbuild.casd.plist"
            mkdir -p "$agents" "$HOME/Library/Logs" || { daemon_note="could not create $agents"; return 1; }
            cat > "$plist" <<PLIST || { daemon_note="could not write $plist"; return 1; }
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>llbuild.casd</string>
    <key>ProgramArguments</key>
    <array>
        <string>$CASD_BIN</string>
        <string>--upstream</string>
        <string>$UPSTREAM</string>
        <string>--listen</string>
        <string>127.0.0.1:$CASD_PORT</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ExitTimeOut</key>
    <integer>45</integer>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/llbuild-casd.log</string>
</dict>
</plist>
PLIST
            # The login session's domain, or the user's own when there is no GUI session (an ssh login).
            uid=$(id -u)
            launchctl bootout "gui/$uid/llbuild.casd" >/dev/null 2>&1 || true
            launchctl bootout "user/$uid/llbuild.casd" >/dev/null 2>&1 || true
            if ! launchctl bootstrap "gui/$uid" "$plist" >/dev/null 2>&1 && ! launchctl bootstrap "user/$uid" "$plist"; then
                daemon_note="launchctl could not load $plist"
                return 1
            fi
            ;;
        *)
            if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
                daemon_note="there is no systemd user session to run it in"
                return 1
            fi
            unit_dir="$HOME/.config/systemd/user"
            mkdir -p "$unit_dir" || { daemon_note="could not create $unit_dir"; return 1; }
            cat > "$unit_dir/casd.service" <<UNIT || { daemon_note="could not write $unit_dir/casd.service"; return 1; }
[Unit]
Description=llbuild cache daemon (casd)
After=network-online.target

[Service]
ExecStart="$CASD_BIN" --upstream $UPSTREAM --listen 127.0.0.1:$CASD_PORT
Restart=on-failure
TimeoutStopSec=45

[Install]
WantedBy=default.target
UNIT
            if ! systemctl --user daemon-reload || ! systemctl --user enable casd.service >/dev/null 2>&1 \
                || ! systemctl --user restart casd.service; then
                daemon_note="systemd could not start $unit_dir/casd.service"
                return 1
            fi
            ;;
    esac
}

# Stops a daemon this installer started before (a re-run), so the port is ours to check.
stop_casd_service() {
    case "$(uname -s)" in
        Darwin)
            launchctl bootout "gui/$(id -u)/llbuild.casd" >/dev/null 2>&1 || true
            launchctl bootout "user/$(id -u)/llbuild.casd" >/dev/null 2>&1 || true
            ;;
        *)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl --user stop casd.service >/dev/null 2>&1 || true
            fi
            ;;
    esac
}

# Takes the service out altogether (stopped, not enabled, its file gone), for a daemon that was
# started and did not come up: left in place, the service manager would keep relaunching it.
remove_casd_service() {
    stop_casd_service
    case "$(uname -s)" in
        Darwin)
            rm -f "$HOME/Library/LaunchAgents/llbuild.casd.plist"
            ;;
        *)
            if command -v systemctl >/dev/null 2>&1; then
                systemctl --user disable casd.service >/dev/null 2>&1 || true
            fi
            rm -f "$HOME/.config/systemd/user/casd.service"
            if command -v systemctl >/dev/null 2>&1; then
                systemctl --user daemon-reload >/dev/null 2>&1 || true
            fi
            ;;
    esac
}

# What the service manager says about a daemon that was started and did not answer, so the
# reason is in the installer's output and not only in a log nobody opens.
casd_diagnostics() {
    echo "The daemon was started and did not answer. What the service manager says:" >&2
    case "$(uname -s)" in
        Darwin)
            { launchctl print "gui/$(id -u)/llbuild.casd" 2>&1 || launchctl print "user/$(id -u)/llbuild.casd" 2>&1; } | head -n 30 >&2 || true
            echo "Its log ($HOME/Library/Logs/llbuild-casd.log):" >&2
            tail -n 15 "$HOME/Library/Logs/llbuild-casd.log" >&2 2>&1 || true
            ;;
        *)
            systemctl --user status casd.service --no-pager 2>&1 | tail -n 15 >&2 || true
            ;;
    esac
}

# True once something answers HTTP on the daemon's port.
casd_up() {
    code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$CASD_PORT/" 2>/dev/null) || code=000
    [ "$code" != 000 ]
}

# Every step is checked by hand: this runs as the condition of an `if`, where `set -e` is off.
do_install_casd() {
    casd_archive="casd-$platform.tar.gz"
    echo "Downloading $casd_archive..."
    if ! fetch "$casd_archive"; then
        daemon_note="the release has no usable $casd_archive"
        return 1
    fi
    if ! tar -xzf "$tmp/$casd_archive" -C "$tmp" || [ ! -f "$tmp/casd" ]; then
        daemon_note="$casd_archive could not be unpacked"
        return 1
    fi
    # From here on a failure leaves things changed, so install_casd takes the service out again.
    casd_touched=1
    # With our own daemon stopped, the port must be free: if it still answers, another program
    # owns it, and whatever answers after the daemon is started could not be taken for ours.
    stop_casd_service
    sleep 1
    if casd_up; then
        daemon_note="port $CASD_PORT is already in use by another program (set LLBUILD_CASD_PORT to use a different one)"
        return 1
    fi
    if ! mkdir -p "$(dirname "$CASD_BIN")" || ! mv -f "$tmp/casd" "$CASD_BIN" || ! chmod 755 "$CASD_BIN"; then
        daemon_note="could not install $CASD_BIN"
        return 1
    fi
    start_casd_service || return 1
    tries=0
    while [ "$tries" -lt 10 ]; do
        if casd_up; then
            return 0
        fi
        tries=$((tries + 1))
        sleep 1
    done
    daemon_note="it did not answer on 127.0.0.1:$CASD_PORT"
    casd_diagnostics
    return 1
}

casd_touched=""
install_casd() {
    if do_install_casd; then
        return 0
    fi
    if [ -n "$casd_touched" ]; then
        remove_casd_service
    fi
    return 1
}

if [ -n "${LLBUILD_CAS_NO_DAEMON:-}" ]; then
    daemon_note="skipped (LLBUILD_CAS_NO_DAEMON is set)"
elif install_casd; then
    CACHE_URL="http://127.0.0.1:$CASD_PORT/\#(scope)"
    daemon_note=""
fi

echo "$CACHE_URL" > "$CONFIG_FILE"

# The cache requires an access token. It is never served from here; take it
# from the environment or ask for it on the terminal (stdin is this script).
token="${LLBUILD_CAS_TOKEN:-}"
if [ -z "$token" ] && ( : < /dev/tty ) 2>/dev/null; then
    printf 'Access token for %s (input hidden): ' "$REMOTE_URL" > /dev/tty
    stty -echo < /dev/tty 2>/dev/null || true
    read -r token < /dev/tty || token=""
    stty echo < /dev/tty 2>/dev/null || true
    echo > /dev/tty
fi
if [ -n "$token" ]; then
    (umask 077; printf '%s\n' "$token" > "$TOKEN_FILE")
    token_note="Wrote $TOKEN_FILE"
else
    token_note="No access token saved: put one in $TOKEN_FILE or set LLBUILD_CAS_TOKEN, or the cache will refuse connections."
fi

if [ "$CACHE_URL" = "$REMOTE_URL" ]; then
    cache_note="The local cache daemon is NOT in use ($daemon_note), so the plugin talks to the Worker directly, which is much slower.
Run it yourself with:  $CASD_BIN --upstream $UPSTREAM --listen 127.0.0.1:$CASD_PORT
and then write http://127.0.0.1:$CASD_PORT/\#(scope) into $CONFIG_FILE.
(If port $CASD_PORT is taken, set LLBUILD_CASD_PORT to another and run the installer again.)"
else
    cache_note="Started the local cache daemon ($CASD_BIN, listening on 127.0.0.1:$CASD_PORT, upstream $UPSTREAM)."
fi

cat <<EOF

Installed $plugin (scope: \#(scope))
Wrote $CONFIG_FILE ($CACHE_URL)
$token_note
$cache_note

swiftc:

  swiftc -c main.swift -explicit-module-build -cache-compile-job \\
    -cas-path ~/.cache/llbuild-cas \\
    -cas-plugin-path $plugin \\
    -cas-plugin-option remote-url=$CACHE_URL \\
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
}
