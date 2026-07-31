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
(require 'md-table-align)
```

Requires Emacs 31 or newer.

## Packages

### md-table-align — align Markdown tables without touching the buffer

`markdown-mode` aligns tables by rewriting the buffer. That is no use in a
read-only buffer, and it dirties files you only meant to read.

`md-table-align` aligns tables **as a display presentation**. Buffer text stays
byte-identical, `buffer-modified-p` stays `nil`, and it works when the buffer is
read-only — VC revision buffers, `magit` blobs, generated docs, archives. That
covers both ways a buffer can be read-only: `buffer-read-only`, and a `read-only`
text property over part of the text, as chat and transcript UIs use to lock down
what they have already printed.

Given a file containing:

```markdown
| Package | Version | Status |
|:--------|--------:|:------:|
| md-table-align | 0.1.0 | ready |
| emacs-tools | 0.1.0 | ready |
| some-other-thing | 12.4 | wip |
```

it renders as:

```
| Package          | Version | Status |
|:-----------------|--------:|:------:|
| md-table-align   |   0.1.0 | ready  |
| emacs-tools      |   0.1.0 | ready  |
| some-other-thing |    12.4 |  wip   |
```

while the file on disk — and the buffer text — is unchanged. Per-column
alignment markers (`:---`, `---:`, `:---:`) are honoured, and cell widths are
measured by display width so CJK text lines up correctly.

#### Requirements

Table discovery uses tree-sitter, so the buffer needs a `markdown` parser — in
practice `markdown-ts-mode`, which ships with Emacs 31. There are no grammars
to install by hand: loading the library registers the grammar sources itself
(pinned to a known-good commit), and the mode calls `treesit-ensure-installed`,
so Emacs offers to build them the first time you open a Markdown file.
`treesit-auto-install-grammar` defaults to `ask`; set it to `always` if you
would rather not be prompted.

Emacs does not associate `.md` with `markdown-ts-mode`, and the mode is not
autoloaded, so both lines are needed:

```elisp
(require 'markdown-ts-mode)
(add-to-list 'auto-mode-alist '("\\.md\\'" . markdown-ts-mode))
```

The MELPA `markdown-mode` package is not supported — it has no tree-sitter
parser. If the mode is enabled where no `markdown` parser exists it declines,
with a message, rather than misbehaving.

#### Usage

```elisp
(add-hook 'markdown-ts-mode-hook #'md-table-align-mode)
```

or turn it on everywhere:

```elisp
(global-md-table-align-mode 1)
```

Commands:

| Command | Description |
|:--------|:------------|
| `md-table-align-mode` | Buffer-local minor mode; keeps tables aligned as you scroll and edit. |
| `global-md-table-align-mode` | Enables the above in `md-table-align-modes`. |
| `md-table-align-buffer` | Align every table once, right now. |
| `md-table-align-clear` | Remove all alignment from the buffer. |
| `md-table-align-hscroll-left` | Scroll the table at point left; bound over `C-x <` (`scroll-left`). |
| `md-table-align-hscroll-right` | Scroll the table at point right; bound over `C-x >` (`scroll-right`). |
| `md-table-align-hscroll-reset` | Return the scrolled table to its left edge. |

Customization:

| Option | Default | Description |
|:-------|:--------|:------------|
| `md-table-align-padding` | `1` | Spaces rendered between a cell border and its content. |
| `md-table-align-pixel-width-function` | `md-table-align-pixel-width` | Measures a cell's rendered width, in pixels. |
| `md-table-align-modes` | `(markdown-ts-mode)` | Modes `global-md-table-align-mode` activates in. |
| `md-table-align-hscroll` | `t` | Clip wide tables to the window and scroll them sideways. |
| `md-table-align-ellipsis` | `…` | Marks where the window's edge has clipped a table. |
| `md-table-align-hscroll-indicator` | `t` | Whether to mark clipped edges at all. |

#### Wide tables and word wrap

Under `visual-line-mode` a table wider than the window wraps, and a wrapped
table is not just ugly — the continuation lines restart at the window's left
edge, so the alignment is gone entirely.

Emacs has no way to switch wrapping off for part of a buffer, so
`md-table-align` clips each table to a horizontal viewport instead, and lets
you scroll it. A table needing 48 columns, shown in a 40-column window:

```
| Name  | Description…
|-------|-----------------------------…
| alpha | first item description here…
| beta  | second item description…
```

Scroll it and the rest arrives, with the columns still on their grid:

```
…Description                 | Status |
…----------------------------|--------|
…first item description here | open   |
…second item description     | done   |
```

Scrolling works the way it already does in a `truncate-lines` buffer, so there
is nothing new to learn:

- **The viewport follows point.** Move onto a cell that is off screen and the
  table scrolls to it, honouring `hscroll-margin` and `hscroll-step` exactly as
  `auto-hscroll-mode` does. Most of the time you never scroll by hand at all.
- **`C-x <` and `C-x >`** scroll the table at point explicitly. Outside a table
  they do what they always did.
- Only the table moves. Prose above and below it stays where it is, which is
  something native horizontal scrolling cannot do — it shifts the whole window,
  and needs `truncate-lines` to work at all.

Only the table you are in is ever scrolled, and it returns to its left edge
when you leave it. Widen the window and the whole table comes back on its own.

Clipped text is also readable without scrolling: put point on it and press
`C-h .` (`display-local-help`), or hover the mouse over it.

Set `md-table-align-hscroll` to `nil` to turn this off and let wide tables
wrap as before.

#### How it works

Each cell gets an overlay whose `before-string` or `display` property is a
stretch glyph — `(space :align-to COLUMN)` — which the redisplay engine expands
to push the following text onto a grid. Overlays never modify buffer text and
never mark a buffer modified, which is what makes read-only buffers work.

See [md-table-align/DESIGN.md](md-table-align/DESIGN.md) for the reasoning,
including why overlays are used rather than text properties.

#### Using it with mixed-pitch / variable-pitch

`markdown-ts-mode` faces tables through
`markdown-ts-table` → `markdown-ts-code-block` → `fixed-pitch`, so under
`mixed-pitch-mode` they stay monospace on their own — no need to add anything to
`mixed-pitch-fixed-pitch-faces`.

There is one catch. Emacs ships `fixed-pitch` with `:family "Monospace"`, which
is a generic fontconfig alias rather than a real family. If you never override
it, your tables (and code blocks, and inline code) render in whatever fontconfig
picks — commonly DejaVu Sans Mono — instead of your coding font. Name a real
family:

```elisp
(set-face-attribute 'fixed-pitch nil :family "Source Code Pro")
```

Alignment itself needs no configuration under mixed-pitch. Cells are measured
in pixels with `string-pixel-width` against the buffer, so the layout follows
whatever the text really renders as — including face remapping and font
fallback — rather than assuming one character occupies one canonical character
width. That assumption is wrong under `mixed-pitch-mode`, where the table face
inherits the remapped default's `:height` and renders wider per character than
`frame-char-width` reports.

The order the two modes are switched on does not matter. Turning on
`mixed-pitch-mode`, `variable-pitch-mode` or `text-scale-adjust` after a table
has been laid out re-measures it, so you can enable them in either order and
from any hook.

#### Limitations

- The delimiter row (`|:---|---:|`) renders as a run of dash characters, so its
  width is quantised to whole characters. Its closing border is pinned exactly;
  any sub-character shortfall shows as a small gap before it.
- A table shown in two differently sized windows at once is laid out for
  whichever window you are in, so it is only correct in one of them at a time.
- Only one table carries a scroll offset at a time — the one point is in.
  Leaving it puts it back to its left edge.
- The first column does not stay pinned while the rest scrolls, so a scrolled
  row loses its row label.
- A window with no room for even a couple of characters of table is left to
  wrap, on the grounds that clipping it to nothing would be worse.

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

With a handful of `vterm` buffers open, `C-x b` stops helping: buffer names say
nothing about where each terminal is or what it is doing.

`termdex` treats a terminal as belonging to **wherever it is now**. `cd`
somewhere else and it is a terminal of that directory — it is not tied to the
project it was born in, the way `projectile-run-vterm` and friends tie it.

```elisp
(require 'termdex)
(keymap-global-set "C-c t"   #'termdex-here)
(keymap-global-set "C-c T"   #'termdex-here-idle)
(keymap-global-set "C-c C-t" #'termdex-new)
(keymap-global-set "C-c b"   #'termdex-switch)
(keymap-global-set "C-c B"   #'termdex-switch-project)
```

| Command | What it does |
|---------|--------------|
| `termdex-here` | Go to a terminal for this directory, or make one. Reuses one already here, else the nearest one in a parent directory up to the project root, most recently used first. A busy terminal still counts — this is "take me to the terminal for here", whatever it is doing. |
| `termdex-here-idle` | The same, but something running disqualifies a terminal, so you always arrive at a prompt. |
| `termdex-new` | Always a new terminal. |
| `termdex-switch` | Pick from every terminal, annotated with directory and what it is running. |
| `termdex-switch-project` | The same, restricted to this project. |
| `termdex-list` | A dashboard: every terminal, its directory, whether it is busy, and what it is running. `RET` switch, `o` other window, `k` kill, `+` new terminal there, `g` refresh. |

`termdex-switch` toggles the way `C-x b` does: `RET` takes you to the most
recent *other* terminal, and pressing it again brings you back.

Reusing a terminal from a parent directory sends it a `cd` so it follows you
down — set `termdex-cd-on-ancestor-match` to nil to leave it where it stands.
Either way a **busy** terminal is never typed into: it has no prompt to read the
line, which would instead go to whatever is running.

Terminals termdex creates are named after the title their shell reports, and
follow it as it changes (`termdex-buffer-name-string`). Terminals started any
other way are left alone.

#### Excluding terminals someone else drives

A coding agent's session terminal, a build console, a REPL in its own window —
these are ordinary vterms in your project directory, so every rule above matches
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

[`vterm`](https://github.com/akermu/emacs-libvterm), and Linux: a terminal's
directory, busy state, and running command are read from `/proc`. That needs no
cooperation from your shell — no rc snippet — and it keeps working inside a
`sudo -i`, an `ssh`, or any other shell started within a terminal, where
`default-directory` silently stops moving. Where you *do* have vterm's
shell-side integration and a genuinely remote directory, that is used instead,
since `/proc` can only see the local `ssh` client.

See [termdex/DESIGN.md](termdex/DESIGN.md) for how a terminal's current shell is
identified, and for what it cannot see (a shell blocked in a builtin such as
`read` looks idle).

## Development

```sh
make deps      # build the tree-sitter grammars and install vterm for the tests
make test      # run the test suite
make compile   # byte-compile, warnings are errors
```

`make deps` also installs `vterm` into `.test-env/elpa`, since termdex's tests
drive real terminals. It compiles a C module, so it needs cmake, a compiler and
libvterm's headers; without them the build is skipped and the termdex tests skip
themselves rather than failing the run.

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
`unload-feature` calls before stripping definitions; `md-table-align` uses it
to switch itself off everywhere so no overlay outlives its code, `md-bare-url`
to make sure no advice outlives the function it names, and `md-heading-scale`
so no buffer is left scaled by a remapping nothing can now remove.

Tests assert on what the redisplay engine actually drew — they read back rendered
columns with `posn-at-point` — so they need a real frame. `make test` runs Emacs
under a pty to get a TTY frame; batch mode has no frame that lays text out.

## Repository layout

```
emacs-tools.el          collection loader; adds each extension to load-path
md-table-align/         extension: display-only Markdown table alignment
md-bare-url/            extension: make bare URLs in Markdown follow
md-heading-scale/       extension: size Markdown headings by their level
termdex/                extension: directory-aware handling for many vterms
tests/                  test suite and TTY test runner
```
