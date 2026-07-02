#!/bin/sh
# All standalone checks (no store, no network). Exit 1 on any failure.
set -e
cd "$(dirname "$0")/.."
fail=0
for f in checks/*_test.exs; do
  if mix run "$f" >/tmp/objects-check.out 2>&1; then
    echo "ok   $f"
  else
    echo "FAIL $f"; tail -20 /tmp/objects-check.out; fail=1
  fi
done
exit $fail
