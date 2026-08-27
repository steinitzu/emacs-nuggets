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
| 5 | Do 1–3 survive a **nested shell** (`sudo -i`, `ssh`, plain `bash`)? | **Only with the descendant walk below.** Reading the pty leader alone, a nested shell makes the terminal read permanently busy and freezes its cwd at the outer shell's. |

Experiment 1 also produced the finding that shapes the mechanism: **vterm's own
`default-directory` stayed at `/usr/` the entire time**, because that Emacs ran a
shell with no `vterm_prompt_end` snippet in its rc. `/proc` needed no
cooperation at all. Experiment 5 is the sharper version of the same point — the
snippet lives in *one* rc file, so a `sudo -i`, an `ssh`, a container, or a
`bash --norc` inside the terminal is unreachable by it even on a machine where
it is installed.

Experiment 4 has a matching caveat: the title is owned by the shell. In the
default bash setup the title escape is embedded in `PS1`, so it is re-set at
every prompt — clearing `PROMPT_COMMAND` did not stop it, and a hand-set title
was overwritten by the next prompt. Titles are therefore useful but not
guaranteed, and never authoritative.

## Mechanism

`/proc` is the source of truth for directory, busy state, and running command.
The question it answers is asked not of the pty leader but of the terminal's
**current shell**, which experiment 5 shows are not the same process.

### Finding the current shell

From the pty leader `(process-id vterm--process)`, read `tpgid` — the process
group that owns the terminal. Then walk the descendant tree from the leader
towards that group, and take the **deepest process on the path whose `comm` is a
shell** (`bash`, `zsh`, `sh`, `dash`, `fish`), defaulting to the leader.

The walk stops descending once it reaches the foreground group, which is what
keeps it honest in both directions: a nested `bash` is followed, but `make`
spawning `cc` is not — `cc` is inside the foreground group, so the walk never
looks at it and the answer stays the shell that launched `make`.

Depth is capped (32) so a pathological process tree cannot hang redisplay.

**Being named `bash` is not enough** (added during implementation). A shell
script's process is also called `bash` — that is what a `#!` line runs — and so
is `bash -c`. Descending into one would report a running script as an idle
prompt for as long as it ran, which is exactly backwards, and would make
`termdex-here-idle` walk you into a busy terminal. The extra test is the command
line: an interactive shell is invoked with options only, while a script or a
command string means a non-option argument, or `-c`.

### Known limitation: blocking builtins read as idle

A shell blocked in a *builtin* — `read`, `wait`, `select` — forks nothing, so
its process group still owns the terminal and it reads as idle. There is no
process to see, and short of shell-side integration there is nothing to detect.
Accepted: the case is rare, and the failure is mild (`termdex-here-idle` walks
you into a shell waiting on `read` rather than opening a new one).

This surfaced from a test written on the assumption that `read answer` would
make a terminal busy. It does not.

### The three facts

Of that shell's pid:

- **cwd** — resolve the `/proc/PID/cwd` symlink.
- **busy** — parse `/proc/PID/stat`, taking fields *after* the last `)` since a
  process name may contain spaces and parens: `pgrp` is index 2, `tpgid` is
  index 5. Idle ⇔ the shell's own `pgrp` equals the leader's `tpgid`, i.e. the
  shell is itself the foreground group.
- **running command** — the processes whose `pgrp` is that group, by `comm`. A
  pipeline puts several there; join their names with `|`.

A handful of small file reads per terminal, performed **on demand** — when the
switcher opens, the dashboard refreshes, or a command searches for a match.
Nothing polls in the background.

### Relationship to vterm's shell-side integration

`vterm_prompt_end` in a shell rc emits `OSC 51;A user@host:pwd` at every prompt,
and vterm's `vterm--set-directory` turns that into `default-directory` — a TRAMP
path when the host is not local. Where it is installed it is authoritative and
it reaches somewhere `/proc` cannot: a shell on the far side of an `ssh`, whose
cwd is not a local path at all.

It also gives *only* the directory. Busy state and the running command — half of
what this extension needs — have no OSC equivalent, so `/proc` is required
regardless. Hence:

> **Remote `default-directory` wins; otherwise `/proc`.** If a buffer's
> `default-directory` is remote, trust it and mark the terminal's busy state
> unknown. Otherwise use the walk above, which is correct whether or not the
> snippet is installed, and stays correct through a nested shell where the
> snippet is not loaded (experiment 5).

The probe lives behind a single function so a macOS implementation
(`lsof`/`ps`) is a drop-in.

### Consequence: for a local vterm buffer, never trust `default-directory`

Anywhere the code asks "what directory am I in", a local vterm buffer must
answer with its probed cwd — including the project-scoping in the switcher, not
just matching. Even with the snippet installed, `default-directory` is stale
inside any shell that did not load it (experiment 5).

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
| `termdex-project-root` | as `termdex-here`, from the **project root** | new terminal at the root |
| `termdex-project-root-idle` | as above, but a busy terminal is not a match | new terminal at the root |
| `termdex-new` | none | new terminal |

Matching is **global**: a match in another frame or tab is still a match, and
selecting it raises that frame.

### `termdex-project-root`: the root as the target, not just the ceiling

Added after first use. `termdex-here` treats the project root as a *ceiling for
reuse* — the target is always the exact directory you are in, so run from a
subdirectory with no matching terminal, it spawns one *there*. Often the
terminal you want is "the terminal of this project", which lives at the root.

`termdex-project-root` and `termdex-project-root-idle` are `termdex-here` /
`termdex-here-idle` with one change: the directory searched for is the project
root of where you are. Everything else is the same search, and the pieces
compose without new rules:

- A terminal already at the root is an **exact match**, so no `cd` is sent and
  it stays put.
- A terminal *below* the root is not a match — its directory is not a prefix of
  the root — so asking for the root never grabs a terminal that has descended
  into a subdirectory.
- **Outside a project the commands degrade to `termdex-here`.** You asked for a
  terminal for this project; with no project, the honest answer is "for here".

The root comes from `termdex--project-root` — the same `project-current`-based
function the matcher's ceiling uses. Deliberately **not** `projectile`: two
definitions of "the root" inside one package can disagree (projectile
recognises more markers), and then the command would open a terminal at a
directory the matcher does not consider the root. A projectile user gets
projectile's answer everywhere at once by plugging it into project.el:

```elisp
(add-hook 'project-find-functions #'project-projectile)  ; projectile 2.7+
```

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

### Terminals termdex should leave alone

Added after first use. A terminal someone else drives — a coding agent's session
terminal, a build console, a REPL that lives in its own window — sits in your
project directory and is a perfectly ordinary vterm, so every rule above matches
it. `termdex-here` then walks you into it looking for a shell prompt, which is
not what anyone wanted.

Two ways to say so, because there are two situations:

- `termdex-exclude`, a buffer-local variable, for a terminal whose creator can
  mark it. One `setq-local` and termdex needs to know nothing about the package
  that set it.
- `termdex-exclude-functions`, a list of predicates on a buffer, for terminals
  you do not create yourself. This keeps knowledge of other packages in the
  user's configuration rather than in termdex.

**Exclusion applies to candidacy, not to sensing.** `termdex--vterm-buffer-p`
asks whether a buffer is a terminal at all and `termdex--candidate-p` whether
termdex may send you to one; only the second consults the exclusions. An
excluded terminal is still probed for its directory, so `termdex-here` run from
*inside* one starts from where that terminal actually is. Folding exclusion into
the first predicate instead would have fallen back to `default-directory` — the
one value that is reliably wrong (experiment 1).

`termdex-list` takes a prefix argument to show excluded terminals too, since the
dashboard's job is an overview of everything rather than of what termdex will
send you to.

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

### `termdex-last`: the last touched terminal, unconditionally

Added after first use. Every reaching command answers a question first — which
directory, which project, busy or not — and `termdex-switch` asks *you* one.
Sometimes the want is simpler than any of them: "put me back in the terminal I
was just using", with no matching, no prompt, and no regard for what it is
doing. That is a one-keystroke jump, and none of the existing commands is it —
`termdex-switch` is two keystrokes and a minibuffer flash, `termdex-here` can
land somewhere else entirely (or spawn) when you have wandered out of the
terminal's directory.

`termdex-last` goes to the most recently used candidate terminal, full stop:

- **No probing.** The command needs neither directory nor busy state, so it
  never touches `/proc` — the answer is `buffer-list` order filtered through
  `termdex--candidate-p`, the same population every other command acts on.
  Exclusions still apply: an agent's terminal is not "the terminal you were
  just using" in the intended sense, however recently its buffer was current.
- **From inside a terminal, the most recent *other* one.** The last touched
  terminal is then the one you are in, and jumping to it is a no-op; skipping
  it makes repeated invocations toggle between your two most recent terminals,
  the same behaviour `termdex-switch`'s `RET` `RET` gives — for free, since
  switching updates MRU order.
- **No terminal means an error, not a spawn.** The command's contract is a
  jump to something that exists; quietly creating a terminal would mean
  choosing a directory, which is exactly the question this command exists to
  not ask. `termdex-here` and `termdex-new` are the creating commands.

### Dashboard: `termdex-list`

A `tabulated-list-mode` buffer, one row per terminal:

| Column | Content |
|--------|---------|
| Directory | abbreviated (`~/…`) |
| State | idle / busy / remote |
| Process | foreground command, blank when idle |
| Buffer | buffer name |

*(Deviation: a separate Title column was dropped during implementation. The
buffer name **is** the title wherever the shell sets one, so the column would
have restated its neighbour in every row.)*

Keys: `RET` switch, `o` other window, `k` kill (confirming when busy), `+` new
terminal in that row's directory, `g` refresh. Auto-refresh runs on a timer
**only while the buffer is displayed**, and the timer is the one piece of state
`termdex-unload-function` must clean up.

The switcher is likely the command that actually gets used daily and the
dashboard the occasional "what is going on" view, so both are built on the same
collector function. That collector is the real product; the two UIs are thin.

### Mode-line indicator: `termdex-indicator-mode`

A global minor mode putting a small element in every mode line — a glyph and
the number of live terminals — as a standing answer to "how many terminals do
I have open?". `mouse-1` on it opens `termdex-list`; the indicator is the
door to the dashboard, not a dashboard itself.

The element lives in `global-mode-string` (rendered by `mode-line-misc-info`),
which is the standard slot for exactly this kind of thing (`display-time`,
battery). It is an `:eval` construct, recomputed at every mode-line redisplay
of every window, which forces the one hard rule:

> **Nothing at redisplay may touch `/proc`.** A count needs only `buffer-list`
> and `termdex--candidate-p` — major mode, live process, exclusions — which is
> cheap enough to run per redisplay. Probing is not, and is never done here.

Three decisions fall out of that rule and the indicator's job:

- **It shows how many, not how busy.** Busy state comes from `/proc`, so
  showing it would mean either probing at redisplay (forbidden above) or a
  background polling timer (state the package otherwise avoids, burning CPU
  for a glyph). Deliberately not built: busy-ness is one click away in the
  dashboard.
- **It counts candidates** — the population every other command acts on and
  `termdex-list` shows by default. An excluded terminal (an agent's session,
  a build console) is not a terminal termdex will send you to, so it is not
  in the count. Consequence: `termdex-exclude-functions` predicates run at
  redisplay for each vterm buffer. They already had to be cheap and
  non-signalling — every command starts by filtering through them — so this
  tightens an existing requirement rather than adding one.
- **Zero terminals shows nothing.** An indicator reading "0" is permanent
  mode-line clutter for the sessions that never open a terminal; absence
  carries the same information.

The glyph is `termdex-indicator-glyph`, default `💻` (U+1F4BB). The first
default was ASCII `>_` for universality; changed by owner decision — Unicode
has no "screen with a prompt" character (that is Nerd Font iconography), and
the laptop emoji is the closest thing that ordinary emoji fonts carry. The
option is the escape hatch: plain ASCII for a TTY whose fonts cannot show
it, or a Nerd Font terminal icon for those who have one.

State: the mode adds one risky-marked symbol to `global-mode-string` and
removes it when disabled; there is no cache, timer, or hook, so the count can
never be stale. `termdex-unload-function` turns the mode off so unloading
does not strand a construct whose function is about to be unbound.

**Found in live use, missed by the first tests: the construct symbol must
never be `global-mode-string`'s first element.** The renderer reads a list
whose car is a symbol as the conditional construct `(SYMBOL THEN ELSE)`, and
with no THEN branch that is malformed — the whole element displays as
`*invalid*`. In a session where nothing else has claimed `global-mode-string`
its value is nil, so a bare `add-to-list` produced exactly that
symbol-headed list. The fix is `display-time-mode`'s own: seed
`global-mode-string` with `("")` before appending, so the list's car is
always a string and the renderer iterates it as a plain list. The first
tests missed this by rendering a hand-built `("" construct)` — accidentally
the fixed shape — where they now render `global-mode-string` itself,
starting from nil, through the same `format-mode-line` pipeline redisplay
uses.

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
- **Nested shells** — run `bash --norc` inside a terminal, `cd`, and assert the
  probed cwd and idle state follow the *inner* shell (experiment 5); assert a
  non-shell child (`make`-like: a foreground process spawning its own children)
  does **not** move the answer off the outer shell.
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

Two things learned writing them, both about testing *negatives*:

- Waiting out the full timeout to prove nothing happened made a single test 15
  of the suite's 19 seconds. Negative assertions get one shell round trip
  instead — the same wait the positive tests show is comfortably enough.
- `bash -c 'sleep 60'` tests nothing: bash execs a lone command in place, so no
  bash process remains to be mistaken for an interactive one. It needs a second
  command (`bash -c 'sleep 60; :'`) before there is anything to get wrong.

### A running command can briefly be named after the shell

Found later, chasing a test that failed about one run in three with `bash`
where it expected `sleep`.

`execve` installs the new program's argument vector **before** it updates the
process name, so /proc reports the two inconsistently for a moment: command
line `sleep 60`, name `bash`. Measured directly — forking and sampling
`/proc/PID/comm` against `/proc/PID/cmdline` caught the window on 5 of 4000
execs, and a probe polling as hard as the tests do lands in it far more often
than that.

Inside that window the probe does something defensible and wrong-looking:
`termdex--interactive-shell-p` sees the non-option argument `60` and declines to
call the child a shell you could type at — which is the right call for
`bash -c`, and here means the answer falls back to the shell above, whose child
/proc will only name `bash`. So `termdex-list` can, for a few microseconds,
show a terminal as running `bash`.

Nothing outside the kernel can close that window, and no user can see it: the
next refresh is correct. Reading both files "at once" is not available, and
re-reading to confirm would slow every probe to fix an artefact nobody
perceives. So the probe is left alone and the **tests** wait for the command
they asked for rather than the first busy reading — `termdex-tests--busy` takes
an optional expected command, and returns the last thing it saw if that never
arrives, so a genuine wrong answer still fails and still says what it was.

Final state: 21 termdex tests, all against real terminals, ~8s for the whole
collection's suite.

## Reload notes

Per `CLAUDE.md`: `termdex-cd-on-ancestor-match` is a boolean, so a stale value
in a running session is harmless. Any future option carrying *units* must be
introduced under a new name rather than have its meaning changed.
