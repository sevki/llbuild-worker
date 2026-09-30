#!/usr/bin/env bash
# How long a new /__rpc connection takes, against a route that touches no Durable
# Object, for each Worker URL given. A compiler opens a connection per process, so
# this is what a build pays hundreds of times: a fresh gateway Durable Object per
# connection took about 1.4 s over the baseline (issue #6). Samples alternate so
# drift affects both. Only reports; needs LLBUILD_CAS_TOKEN.
#
#   Scripts/time-connections.sh https://xcache.devtoo.ls https://<preview>
set -uo pipefail

: "${LLBUILD_CAS_TOKEN:?set LLBUILD_CAS_TOKEN}"
samples="${SAMPLES:-15}"
[ "$#" -gt 0 ] || { echo "usage: $0 <worker url>..." >&2; exit 2; }

# First-byte time in seconds, printed only for the response that was expected: 101
# for the upgrade, 200 for the plain route. curl prints a 0 time when a request
# fails, and a 401 or 404 comes back fast, so either would pass for a quick
# connection; those print nothing and are counted as failures instead. The upgrade
# holds the socket open, so curl is cut off after a few seconds (its exit status
# says nothing); the 101 and its first byte have arrived by then.
timed() { # <expected status> <curl args...>
    local want="$1"; shift
    local result status time
    result="$(curl --http1.1 -sS -o /dev/null -w '%{http_code} %{time_starttransfer}' "$@" 2>/dev/null)" || true
    read -r status time <<<"$result"
    [ "$status" = "$want" ] && echo "$time"
}
upgrade() { timed 101 -m 5 -H "Authorization: Bearer $LLBUILD_CAS_TOKEN" -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$1/__rpc"; }
plain() { timed 200 -m 10 "$1/setup"; }
# One call as a plain POST (no upgrade, no gateway). A sample counts only if the
# reply is the exact answer to the call: any 200 (an HTML page, a bare error, another
# call's id) would otherwise pass for a fast endpoint.
POST_CALL='{"id":"1","identifier":"$s11CASProtocol10CASServiceC8contains6digestSbSS_tYaKFTE","arguments":["0000000000000000000000000000000000000000000000000000000000000000"],"genericSubstitutions":[]}'
POST_REPLY='{"id":"1","result":false}'
post() {
    local body result status time
    body="$(mktemp)"
    result="$(curl --http1.1 -sS -m 10 -o "$body" -w '%{http_code} %{time_starttransfer}' -X POST \
        -H "Authorization: Bearer $LLBUILD_CAS_TOKEN" -d "$POST_CALL" "$1/__rpc" 2>/dev/null)" || true
    read -r status time <<<"$result"
    if [ "$status" = 200 ] && [ "$(cat "$body")" = "$POST_REPLY" ]; then echo "$time"; fi
    rm -f "$body"
}

median() { grep . | sort -n | awk '{a[NR]=$1} END {if (NR) printf "%.2f", (NR%2 ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2); else printf "n/a"}'; }

failed=0
for url in "$@"; do
    base="" ws="" rpc=""
    for _ in $(seq "$samples"); do
        base+="$(plain "$url")"$'\n'
        ws+="$(upgrade "$url")"$'\n'
        rpc+="$(post "$url")"$'\n'
    done
    nb="$(grep -c . <<<"$base")"; nw="$(grep -c . <<<"$ws")"; np="$(grep -c . <<<"$rpc")"
    b="$(median <<<"$base")"; w="$(median <<<"$ws")"; r="$(median <<<"$rpc")"
    line="$url: median first byte, no Durable Object $b s ($nb of $samples ok), new /__rpc WebSocket connection $w s ($nw of $samples ok), one POST /__rpc call $r s ($np of $samples ok; n/a where the Worker has no such endpoint)"
    echo "$line"
    [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "- $line" >> "$GITHUB_STEP_SUMMARY"
    if [ "$nb" -lt "$samples" ] || [ "$nw" -lt "$samples" ] || [ "$np" -lt "$samples" ]; then
        echo "::warning::$url: some requests did not get the expected response (200 for /setup and POST /__rpc, 101 for the WebSocket), so the medians use fewer samples"
        failed=1
    fi
done
# Only reports, but a run with nothing measured is not a result.
[ "$failed" -eq 0 ] || true
