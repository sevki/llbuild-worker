#!/usr/bin/env bash
# Stops the cache daemon Scripts/ci-compile-cache.sh started, if it did, and waits for it: on
# SIGTERM casd sends the results it has queued to the Worker (up to 30 s), which is how a CI run
# fills the cache for the next one. Prints what the daemon logged, which on exit includes what it
# asked of the Worker. Never fails the job.
set -uo pipefail
pidfile="${RUNNER_TEMP:-/tmp}/casd.pid"
[ -f "$pidfile" ] || exit 0
pid="$(cat "$pidfile")"
# `kill -0` is true for a process that has exited but was never reaped. In a container job nothing
# reaps the daemon (it was started by a step's shell that is gone), so look at its state too, or
# this waits the whole 45 s for a process that is already finished.
alive() {
    kill -0 "$pid" 2>/dev/null || return 1
    if [ -r "/proc/$pid/status" ] && grep -q '^State:[[:space:]]*Z' "/proc/$pid/status"; then
        return 1
    fi
    return 0
}
if alive; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 45); do
        alive || break
        sleep 1
    done
    if alive; then
        echo "::warning::casd did not stop within 45 s"
        kill -KILL "$pid" 2>/dev/null || true
    fi
fi
echo "--- casd log"
cat "${RUNNER_TEMP:-/tmp}/casd.log" 2>/dev/null | tail -n 40
rm -f "$pidfile"
exit 0
