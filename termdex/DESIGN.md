# termdex — planning and design

Multi-terminal handling for `vterm`: an overview of every live terminal, and
directory-aware commands for reaching or spawning one.

Supersedes `docs/vterm-plan.md`, which is the original statement of intent.

## Name

`termdex` — "terminal index". Deliberately **not** prefixed `vterm-`: that
namespace belongs to `vterm` itself, and sharing it would confuse
`unload-feature`, `customize-group`, and anyone reading a backtrace. The name is
cheap to change now and expensive later; say so if you want a different one.

## Problem

With more than three or four terminals open, three things go wrong:

- There is no overview. `C-x b` shows buffer names, which say nothing about what
  each terminal is *doing*.
- Reaching "a terminal in this directory" means remembering which buffer that
  is. Project-tied helpers (`projectile-run-vterm` and friends) bind a terminal
  to the project it was born in, which is wrong: **a terminal belongs to
  wherever it is now.** `cd` elsewhere and it is a terminal of that directory.
- Buffer names do not track what the terminal is or where it is.

## Feasibility (validated before design)

Everything below rests on being able to answer three questions about a live
terminal without the shell's cooperation: **where is it, is it busy, and what is
it running?** All four experiments were run against real `vterm` (MELPA build,
`vterm-module.so` compiled against system libvterm 0.3.3) in a real TTY frame
driven through a pty.

| # | Question | Result |
|---|----------|--------|
| 1 | Does `/proc/PID/cwd` track a `cd` typed into vterm? | **Yes.** Terminal started in `/usr`, `cd /etc` → link followed to `/etc` immediately. |
| 2 | Can idle-vs-busy be detected? | **Yes.** `tpgid` from `/proc/PID/stat` equals the shell's own `pgrp` at the prompt, differs while a foreground job runs, and returns on `C-c`. A `&` background job correctly reads as **idle**. |
| 3 | Can the running command be named? | **Yes.** The shell's child whose `pgrp` matches `tpgid` is the foreground job; `/proc/CHILD/comm` gave `sleep`, and `/proc/CHILD/cwd` is available too. |
| 4 | Does `vterm-buffer-name-string` track the title live? | **Yes.** Buffer renamed from `…: /home/…/emacs-tools` to `…: /etc` on `cd`. A second terminal claiming the same title became `…<2>` — Emacs handles collisions. |

Experiment 1 also produced the finding that decides the whole mechanism:
**vterm's own `default-directory` stayed at `/usr/` the entire time.** vterm
tracks directories only when the shell emits the OSC sequences from its
shell-side integration snippet, which was not installed. `/proc` needed no
cooperation at all.

Experiment 4 has a matching caveat: the title is owned by the shell. In the
default bash setup the title escape is embedded in `PS1`, so it is re-set at
every prompt — clearing `PROMPT_COMMAND` did not stop it, and a hand-set title
was overwritten by the next prompt. Titles are therefore useful but not
guaranteed, and never authoritative.

## Mechanism

`/proc` is the source of truth for directory, busy state, and running command.
For each terminal buffer, from `(process-id vterm--process)`:

- **cwd** — resolve the `/proc/PID/cwd` symlink.
- **busy** — parse `/proc/PID/stat` (fields taken *after* the last `)`, since a
  process name may contain spaces and parens): `pgrp` is index 2, `tpgid` is
  index 5. Idle ⇔ `tpgid == pgrp`.
- **running command** — read `/proc/PID/task/PID/children`, keep those whose
  `pgrp` equals `tpgid`, and read their `comm`. A pipeline puts several
  processes in the group; join their names with `|`.

Three to four small file reads per terminal, performed **on demand** — when the
switcher opens, the dashboard refreshes, or a command searches for a match.
Nothing polls in the background.

`default-directory` is used only as a fallback: when the buffer is remote
(TRAMP), where `/proc` describes the local `ssh` client rather than the remote
shell, and on non-Linux platforms. The probe lives behind a single function so
that a macOS implementation (`lsof`/`ps`) is a drop-in.

### Consequence: for a vterm buffer, never trust `default-directory`

Anywhere the code asks "what directory am I in", a vterm buffer must answer with
its probed cwd. Experiment 1 shows `default-directory` is stale. This applies to
the project-scoping in the switcher just as much as to matching.

### Zero persistent state

Every fact is derived from `buffer-list` plus `/proc` at the moment it is
needed. There is no registry, no advice, no `vterm-mode-hook`. Two things fall
out of that:

- **Recency is free.** `buffer-list` is already MRU-ordered, which is exactly
  the tiebreaker the matching rules and the switcher need.
- **`emacs-tools-reload` is a non-event.** Nothing accumulates, so nothing needs
  resetting. `termdex-unload-function` has to cancel the dashboard's refresh
  timer and nothing else.

Buffer names change on every `cd` (experiment 4), so **identity is the buffer
object**, never its name. No lookup may be keyed on a name.

## Commands

### Reaching a terminal

Three commands, one search. The search takes the current directory (probed, per
above) and returns the best matching terminal:

1. terminals whose cwd **is** the current directory;
2. otherwise terminals whose cwd is an **ancestor** of it, nearest first, no
   higher than the project root;
3. ties broken by **strict MRU**.

The project root comes from `project-current`, falling back to the VC root. With
neither, ancestor matching is disabled and only exact matches count — otherwise
a terminal sitting in `$HOME` would match everything.

| Command | Search | If no match |
|---------|--------|-------------|
| `termdex-here` | as above; **matches regardless of busy state** | new terminal |
| `termdex-here-idle` | as above, but a busy terminal is not a match | new terminal |
| `termdex-new` | none | new terminal |

Matching is **global**: a match in another frame or tab is still a match, and
selecting it raises that frame.

### `cd`-on-ancestor-match, and its collision with busy terminals

When `termdex-here` reuses a terminal matched on an *ancestor* directory, it
sends `cd <dir>` so the terminal follows you down. Controlled by
`termdex-cd-on-ancestor-match` (default `t`) — this is the one rule whose feel
is unproven, so it is a switch from the start.

The two answered questions collide here: `termdex-here` reuses busy terminals,
but a busy terminal has no shell prompt to read a `cd`. Typing into it would
feed the string to whatever is running — a REPL, `less`, or a confirmation
prompt. So:

> **`cd` is sent only to an idle terminal.** A busy match is switched to as-is,
> regardless of `termdex-cd-on-ancestor-match`.

Exact matches never need a `cd`. The `cd` goes through `vterm-send-string` and
so lands in shell history; that is accepted rather than worked around, since
suppressing it depends on shell-specific settings (`HISTCONTROL=ignorespace`).

### Switching: `termdex-switch` and `termdex-switch-project`

A `completing-read` over terminal buffers, annotated with cwd, busy state, and
running command. Two commands rather than one with a prefix argument, since both
deserve a key:

- `termdex-switch` — every live terminal.
- `termdex-switch-project` — only terminals whose cwd is inside the current
  project (root resolved as above; outside a project, this degrades to every
  terminal and says so).

**`C-x b` toggling.** The current buffer is excluded from the candidates and the
default is the most recent remaining terminal, so `RET` switches immediately.
Because switching updates MRU order, the buffer you just left becomes the new
default — `RET` again returns, and repeating flips between the two. This is
exactly how `C-x b` behaves, and it needs no special-casing: it is a consequence
of taking the default from `buffer-list`. (When the current buffer is not a
terminal, nothing is excluded and the default is simply the most recent one.)

Plain `completing-read` is used, not `counsel`/`ivy` directly, so the command
adopts whatever completion UI is configured. Annotations are attached via
completion metadata (`affixation-function`), which `vertico`+`marginalia`,
`ivy`, `helm`, and the built-in UI all honour.

Deliberately **not** built: toggling between global and project scope from
inside the minibuffer. Doing that portably means writing per-framework code for
each completion UI. Two bindings cost less and break less.

### Dashboard: `termdex-list`

A `tabulated-list-mode` buffer, one row per terminal:

| Column | Content |
|--------|---------|
| Dir | project-relative where possible, else abbreviated |
| State | idle / busy |
| Process | foreground command, blank when idle |
| Title | the terminal's title, when it is not just a restatement of the cwd |
| Buffer | buffer name |

Keys: `RET` switch, `o` other window, `k` kill (confirming when busy), `+` new
terminal in that row's directory, `g` refresh. Auto-refresh runs on a timer
**only while the buffer is displayed**, and the timer is the one piece of state
`termdex-unload-function` must clean up.

The switcher is likely the command that actually gets used daily and the
dashboard the occasional "what is going on" view, so both are built on the same
collector function. That collector is the real product; the two UIs are thin.

## Buffer naming

Requirement: buffer names match the terminal title. Experiment 4 shows
`vterm-buffer-name-string` already does this, including live updates on `cd`, so
termdex sets it rather than reimplementing it — and documents that the resulting
names are only as good as the shell's `PS1`.

When a terminal has no title, the fallback name is derived from the probed cwd:
`*term project/relative/dir*`. Emacs appends `<2>` on collision (experiment 4),
which is sufficient.

The running command is **not** put in the buffer name. It would churn the name
on every command, which fights `switch-to-buffer` history and any
`display-buffer-alist` rule keyed on a name. The dashboard and the switcher
annotation are where that information belongs.

## Scope

Only `vterm`. But the collector's notion of a terminal is "a buffer with a live
process on a pty", so `eat`, `ansi-term`, and `shell` can be added later by
teaching the probe to find their process — no change to matching, switching, or
the dashboard.

## Testing

Real vterm, per the repo's integration-first rule. `vterm` is now installed into
`.test-env/elpa` from MELPA, with `vterm-module.so` compiled against the system
libvterm; `make deps` gains that step and `run-tests.el` gains
`package-user-dir` + `package-initialize`. Tests `skip-unless` vterm is loadable,
so the suite still runs where it is not.

What gets tested against real terminals:

- **Probe** — start a terminal, `cd`, assert the probed cwd follows; run a
  foreground job, assert busy and the command name; `C-c`, assert idle; `&` a
  job, assert still idle.
- **Matching** — terminals in a known layout of directories; assert exact beats
  ancestor, ancestor stops at the project root, MRU breaks ties, and that
  `termdex-here` takes a busy match where `termdex-here-idle` spawns instead.
- **`cd`-on-match** — assert the reused terminal's probed cwd actually moves,
  and assert a busy terminal is **not** written to.
- **Switcher** — assert the default candidate is the MRU other terminal, and
  that switching twice returns to the start (the toggle).
- **Naming** — assert the buffer name follows the title across a `cd`.

Two mechanics the tests need: a `wait-until` helper polling a predicate with a
timeout (never a fixed `sleep-for` — the probes above needed ~1–2s for a shell
to settle, and a fixed wait is a flaky test), and teardown that kills terminal
buffers with `kill-buffer-query-functions` bound to nil, since a live process
otherwise prompts.

## Reload notes

Per `CLAUDE.md`: `termdex-cd-on-ancestor-match` is a boolean, so a stale value
in a running session is harmless. Any future option carrying *units* must be
introduced under a new name rather than have its meaning changed.
