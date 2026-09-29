#!/usr/bin/env bash
# Shows whether C compiles really go through the compile cache in this job.
# CC points at the wrapper Scripts/ci-compile-cache.sh writes, but a build log
# with no "compile job cache" remark looks the same whether the wrapper ran and
# printed nothing or SwiftPM never called it. This recompiles one C file
# verbosely and prints the compile command (to see which compiler ran) and any
# cache remark. It only warns: the job's own result does not depend on it.
#
# Usage (after the build): Scripts/check-c-cache.sh <swift build args...>
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
log="$(mktemp)"
touch "$root/Sources/CLLCAS/shim.c"
swift build "$@" -v > "$log" 2>&1
status=$?

echo "swift build exited $status; CC=${CC:-unset}"
echo "--- how the C file was compiled:"
grep -E "shim\.c" "$log" | grep -v "^\[" | head -n 3 | cut -c1-900
echo "--- cache remarks for it:"
grep -E "compile job cache" "$log" | head -n 3 | cut -c1-200
if grep -q "compile job cache" "$log"; then
    echo "C compiles go through the cache."
else
    echo "::warning::A C file was recompiled without a compile-cache remark: the C cache is not engaged in this job"
fi
