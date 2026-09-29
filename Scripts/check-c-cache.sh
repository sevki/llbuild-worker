#!/usr/bin/env bash
# Shows whether C compiles really go through the compile cache in this job.
# CC points at the wrapper Scripts/ci-compile-cache.sh writes, but a build log
# with no "compile job cache" remark looks the same whether the wrapper ran and
# printed nothing or SwiftPM never called it. This recompiles one C file
# verbosely and prints the compile command (to see which compiler ran) and any
# cache remark. It only warns: the job's own result does not depend on it.
#
# The file it touches belongs to the CLLCAS target, so that is what it builds:
# building a product that does not depend on the target recompiles nothing and
# leaves nothing to look at (a first version did that and reported a false alarm).
#
# Usage: Scripts/check-c-cache.sh <build system and cache flags for swift build>
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
log="$(mktemp)"
touch "$root/Sources/CLLCAS/shim.c"
swift build "$@" --target CLLCAS -v > "$log" 2>&1
status=$?

echo "swift build exited $status; CC=${CC:-unset}"
echo "--- how the C file was compiled:"
grep -E "shim\.c" "$log" | grep -E -- "-c " | head -n 3 | cut -c1-500
if ! grep -q "shim\.c" "$log"; then
    echo "::warning::shim.c was not recompiled, so this check saw nothing"
fi
echo "--- cache remarks for it:"
grep -E "compile job cache" "$log" | head -n 3 | cut -c1-200
if grep -q "compile job cache" "$log"; then
    echo "C compiles go through the cache."
else
    echo "::warning::A C file was recompiled without a compile-cache remark: the C cache is not engaged in this job"
fi
