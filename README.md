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
read-only — VC revision buffers, `magit` blobs, generated docs, archives.

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

Customization:

| Option | Default | Description |
|:-------|:--------|:------------|
| `md-table-align-padding` | `1` | Spaces rendered between a cell border and its content. |
| `md-table-align-pixel-width-function` | `md-table-align-pixel-width` | Measures a cell's rendered width, in pixels. |
| `md-table-align-modes` | `(markdown-ts-mode)` | Modes `global-md-table-align-mode` activates in. |

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
- Long lines still wrap; alignment does not add horizontal scrolling.

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
to switch itself off everywhere so no overlay outlives its code.

Tests assert on what the redisplay engine actually drew — they read back rendered
columns with `posn-at-point` — so they need a real frame. `make test` runs Emacs
under a pty to get a TTY frame; batch mode has no frame that lays text out.

## Repository layout

```
emacs-tools.el          collection loader; adds each extension to load-path
md-table-align/         extension: display-only Markdown table alignment
tests/                  test suite and TTY test runner
```
