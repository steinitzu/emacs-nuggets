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

## Development

```sh
make deps      # build the tree-sitter grammars the tests need
make test      # run the test suite
make compile   # byte-compile, warnings are errors
```

### Reloading in a live session

```
M-x emacs-tools-reload       ; one extension, completing over what is loaded
M-x emacs-tools-reload-all   ; every loaded extension
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
are rebuilt by the new code. The loader itself is deliberately not reloadable —
unloading `emacs-tools` would remove the functions doing the unloading.

Extensions can hook the unload by defining `FEATURE-unload-function`, which
`unload-feature` calls before stripping definitions; `md-table-align` uses it
to switch itself off everywhere so no overlay outlives its code, and
`md-bare-url` to make sure no advice outlives the function it names.

Tests assert on what the redisplay engine actually drew — they read back rendered
columns with `posn-at-point` — so they need a real frame. `make test` runs Emacs
under a pty to get a TTY frame; batch mode has no frame that lays text out.

## Repository layout

```
emacs-tools.el          collection loader; adds each extension to load-path
md-table-align/         extension: display-only Markdown table alignment
md-bare-url/            extension: make bare URLs in Markdown follow
tests/                  test suite and TTY test runner
```
