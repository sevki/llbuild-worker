#!/usr/bin/env bash
# Stages clang/swift crash reproducers into <dest>, for a CI step to upload
# as an artifact when a job fails. A reproducer's own path is random (clang
# picks it) and, on macOS, outside the workspace ($TMPDIR is a per-user
# /var/folders/... directory), so the failing step's log only ever names it -
# without this, whoever triages the failure has to reproduce it themselves to
# see what clang saw.
#
#   Scripts/collect-crash-artifacts.sh <dest>
set -uo pipefail

dest="${1:?usage: collect-crash-artifacts.sh <dest>}"
mkdir -p "$dest"

# A clang crash reproducer is a *.sh script that re-runs the crashing
# invocation, plus the *.rsp (flags) and preprocessed source (*.cpp/*.c/*.m/
# *.mm/*.ii) it points at - see the "clang: note: diagnostic msg:" lines a
# crash prints. They land under TMPDIR (/tmp if unset).
find "${TMPDIR:-/tmp}" -maxdepth 1 \
    \( -iname '*.rsp' -o -iname '*.sh' -o -iname '*.cpp' -o -iname '*.c' -o -iname '*.m' -o -iname '*.mm' -o -iname '*.ii' \) \
    -exec cp -p {} "$dest/" \; 2>/dev/null

# A Swift compiler crash (as opposed to clang's own backend) writes its own
# reproducer bundle instead; swiftc prints its path, matching this pattern.
find "${TMPDIR:-/tmp}" -maxdepth 1 -iname 'swift-crash-reproducer*' \
    -exec cp -pr {} "$dest/" \; 2>/dev/null

# macOS's own crash reporter, for a clang that crashed hard enough not to
# print its own diagnostic (a signal, not a caught fatal error).
if [ -d "$HOME/Library/Logs/DiagnosticReports" ]; then
    find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 \( -iname '*.crash' -o -iname '*.ips' \) \
        -exec cp -p {} "$dest/" \; 2>/dev/null
fi

count=$(find "$dest" -maxdepth 1 -type f | wc -l | tr -d ' ')
echo "collected $count crash artifact(s) into $dest"
