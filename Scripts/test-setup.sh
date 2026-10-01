#!/usr/bin/env bash
# Tests the installer the Worker serves at /setup (Sources/CASWorker/Setup.swift): that it
# installs casd, starts it as a user service, and points the plugin at it only once it answers,
# and that every way it can fail leaves the plugin pointed at the Worker, not at nothing.
#
# The installer is rendered from the Swift source and run against a fake release (a local
# HTTP server) with a stand-in casd. Two changes are made to the rendered copy, and only
# those: the curl flags that insist on https are dropped (the fake release is plain http), and
# the download base is the fake release (LLBUILD_CAS_RELEASE_URL).
#
# Linux: the service manager is a stub systemctl that "starts" the unit's ExecStart.
# macOS: the real launchctl loads the real plist, so the launchd branch is really exercised.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) platform=macos-arm64; os=mac ;;
    Linux/x86_64) platform=linux-x86_64; os=linux ;;
    *) echo "skipping: no prebuilt platform for $(uname -s) $(uname -m)"; exit 0 ;;
esac
command -v python3 >/dev/null || { echo "python3 is needed" >&2; exit 1; }
py="$(command -v python3)"

work="$(mktemp -d)"
port=4199
relport=8480
pids=""
fail=0

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
stopcasd() {
    # The stub systemctl records what it starts; pkill is a second net where it exists.
    if [ -f "$work/casd.pids" ]; then
        for p in $(cat "$work/casd.pids"); do kill "$p" 2>/dev/null || true; done
        : > "$work/casd.pids"
    fi
    pkill -f "http.server $port" 2>/dev/null || true
    if [ "$os" = mac ]; then
        for h in "$work"/home-*; do
            [ -d "$h" ] || continue
            launchctl bootout "gui/$(id -u)/llbuild.casd" >/dev/null 2>&1 || true
            launchctl bootout "user/$(id -u)/llbuild.casd" >/dev/null 2>&1 || true
        done
    fi
    sleep 1
}
cleanup() {
    stopcasd
    for p in $pids; do kill "$p" 2>/dev/null || true; done
    rm -rf "$work"
}
trap cleanup EXIT
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

# Render the installer: the text between the raw-string delimiters, interpolations filled in,
# and the https-only curl flags dropped (see the header).
mkdir -p "$work/bin" "$work/rel"
awk '/^    #"""$/{f=1;next} /^"""#$/{f=0} f' "$root/Sources/CASWorker/Setup.swift" \
    | sed -e 's|\\#(remoteURL)|https://cache.example/default|' -e 's|\\#(scope)|default|' \
          -e "s|--proto '=https' --tlsv1.2 ||" > "$work/setup.sh"
check "installer rendered" "[ -s $work/setup.sh ] && head -1 $work/setup.sh | grep -q '^#!/bin/sh'"
check "installer is valid sh" "sh -n $work/setup.sh"
check "https flags dropped only in the test copy" "! grep -q -- \"--proto\" $work/setup.sh && grep -q -- \"--proto '=https'\" $root/Sources/CASWorker/Setup.swift"

# A stand-in casd: takes the real flags and serves HTTP on --listen.
cat > "$work/fakecasd" <<EOF
#!/bin/sh
while [ \$# -gt 0 ]; do case "\$1" in --listen) addr="\$2"; shift 2;; *) shift;; esac; done
exec "$py" -m http.server "\${addr##*:}" --bind "\${addr%:*}"
EOF
chmod +x "$work/fakecasd"
mkdir -p "$work/stage"
cp "$work/fakecasd" "$work/stage/casd"; : > "$work/stage/libCASPlugin.so"; : > "$work/stage/libCASPlugin.dylib"
tar -C "$work/stage" -czf "$work/rel/casd-$platform.tar.gz" casd
tar -C "$work/stage" -czf "$work/rel/CASPlugin-$platform.tar.gz" libCASPlugin.so libCASPlugin.dylib
sums() { (cd "$work/rel" && sha256 "$@" > SHA256SUMS); }
sums CASPlugin-$platform.tar.gz casd-$platform.tar.gz

# The fake release.
(cd "$work/rel" && exec "$py" -m http.server "$relport" --bind 127.0.0.1 >/dev/null 2>&1) &
pids="$pids $!"
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -sf -o /dev/null "http://127.0.0.1:$relport/SHA256SUMS" && break; sleep 1; done

# A stub systemctl for Linux that "starts" the unit's ExecStart in the background.
cat > "$work/bin/systemctl" <<EOF
#!/bin/sh
[ "\$1" = "--user" ] && shift
case "\$1" in
  restart)
    cmd=\$(sed -n 's/^ExecStart=//p' "\$HOME/.config/systemd/user/casd.service")
    eval "nohup \$cmd >/dev/null 2>&1 &"
    echo \$! >> "$work/casd.pids"
    ;;
esac
exit 0
EOF
chmod +x "$work/bin/systemctl"

run() { # name, then VAR=value words
    name="$1"; shift
    h="$work/home-$name"; mkdir -p "$h"
    env HOME="$h" LLBUILD_CAS_RELEASE_URL="http://127.0.0.1:$relport" LLBUILD_CAS_TOKEN=test-token \
        LLBUILD_CASD_PORT=$port "$@" sh "$work/setup.sh" < /dev/null > "$work/out-$name.txt" 2>&1
    echo $? > "$work/rc-$name"
}
cfg() { cat "$work/home-$1/.config/llbuild-cas-remote"; }
withsvc() { if [ "$os" = linux ]; then echo "PATH=$work/bin:$PATH"; else echo "PATH=$PATH"; fi; }

# A: the daemon is installed, started by the service manager, and used.
run A "$(withsvc)"
check "A: exit 0" "[ \$(cat $work/rc-A) = 0 ]"
check "A: casd installed" "[ -x $work/home-A/.local/bin/casd ]"
if [ "$os" = linux ]; then
    check "A: unit has the upstream and port" "grep -q 'ExecStart=\"$work/home-A/.local/bin/casd\" --upstream https://cache.example --listen 127.0.0.1:$port' $work/home-A/.config/systemd/user/casd.service"
else
    check "A: plist has the upstream and port" "grep -q '<string>https://cache.example</string>' $work/home-A/Library/LaunchAgents/llbuild.casd.plist && grep -q '<string>127.0.0.1:$port</string>' $work/home-A/Library/LaunchAgents/llbuild.casd.plist"
    check "A: plist is valid" "plutil -lint $work/home-A/Library/LaunchAgents/llbuild.casd.plist >/dev/null"
fi
check "A: the plugin is pointed at the daemon" "[ \"\$(cfg A)\" = http://127.0.0.1:$port/default ]"
check "A: the token is saved, mode 600" "[ \"\$(cat $work/home-A/.config/llbuild-cas-remote-token)\" = test-token ] && [ \$(mode $work/home-A/.config/llbuild-cas-remote-token) = 600 ]"
check "A: the output says so" "grep -q 'Started the local cache daemon' $work/out-A.txt && grep -q 'remote-url=http://127.0.0.1:$port/default' $work/out-A.txt"
stopcasd

# B (Linux): no systemd user session, so no daemon; falls back to the Worker and says why.
if [ "$os" = linux ]; then
    run B
    check "B: exit 0" "[ \$(cat $work/rc-B) = 0 ]"
    check "B: the plugin is pointed at the Worker" "[ \"\$(cfg B)\" = https://cache.example/default ]"
    check "B: says it is not in use, and why" "grep -q 'NOT in use (there is no systemd user session' $work/out-B.txt"
    check "B: the plugin is still installed" "[ -e $work/home-B/.cache/llbuild-cas/plugin/libCASPlugin.so ]"
fi

# C: the release has no casd archive.
mv "$work/rel/casd-$platform.tar.gz" "$work/casd.hold"
sums CASPlugin-$platform.tar.gz
run C "$(withsvc)"
check "C: exit 0" "[ \$(cat $work/rc-C) = 0 ]"
check "C: the plugin is pointed at the Worker" "[ \"\$(cfg C)\" = https://cache.example/default ]"
check "C: says the release has no casd" "grep -q 'has no usable casd-$platform.tar.gz' $work/out-C.txt"
mv "$work/casd.hold" "$work/rel/casd-$platform.tar.gz"

# D: casd's checksum does not match.
{ sha256 "$work/rel/CASPlugin-$platform.tar.gz" | sed "s|$work/rel/||"
  echo "0000000000000000000000000000000000000000000000000000000000000000  casd-$platform.tar.gz"; } > "$work/rel/SHA256SUMS"
run D "$(withsvc)"
check "D: exit 0" "[ \$(cat $work/rc-D) = 0 ]"
check "D: casd is not installed" "[ ! -e $work/home-D/.local/bin/casd ]"
check "D: the plugin is pointed at the Worker" "[ \"\$(cfg D)\" = https://cache.example/default ]"
sums CASPlugin-$platform.tar.gz casd-$platform.tar.gz

# E: opted out.
run E "$(withsvc)" LLBUILD_CAS_NO_DAEMON=1
check "E: exit 0" "[ \$(cat $work/rc-E) = 0 ]"
check "E: no casd, plugin pointed at the Worker" "[ ! -e $work/home-E/.local/bin/casd ] && [ \"\$(cfg E)\" = https://cache.example/default ]"
check "E: says it was skipped" "grep -q 'skipped (LLBUILD_CAS_NO_DAEMON is set)' $work/out-E.txt"

# F: the service is started but the daemon never answers.
mkdir -p "$work/dead"; printf '#!/bin/sh\nexit 1\n' > "$work/dead/casd"; chmod +x "$work/dead/casd"
tar -C "$work/dead" -czf "$work/rel/casd-$platform.tar.gz" casd
sums CASPlugin-$platform.tar.gz casd-$platform.tar.gz
run F "$(withsvc)"
check "F: exit 0" "[ \$(cat $work/rc-F) = 0 ]"
check "F: the plugin is pointed at the Worker" "[ \"\$(cfg F)\" = https://cache.example/default ]"
check "F: says it did not answer" "grep -q 'did not answer on 127.0.0.1:$port' $work/out-F.txt"

if [ "$fail" = 0 ]; then echo "ALL OK"; else
    echo "SOME FAILED"
    for n in A B C D E F; do [ -f "$work/out-$n.txt" ] && { echo "--- out-$n"; tail -15 "$work/out-$n.txt"; }; done
fi
exit $fail
