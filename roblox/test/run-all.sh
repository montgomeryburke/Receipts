#!/bin/bash
# Every check, in one go. Needs `luau` on PATH (or set LUAU).
cd "$(dirname "$0")/.." || exit 1
LUAU="${LUAU:-luau}"
fail=0
for suite in maptest servertest clienttest drivetest shoottest; do
  echo "=============== $suite ==============="
  python3 "test/run-$suite.py" > "/tmp/$suite.luau" || { echo "assembly failed"; fail=1; continue; }
  "$LUAU" "/tmp/$suite.luau" || fail=1
  echo
done
echo "=============== servertest, unpublished place ==============="
python3 test/run-servertest.py --block-datastore > /tmp/servertest_ds.luau
"$LUAU" /tmp/servertest_ds.luau || fail=1
exit $fail
