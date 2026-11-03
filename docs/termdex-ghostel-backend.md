# termdex: ghostel as a second terminal backend

Status: **implemented** on 2026-10-28. The design and its deviations are in
termdex/DESIGN.md ("Backends: vterm and ghostel"), which supersedes the plan
below. Kept for the measurements and the rejected options.

## The ask

> Can termdex work with ghostel? Make the terminal backend configurable.
> Support both vterm and ghostel. If only one is installed use that one,
> otherwise pick a default (ghostel).

Short answer: **yes**. Everything termdex knows about a terminal comes from
`/proc`, asked of a leader pid, and that works on a ghostel unchanged. The one
real gap is the cleanup sweep's activity signal (below).

## What ghostel is (v0.59.0, MELPA `ghostel-20261027.833`)

Emacs terminal on libghostty-vt, by dakra (github.com/dakra/ghostel). A native
module does VT parsing and, by default, owns the PTY itself
(`ghostel-use-native-pty`, default `t`). The pieces termdex needs:

| termdex needs | vterm | ghostel |
|---|---|---|
| major mode | `vterm-mode` | `ghostel-mode` |
| live check | `(process-live-p vterm--process)` | `(process-live-p ghostel--process)` |
| leader pid | `(process-id vterm--process)` | **`ghostel--pid`** — see trap below |
| send text | `vterm-send-string` (current buffer) | `ghostel-send-string` (current buffer) |
| create | `(vterm NAME)` | `(ghostel t)` with `ghostel-buffer-name` let-bound to the name; returns the buffer |
| name follows title | `vterm-buffer-name-string` (format string) | `ghostel-buffer-name-function` (function of TITLE, read in the buffer, so `setq-local` works) |
| remote `default-directory` | OSC 51 via `vterm_prompt_end` | OSC 7, which ghostel's own shell integration emits; TRAMP path when remote |

**Trap:** with the native PTY, `ghostel--process` is a *pipe* process
(`ghostel-native-process`) and `process-id` on it is nil. The pid must come
from `ghostel--pid`. Under `ghostel-use-native-pty nil` it is also set
(`ghostel--spawn-via-emacs`), so `ghostel--pid` is right in both modes.
`ghostel--shell-forked` exists for a macOS login wrapper that forks; the
descendant walk already handles a wrapper above the shell.

## Validated (hacks/ghostel-probe.el → hacks/ghostel-probe.out)

Real ghostel in a TTY frame, termdex's `/proc` functions on `ghostel--pid`:

- cwd follows `cd` (`/usr` → `/etc`). `default-directory` followed too, via
  ghostel's shell integration — still not to be trusted (nested shells).
- busy: `sleep 30` → fg `("sleep")`; `C-c` → idle.
- nested `bash --norc` + `cd /tmp` → current shell is the inner bash, cwd
  `/tmp/`, idle. Experiment 5 of termdex/DESIGN.md holds.
- `ghostel-send-string` from `with-current-buffer` works.

## The gap: cleanup's activity signal is blind on a buried ghostel

Same probe: buried, idle 6s → tick still (good); displayed, idle 6s → still
(good); **`echo hi` while buried → tick did not move.** `ghostel--invalidate`
defers rendering for a buffer with no window (`ghostel--pending-redraw t`), so
nothing is written to the buffer until it is shown. termdex's sweep reads
`buffer-chars-modified-tick` as "the terminal produced output", which is true for
vterm and false for a buried ghostel.

Practical impact is small, since busy terminals and shells with children are protected
anyway. But the signal should be right, and the
`termdex-cleanup-restarts-the-clock-on-output` test would fail for ghostel.

Options considered:

1. **`ghostel--pending-redraw` flipping nil→t as an activity edge.** Zero state,
   but it stays `t` until the buffer is displayed. A second burst of output is
   invisible, so the restart-on-output test still fails if startup output landed
   after burial. Rejected as the sole signal. As a *protection* ("unseen
   output") it would stop cleanup from ever closing a terminal you ran
   something in and left, which defeats the feature.
2. **Advice / `add-function` on the event pipe's filter** to count output.
   Exact, but it breaks termdex's "no advice, no hooks" rule. After an
   `unload-feature` the wrapper would reference unbound symbols and signal on
   every output. Rejected.
3. **The current shell's `wchar` from `/proc/PID/io`** (in progress). It needs
   nothing from ghostel. The argument: the sweep only asks about terminals that are not busy and
   have no children, and for those the only thing that can write to the
   terminal is the shell itself. Every finished command ends with a new prompt,
   readline echoes typed characters itself, and `echo` is a builtin. Reading
   `/proc/<own pid>/io` from Emacs works (checked). **Validated** by
   `hacks/ghostel-io-probe.el` (two runs, same shape):

   | case | wchar |
   |---|---|
   | buried, idle 6s | 8922 → 8922 |
   | `echo hi` buried | 8922 → 9132 |
   | `ls` buried | 9132 → 9524 |
   | typing `abc`, no RET, buried | +3 (readline echo) |
   | displaying it | unchanged |
   | displayed, idle 6s | unchanged |
   | nested bash, idle 6s | unchanged (inner shell's own counter) |
   | nested `echo hi` | +38 |

   It is still at a prompt nobody touches, it moves on buried output and on
   keystrokes, and redisplay doesn't touch it. When the current shell changes
   (a nested bash starts or exits) the value jumps, which counts as activity.
   That is correct.

Decided: ghostel's activity mark = `(tick . shell-wchar)`, and vterm keeps its
validated tick-only signal. Generalise the record's `eql` on a tick to `equal`
on a backend-supplied mark (`termdex--cleanup-activity`,
`termdex--cleanup-quiet-since`, `termdex--cleanup-quiet-for`). The tests'
`termdex-tests--quiet` / `--spoke` read the tick directly and would need the
same mark.

### The probe's hang was a kill query, and termdex has the same bug

The io probe measured everything, then hung in `kill-buffer`. The earlier guess
was wrong: it wasn't the never-displayed buffer. ghostel adds
`ghostel--kill-buffer-query` to `kill-buffer-query-functions` **buffer-locally**
(`ghostel.el` `ghostel-mode`). `(let ((kill-buffer-query-functions nil)) ...)`
from another buffer binds only the global value, so the local hook still runs.
With `ghostel-query-before-killing` at its default `auto` and a command running
(the nested bash), it calls `yes-or-no-p` and waits forever.

termdex uses that idiom in `termdex-list-kill` and `termdex--cleanup-close`. It
works for vterm, whose query is the global `process-kill-buffer-query-function`.
On ghostel the cleanup sweep would raise a prompt from a timer whenever
`ghostel-command-running-p` (shell integration's view) says busy and termdex's
`/proc` view doesn't, e.g. a shell blocked in `read`.

Fix, verified in the probe: bind it with the terminal current, so the `let`
binds the buffer-local value:

```elisp
(with-current-buffer buffer
  (let ((kill-buffer-query-functions nil))
    (kill-buffer buffer)))
```

Give it one helper, `termdex--kill`, used by both call sites and by the tests'
teardown (`tests/termdex-tests.el` has the same `let` twice). Needs a test: a
ghostel running a nested shell is killed by the sweep with no prompt.

## Planned shape (not yet written to termdex/DESIGN.md)

- `defcustom termdex-backend`: `auto` (default), `ghostel`, `vterm`. `auto` =
  ghostel if `(locate-library "ghostel")`, else vterm; error clearly if
  neither is installed. Symbols, not units, so the CLAUDE.md reload trap does not
  apply.
- **The backend chooses what termdex *creates*, not what it *indexes*.** Every
  live vterm and ghostel buffer is a terminal regardless of the setting, so
  switching backends mid-session doesn't orphan the old terminals from the
  switcher, dashboard, cleanup or indicator. Worth confirming with the user.
- Dispatch by major mode in a few small functions:
  `termdex--terminal-buffer-p` (replaces `termdex--vterm-buffer-p`, used by the
  redisplay-time indicator, so it has to stay cheap), `termdex--leader-pid`, `termdex--send-string`,
  `termdex--create`, plus the activity mark. Everything else in termdex
  (matching, switching, dashboard, probe) is untouched.
- Naming: for ghostel, `setq-local ghostel-buffer-name-function` to a lambda
  formatting the title with `termdex-buffer-name-string`, nil title → nil (no
  rename).
- `declare-function` / `defvar` for the ghostel symbols, as for vterm.
- Byte-compile must stay warning-free (`make compile`).

## Tests

- `tests/install-ghostel.el` **written, worked** (untracked, not committed):
  installs ghostel into `.test-env/elpa` and calls `ghostel--download-module`
  for the prebuilt `ghostel-module-x86_64-linux.so` from GitHub releases, since
  batch mode can't answer the first-use prompt. Still to do: a
  `$(ELPA)/.ghostel-stamp` target in `make deps`, mirroring vterm's, that warns
  rather than fails.
- `tests/run-tests.el` comment says "currently just vterm", which needs updating.
- Run the existing real-terminal suite against **both** backends rather than
  duplicate it. The helpers that touch vterm directly are `termdex-tests--type`,
  `--settle` (`vterm--process`), `--terminal` (`vterm`), the background-job test
  (`vterm--process`), and the naming test (`vterm-send-string`). Route them
  through the new backend functions and a `termdex-tests--backend` binding, and
  have `termdex-tests--deftest` emit one test per available backend, each
  `skip-unless` that backend loads.
- New tests: backend resolution (`auto` with one, both, or neither installed;
  this one can stub `locate-library`), and that both kinds are indexed whatever
  the backend.

## Also to update when implemented

termdex/DESIGN.md (Scope section says "Only vterm"; feasibility table; the
activity-signal section), termdex.el commentary and the defgroup docstring
("many vterms"), README.md termdex section (new option, ghostel support).
