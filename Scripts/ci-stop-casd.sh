#!/usr/bin/env bash
# Stops the cache daemon Scripts/ci-compile-cache.sh started, if it did, and waits for it: on
# SIGTERM casd sends the results it has queued to the Worker (up to 30 s), which is how a CI run
# fills the cache for the next one. Prints what the daemon logged, which on exit includes what it
# asked of the Worker. Never fails the job.
set -uo pipefail
pidfile="${RUNNER_TEMP:-/tmp}/casd.pid"
[ -f "$pidfile" ] || exit 0
pid="$(cat "$pidfile")"
if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 45); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
        echo "::warning::casd did not stop within 45 s"
        kill -KILL "$pid" 2>/dev/null || true
    fi
fi
echo "--- casd log"
cat "${RUNNER_TEMP:-/tmp}/casd.log" 2>/dev/null | tail -n 40
rm -f "$pidfile"
exit 0
