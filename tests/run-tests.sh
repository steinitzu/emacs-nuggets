#!/bin/sh
# Run the ERT suite inside a real TTY frame.
#
# The tests assert on rendered geometry via `posn-at-point', which needs the
# redisplay engine to have actually laid the buffer out.  `emacs --batch' has
# no usable frame, so we hand Emacs a pty with script(1) and it builds a real
# terminal frame.  Output goes through *Messages* to a log file, since in a
# TTY frame `message' writes to the echo area rather than stdout.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
log="$here/.last-run.log"
rm -f "$log"

# Emacs must not inherit this script's stdin, or a stray key can drive it.
script -qec "${EMACS:-emacs} -nw -Q -l '$here/run-tests.el'" /dev/null \
  >/dev/null 2>&1 </dev/null || true

if [ ! -f "$log" ]; then
  echo "FAIL: test run produced no log -- Emacs likely died during startup" >&2
  exit 1
fi

cat "$log"
grep -q '^RESULT: PASS$' "$log"
