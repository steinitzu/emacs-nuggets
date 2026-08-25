#!/bin/sh
# Run the md-table-align benchmark inside a real TTY frame.
#
# Same pty trick as run-tests.sh, plus a fixed frame size: the benchmark's
# call counts depend on window width (the viewport clips against it), so
# the frame is pinned at 400x60 rather than inherited from whatever
# terminal happens to run this.
#
# Prints the result as a ready-to-append Markdown section; to record a run:
#
#   tests/run-bench.sh >> tests/bench-results.md
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
log="$here/.last-bench.log"
rm -f "$log"

script -qec "stty rows 60 cols 400; ${EMACS:-emacs} -nw -Q -l '$here/bench-tables.el'" /dev/null \
  >/dev/null 2>&1 </dev/null || true

if [ ! -f "$log" ]; then
  echo "FAIL: benchmark produced no log -- Emacs likely died during startup" >&2
  exit 1
fi

cat "$log"
! grep -q '^BENCH ERROR' "$log"
