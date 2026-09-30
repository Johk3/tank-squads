#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

"$ROOT/test/check-assets.sh" || { echo "asset check failed"; exit 1; }

setup_sandbox
trap stop_server EXIT
start_server || exit 1

fails=0
skips=0
# An optional argument runs only the cases whose file name starts with it.
for f in "$ROOT"/test/cases/${1:-}*.lua; do
  result=0
  run_case "$f" || result=$?
  if [ "$result" -eq 2 ]; then skips=$((skips + 1)); fi
  if [ "$result" -eq 1 ]; then fails=$((fails + 1)); fi
done

echo "---"
if [ "$fails" -gt 0 ]; then echo "$fails failing"; exit 1; fi
echo "all executed cases passing; $skips skipped (require a real test player)"
