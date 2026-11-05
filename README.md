# emacs-tools

A small collection of Emacs extensions, installable as a single package.

Each extension lives in its own directory. Loading this repository puts them all
on `load-path`; nothing is loaded until you `require` it.

## Install

Clone the repository and point Emacs at it:

```elisp
(add-to-list 'load-path "/path/to/emacs-tools")
(require 'emacs-tools)
```

`emacs-tools` adds every extension directory to `load-path`, so afterwards:

```elisp
(require 'md-table-wrap)
```

Requires Emacs 31 or newer.

## Packages

### md-table-wrap — Markdown tables, aligned and wrapped to fit the window

`markdown-mode` aligns tables by rewriting the buffer. That is no use in a
read-only buffer, it dirties files you only meant to read, and a table whose
cells hold sentences still runs off the side of the window.

`md-table-wrap` draws every table **as a display presentation**, aligned, and
with each cell word-wrapped inside its column when the table is too wide, so
the whole table fits the window, the way you would hand-align it in a text
file:

```
┌──────────┬─────────────────────────┬───────────┐
│ Approach │ What it does            │ Status    │
╞══════════╪═════════════════════════╪═══════════╡
│ Per-line │ Every cell is drawn as  │ chosen    │
│ anchors  │ a copy in an overlay    │           │
│          │ before-string.          │           │
├──────────┼─────────────────────────┼───────────┤
│ Focus    │ The cell holding point  │ fallback  │
│ cell     │ stays real buffer text. │           │
└──────────┴─────────────────────────┴───────────┘
```

Buffer text stays byte-identical and `buffer-modified-p` stays `nil`: the
buffer still holds one line of Markdown per row. So it works in read-only
buffers — VC revision buffers, `magit` blobs, generated docs — under both
`buffer-read-only` and a `read-only` text property, as chat and transcript UIs
use to lock down what they have already printed.

Column widths are chosen to keep the table short, short label columns stay
unwrapped where that is cheap, and the table re-wraps as you type or resize
the window. Rows of a wrapped table are separated by rules; a table that fits
is just framed. Only the rows near the window are drawn, so a thousand-row
table costs about what a screenful does. Because the table is fitted to the
text area, it stays inside the measure `visual-fill-column-mode` or
`olivetti-mode` gives the prose around it.

```elisp
(require 'md-table-wrap)
(add-hook 'markdown-ts-mode-hook #'md-table-wrap-mode)
;; or
(global-md-table-wrap-mode 1)
```

Tables are found with the tree-sitter `markdown` parser, so fenced code is
never mistaken for one; without a parser a line scan stands in. In practice
that means `markdown-ts-mode`, which ships with Emacs 31 and offers to build its
grammars the first time you open a Markdown file. Emacs does not associate
`.md` with it, and the mode is not autoloaded, so both lines are needed:

```elisp
(require 'markdown-ts-mode)
(add-to-list 'auto-mode-alist '("\\.md\\'" . markdown-ts-mode))
```

| Command | Description |
|:--------|:------------|
| `md-table-wrap-mode` | Buffer-local minor mode. |
| `global-md-table-wrap-mode` | Enables the above in `md-table-wrap-modes`. |
| `md-table-wrap-refresh` | Lay out every table in the buffer again. |

`C-n`/`C-p` move by screen line as the table is drawn: through a wrapped row,
over the rules and the header's separator, keeping the column. On a line
where the column's cell is blank, the cursor waits at the cell's start and
picks the column back up on the next line. `C-a`/`C-e` go to the first and
last text on the screen line, and a click on cell text puts point there.

| Option | Default | Description |
|:-------|:--------|:------------|
| `md-table-wrap-style` | `box` | `box` for box-drawing borders, `ascii` for `\|` and `-`. |
| `md-table-wrap-row-rules` | `t` | Draw a rule between the rows of a wrapped table. |
| `md-table-wrap-modes` | `(markdown-ts-mode)` | Modes `global-md-table-wrap-mode` activates in. |
| `md-table-wrap-word-cap` | `20` | Longest word that may set a column's minimum width. |
| `md-table-wrap-short-column` | `16` | Columns this narrow are labels, kept unwrapped where cheap. |
| `md-table-wrap-mirror-faces` | `t` | Show region, isearch and similar highlights on wrapped text. |

Borders take the `md-table-wrap-border` face (inherits `shadow`).

#### Fonts: mixed-pitch / variable-pitch

Widths are counted in characters of the table's font, so that font must be
fixed-pitch. `markdown-ts-mode` faces tables through `markdown-ts-table` →
`markdown-ts-code-block` → `fixed-pitch`, so under `mixed-pitch-mode` they stay
monospace on their own.

Emacs ships `fixed-pitch` with `:family "Monospace"`, a fontconfig alias
rather than a real family, so unless you override it tables (and code) render
in whatever fontconfig picks. Name a real family:

```elisp
(set-face-attribute 'fixed-pitch nil :family "Source Code Pro")
```

Turning on `mixed-pitch-mode`, `variable-pitch-mode` or `text-scale-adjust`
after a table is drawn re-measures it, so the order modes come on in does not
matter.

With `markdown-ts-hide-markup` (and `md-table-inline-mode`, which lets it
reach cells), cells wrap by the text that shows: a link takes the width of
its text, not its URL, and the cursor steps over hidden markup.

See [md-table-wrap/DESIGN.md](md-table-wrap/DESIGN.md) for how it works.

#### Limitations

- Every column is left-aligned; the `:---:` and `---:` markers in the
  delimiter row are not honoured.
- `C-f`/`C-b`, `M-f`/`M-b`, the region and kill follow the buffer's order,
  which is cell by cell along the row, not screen line by screen line.
- No drag-selecting through wrapped text with the mouse.
- A buffer shown in two windows of different widths fits one of them.

### md-table-inline — inline markup inside table cells

In `markdown-ts-mode`, inline markup inside a pipe table cell is dead text: a
`` `code span` ``, `**emphasis**` or `[link](url)` in a cell gets no face, and
`markdown-ts-toggle-hide-markup` leaves its delimiters visible — the backticks
sit there raw while the same markup outside the table hides correctly.

The cause is in the mode's parser plumbing: it only hands its inline grammar
the `inline` nodes of the block parse, and table cells never produce one. This
mode adds the missing ranges — each cell is parsed by the inline grammar the
same way a paragraph is — and everything downstream (faces, markup hiding,
cleanup) is `markdown-ts-mode`'s own machinery, reused rather than
reimplemented.

Enable per buffer or globally:

```elisp
(require 'md-table-inline)
(add-hook 'markdown-ts-mode-hook #'md-table-inline-mode)
;; or
(global-md-table-inline-mode 1)
```

`md-table-inline-modes` (default `(markdown-ts-mode)`) says where the global
mode applies. It composes with `md-table-wrap`: the cells a wrapped table
draws carry these faces, whichever of the two modes comes on first.

### md-bare-url — make plain URLs in Markdown actually open

A URL written without link syntax does not open in a browser when you press
`RET` on it, while a tagged `[link](url)` on the same line does:

```markdown
See https://example.com/foo for details.   <- RET does nothing useful
See [the docs](https://example.com/foo).   <- RET opens a browser
```

There is no setting for this, and nothing is missing: `markdown-ts-mode`
already buttonizes bare URLs, and `RET` and mouse clicks already reach that
button. It is the destination that is wrong. Deciding whether a match came from
its URL regexp or its email regexp, the mode asks `(eq uri-start 0)` of a
*buffer position* — and buffer positions start at 1, so the test never succeeds
and **every** bare URL is treated as an email address. A bare `https://` URL is
handed to the mail composer instead of `browse-url`, or fails outright with
`Symbol's value as variable is void: url-mail-command`.

`md-bare-url` fixes the destination. Bare URLs then browse, and everything that
already worked — tagged links, `<autolinks>`, and bare email addresses, which
happen to come out right under the bug — is untouched.

```elisp
(require 'md-bare-url)
(md-bare-url-mode 1)
```

`md-bare-url-mode` is global: it works by advising a function, and there is
nothing buffer-local to switch on. There is nothing to customize.

This is a shim against an upstream bug — still present in Emacs master as of
July 2026 — and is meant to be deleted once that bug is fixed. It is written so
that deletion stays cheap: rather than reimplementing bare-URL detection, it
strips the bogus `mailto:` prefix only when what follows carries a URI scheme of
its own, which nothing but the bug can produce. When upstream is fixed the
advice simply stops matching. The test suite pins the bug itself, so it will say
so.

Without it, `M-x goto-address-mode` is a partial workaround: it gives you
working `C-c RET` and `mouse-2`, but plain `RET` keeps hitting the broken
button, since goto-address binds `RET` only in read-only buffers.

See [md-bare-url/DESIGN.md](md-bare-url/DESIGN.md) for the full diagnosis.

### md-file-anchor — follow line and heading anchors on file links

A Markdown link to a file with a line anchor, the kind every forge generates —

```markdown
[builder.py:392–400](../src/builder.py#L392-L400)
```

— does not open `builder.py` in `markdown-ts-mode`. It opens an empty buffer
for a file literally named `builder.py#L392-L400`: the link dispatch has cases
for in-buffer `#fragments`, `mailto:` and URI schemes, but everything else is
handed to `find-file` whole, fragment included.

`md-file-anchor` supplies the missing case. With the mode on, `RET` or a click
on such a link opens the file, jumps to the first anchored line, and briefly
highlights the whole range — the confirmation GitHub gives you. All the forge
anchor shapes work: `#L392`, GitHub's `#L392-L400`, GitLab's `#L392-400`, and
column-carrying permalinks like `#L392C5-L400C10` (columns are ignored). An
anchor that is not a line reference is a heading slug: `[notes](notes.md#slug)`
opens the file and jumps to the heading, resolved by `markdown-ts-mode`'s own
fragment machinery.

The compiler-style line suffix that coding agents write is handled the same
way: `[diagnostics.sql](/home/me/notes/diagnostics.sql:12)` opens
`diagnostics.sql` at line 12, and `file.py:12:5` (column ignored) and
`file.py:392-400` work too. A bare all-lowercase name like `makefile:12` is
the one exception — it reads as a URI scheme, as it does to `markdown-ts-mode`
— but `./makefile:12` or `Makefile:12` opens the file.

```elisp
(require 'md-file-anchor)
(md-file-anchor-mode 1)
```

`md-file-anchor-mode` is global: it works by advising a function, and there is
nothing buffer-local to switch on. There is nothing to customize.

Everything else is untouched: links with a URI scheme keep browsing (a URL's
`#fragment` stays with the URL), in-buffer `#heading` links keep jumping, plain
file links keep opening, and a file whose name really does contain a `#` or a
`:12` suffix — if it exists on disk under that name — still opens verbatim.

See [md-file-anchor/DESIGN.md](md-file-anchor/DESIGN.md) for the details.

### md-heading-scale — size headings by their level

`markdown-mode` has `markdown-header-scaling`, which renders a level-1 heading
large and each level below it a little smaller. `markdown-ts-mode` has no
equivalent — a heading there is told apart only by counting `#` characters.

`md-heading-scale` adds it, and it is a small thing to add: `markdown-ts-mode`
already applies a distinct face per level, `markdown-ts-heading-1` through
`markdown-ts-heading-6`, and then defines all six identically. This package
gives those faces a height.

```elisp
(require 'md-heading-scale)
(add-hook 'markdown-ts-mode-hook #'md-heading-scale-mode)
```

or turn it on everywhere:

```elisp
(global-md-heading-scale-mode 1)
```

| Command | What it does |
|---------|--------------|
| `md-heading-scale-mode` | Buffer-local minor mode; scales this buffer's headings. |
| `global-md-heading-scale-mode` | Enables the above in `md-heading-scale-modes`. |
| `md-heading-scale-refresh` | Re-apply after a plain `setq` of the values below. |

| Option | Default | Description |
|:-------|:--------|:------------|
| `md-heading-scale-values` | `(1.6 1.4 1.25 1.1 1.0 1.0)` | Height multipliers for levels 1–6. |
| `md-heading-scale-modes` | `(markdown-ts-mode)` | Modes `global-md-heading-scale-mode` activates in. |

The default ramp is a little gentler than `markdown-mode`'s, whose level 1 is
twice body size. For exactly what `markdown-header-scaling` looks like:

```elisp
(setopt md-heading-scale-values '(2.0 1.7 1.4 1.1 1.0 1.0))
```

Set the values with `setopt` (or Customize) and every buffer with the mode on
takes them up immediately.

A multiplier of `1` means *leave that level completely alone* — it is not
scaled to 1.0, it is not touched at all. The list may also be short:
`(setopt md-heading-scale-values '(1.6))` enlarges level 1 and nothing else.

#### What it does not do

Sizes are **multipliers**, not fixed sizes, and they are applied as a
buffer-local face remapping rather than by editing the faces:

- `text-scale-adjust`, `mixed-pitch-mode` and a `:height` of your own on the
  `markdown-ts-heading-N` faces all still work, with the ratios between levels
  preserved.
- Switching the mode off restores exactly what was there before. Nothing is
  written over your face customizations, and no other package's remapping is
  disturbed.
- One buffer can be scaled while another is not.

Setext headings (underlined with `===`) follow level 1, since
`markdown-ts-setext-heading` inherits `markdown-ts-heading-1`.

#### Limitations

- **The `#` markers grow with their heading.** `markdown-ts-mode` applies the
  heading face across the whole heading, markers included, and the delimiter
  face it puts on top specifies no height of its own. If large markers bother
  you, `markdown-ts-hide-markup` hides them altogether. The same applies to the
  `======` under a setext heading.
- Nothing is visible on a terminal frame — `:height` needs a graphical display.
- This is for `markdown-ts-mode`. The MELPA `markdown-mode` has its own
  `markdown-header-scaling` already.

See [md-heading-scale/DESIGN.md](md-heading-scale/DESIGN.md) for why remapping
is used rather than `markdown-mode`'s global `set-face-attribute`.

### termdex — reach the right terminal, out of many

With a handful of terminal buffers open, `C-x b` stops helping: buffer names say
nothing about where each terminal is or what it is doing. termdex works with
[vterm](https://github.com/akermu/emacs-libvterm) and
[ghostel](https://github.com/dakra/ghostel); install either or both.

`termdex` treats a terminal as belonging to **wherever it is now**. `cd`
somewhere else and it is a terminal of that directory — it is not tied to the
project it was born in, the way `projectile-run-vterm` and friends tie it.

```elisp
(require 'termdex)
(keymap-global-set "C-c t"   #'termdex-here)
(keymap-global-set "C-c T"   #'termdex-here-idle)
(keymap-global-set "C-c C-t" #'termdex-new)
(keymap-global-set "C-c l"   #'termdex-last)
(keymap-global-set "C-c b"   #'termdex-switch)
(keymap-global-set "C-c B"   #'termdex-switch-project)
```

| Command | What it does |
|---------|--------------|
| `termdex-here` | Go to a terminal for this directory, or make one. Reuses one already here, else the nearest one in a parent directory up to the project root, most recently used first. A busy terminal still counts — this is "take me to the terminal for here", whatever it is doing. |
| `termdex-here-idle` | The same, but something running disqualifies a terminal, so you always arrive at a prompt. |
| `termdex-project-root` | Like `termdex-here`, but for the project root of where you are — "take me to the terminal of this project". Reuses a terminal already at the root, else makes one there. Outside a project it behaves as `termdex-here`. |
| `termdex-project-root-idle` | The same, but you always arrive at a prompt. |
| `termdex-new` | Always a new terminal. |
| `termdex-last` | Back to the last terminal you were in, unconditionally — no directory matching, no prompt, busy or not. From inside a terminal, the most recent *other* one, so repeating it toggles between your two most recent terminals. With no terminal at all it behaves as `termdex-here`. |
| `termdex-switch` | Pick from every terminal, annotated with directory and what it is running. |
| `termdex-switch-project` | The same, restricted to this project. |
| `termdex-list` | A dashboard: every terminal, its directory, whether it is busy, what it is running, and how long it has been quiet. `RET` switch, `o` other window, `k` kill, `+` new terminal there, `g` refresh. |
| `termdex-cleanup-now` | Close every terminal that has gone quiet, without waiting for the timer that normally does it. |

`termdex-switch` toggles the way `C-x b` does: `RET` takes you to the most
recent *other* terminal, and pressing it again brings you back.

Reusing a terminal from a parent directory sends it a `cd` so it follows you
down — set `termdex-cd-on-ancestor-match` to nil to leave it where it stands.
Either way a **busy** terminal is never typed into: it has no prompt to read the
line, which would instead go to whatever is running.

The project root everywhere in termdex comes from Emacs' built-in project.el
(`project-current`). To use projectile's notion of a root instead, plug
projectile into project.el and every termdex command follows:

```elisp
(add-hook 'project-find-functions #'project-projectile)  ; projectile 2.7+
```

Terminals termdex creates are named after the title their shell reports, and
follow it as it changes (`termdex-buffer-name-string`). Terminals started any
other way are left alone.

#### vterm or ghostel

`termdex-backend` picks which kind of terminal termdex makes:

```elisp
(setq termdex-backend 'auto)     ; default: ghostel if installed, else vterm
(setq termdex-backend 'vterm)    ; or pick one
(setq termdex-backend 'ghostel)
```

It only affects what termdex *creates*. Every live vterm and ghostel counts as a
terminal whatever it says, so you can switch backends mid-session without
losing track of the terminals you already have open. ghostel's compilation,
`ghostel-exec` and eshell-visual buffers run a program, not a shell, so they
are not counted as terminals.

#### A count in the mode line

```elisp
(termdex-indicator-mode 1)
```

Puts `💻 3` in every mode line — how many terminals are open right now.
`mouse-1` on it opens the `termdex-list` dashboard. With no terminals the
indicator disappears entirely, and excluded terminals (below) are not counted,
so the number is always the population `termdex-switch` would offer.

The glyph is `termdex-indicator-glyph`: set it to plain ASCII (`">_"`) for a
TTY whose fonts cannot show the emoji, or to a terminal icon of your choice
with a Nerd Font installed.

#### Closing terminals that have gone quiet

On by default. A terminal that has done nothing for half an hour is closed, so a
long-running Emacs does not silt up with shells sitting at a prompt in
directories you stopped working in days ago.

```elisp
(setq termdex-cleanup-idle-seconds (* 2 60 60))  ; two hours instead
(setq termdex-cleanup-idle-seconds nil)          ; or never close anything
(termdex-cleanup-mode -1)                        ; same, by switching it off
```

A terminal is never closed while it is **busy**, while its shell has a
**background job** (`sleep 60 &` leaves a prompt, so it looks idle — but killing
the buffer would take the job with it), while it is **displayed** in any window
of any frame, or when it is **remote**, since nothing local can tell what a
shell across an `ssh` is doing. Excluded terminals (below) are never touched at
all. Anything that protects a terminal also restarts its clock: a job that ran
for two hours leaves the terminal idle from when it *finished*.

Every terminal that gets closed says so in the echo area, because there is one
case termdex cannot see: a shell blocked in a builtin such as `read` — sitting
at an unanswered prompt of its own — looks idle to `/proc`, and can be closed.

The sweep runs from an idle timer, so it never interrupts your typing, and at
most once a minute. `M-x termdex-cleanup-now` runs one immediately.

`M-x termdex-list` shows where each terminal stands, in its **Quiet** column:

```
~/projects/emacs-tools   idle             12m 03s   *term emacs-tools*
~/projects/emacs-tools   busy    sleep    busy      *term sleep*
~/src/kernel             idle             jobs      *term kernel*
~/notes                  idle             -         *term notes*
```

Either how long it has been quiet, or why that question does not apply: `busy`,
`jobs` (a background job), `shown` (displayed somewhere), `remote`, `excluded` —
or `-` for a terminal no sweep has stamped yet. **After loading or reloading
termdex, every terminal reads `-`**: the clock lives on the buffer and starts at
the first sweep that sees it, so existing terminals get a fresh idle period
rather than being closed immediately. Sort by the column with `S` to bring the
stalest to the top.

#### Excluding terminals someone else drives

A coding agent's session terminal, a build console, a REPL in its own window —
these are ordinary terminals in your project directory, so every rule above matches
them, and `termdex-here` will happily walk you into one looking for a shell
prompt.

Whatever creates such a terminal can mark it with one line:

```elisp
(setq-local termdex-exclude t)
```

For terminals you do not create yourself, add a predicate instead:

```elisp
(add-to-list 'termdex-exclude-functions
             (lambda (buffer)
               (with-current-buffer buffer
                 (bound-and-true-p some-package-session-terminal-p))))
```

Use `bound-and-true-p`, not `buffer-local-value`: a predicate that signals takes
every termdex command down with it, since they all begin by listing terminals.
If the package defining that variable is autoloaded, it is void until something
first loads it — which is exactly the state a fresh Emacs is in.

Excluded terminals keep working normally — they are only left out of matching
and switching. `C-u M-x termdex-list` shows them, and a command run from inside
one still starts from that terminal's directory.

#### Requirements

[`vterm`](https://github.com/akermu/emacs-libvterm) or
[`ghostel`](https://github.com/dakra/ghostel), and Linux: a terminal's
directory, busy state, and running command are read from `/proc`. That needs no
cooperation from your shell — no rc snippet — and it keeps working inside a
`sudo -i`, an `ssh`, or any other shell started within a terminal, where
`default-directory` silently stops moving. Where the terminal's own shell-side
integration (vterm's `vterm_prompt_end`, ghostel's OSC 7) reports a genuinely
remote directory, that is used instead, since `/proc` can only see the local
`ssh` client.

See [termdex/DESIGN.md](termdex/DESIGN.md) for how a terminal's current shell is
identified, and for what it cannot see (a shell blocked in a builtin such as
`read` looks idle).

## Development

```sh
make deps      # build the tree-sitter grammars, install vterm and ghostel for the tests
make test      # run the test suite
make compile   # byte-compile, warnings are errors
```

`make deps` also installs `vterm` and `ghostel` into `.test-env/elpa`, since
termdex's tests drive real terminals, each one on both backends. vterm compiles
a C module, so it needs cmake, a compiler and libvterm's headers. ghostel
downloads a prebuilt module from its GitHub releases, so it needs network
access. Whichever backend is missing, its termdex tests skip themselves rather
than failing the run.

### Reloading in a live session

```
M-x emacs-tools-reload         ; one extension, completing over what is loaded
M-x emacs-tools-reload-all     ; every loaded extension
M-x emacs-tools-reload-loader  ; this loader itself, after editing emacs-tools.el
```

Use these rather than `load-file` while iterating. `load` on its own does not
give you a clean slate:

- `defvar` and `defcustom` **do not reassign a variable that is already
  bound**, so a changed default silently keeps its old value — and if the
  meaning of that variable changed too, the stale value gets reinterpreted
  rather than rejected;
- overlays, hooks and `jit-lock` registrations from the previous definition
  survive;
- a stale `.elc` shadows the `.el` you just edited.

`emacs-tools-reload` unloads the feature first, which unbinds everything its
file defined, then loads the `.el` path explicitly. Minor modes that are
switched on are turned off beforehand and back on afterwards, so their buffers
are rebuilt by the new code. Hook registrations survive: `unload-feature`
strips a feature's functions from every hook, which is right when a feature is
going away for good and wrong when it is coming straight back, so they are
recorded beforehand and put back — with their depth, so an appended entry stays
appended.

The loader cannot unload itself — that would remove the functions doing the
unloading — so `emacs-tools-reload-loader` plainly `load`s `emacs-tools.el`
instead. That is enough here: the file defines no `defcustom` and no stateful
`defvar`, its functions are simply redefined, and its `load-path` setup is
idempotent. Use it after editing `emacs-tools.el`, or a stale
`emacs-tools-reload` will keep quietly doing the old thing.

Extensions can hook the unload by defining `FEATURE-unload-function`, which
`unload-feature` calls before stripping definitions; `md-table-wrap` uses it
to switch itself off everywhere so no overlay outlives its code, `md-bare-url`
to make sure no advice outlives the function it names, and `md-heading-scale`
so no buffer is left scaled by a remapping nothing can now remove.

Tests assert on what the redisplay engine actually drew — screen lines,
rendered positions and the strings it lays out — so they need a real frame. `make test` runs Emacs
under a pty to get a TTY frame; batch mode has no frame that lays text out.

## Repository layout

```
emacs-tools.el          collection loader; adds each extension to load-path
md-table-wrap/          extension: display-only Markdown tables, wrapped to fit
md-table-inline/        extension: inline markup inside Markdown table cells
md-bare-url/            extension: make bare URLs in Markdown follow
md-file-anchor/         extension: follow line/heading anchors on file links
md-heading-scale/       extension: size Markdown headings by their level
termdex/                extension: directory-aware handling for many terminals
docs/                   cross-session working notes: questions and findings
tests/                  test suite and TTY test runner
```
