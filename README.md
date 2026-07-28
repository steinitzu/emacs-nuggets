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

Requires Emacs 29.1 or newer.

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

Table discovery uses tree-sitter, so the buffer needs a `markdown` parser —
in practice, `markdown-ts-mode`. Install the grammars once:

```elisp
(setq treesit-language-source-alist
      '((markdown "https://github.com/tree-sitter-grammars/tree-sitter-markdown"
                  "split_parser" "tree-sitter-markdown/src")
        (markdown-inline "https://github.com/tree-sitter-grammars/tree-sitter-markdown"
                         "split_parser" "tree-sitter-markdown-inline/src")))

(treesit-install-language-grammar 'markdown)
(treesit-install-language-grammar 'markdown-inline)
```

Note that Emacs does **not** associate `.md` files with `markdown-ts-mode` by
default. You probably want:

```elisp
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
| `md-table-align-width-function` | `string-width` | Measures a cell's display width. |
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

Alignment is measured in the frame's canonical character width, so for columns
to line up exactly, the font `fixed-pitch` resolves to must have the same
advance width as your frame font. To check:

```elisp
(list :frame-char-width (frame-char-width)
      :table-font-width (window-font-width nil 'markdown-ts-table))
```

Equal values mean alignment is exact. If they differ, match `fixed-pitch` to
your default face more closely — the `:width` and `:height` attributes are the
usual culprits.

#### Limitations

- Alignment is in character-width units, so proportional fonts will not line up
  exactly. Monospace fonts (and any terminal) are exact, provided the check
  above passes.
- Long lines still wrap; alignment does not add horizontal scrolling.

## Development

```sh
make deps      # build the tree-sitter grammars the tests need
make test      # run the test suite
make compile   # byte-compile, warnings are errors
```

Tests assert on what the redisplay engine actually drew — they read back rendered
columns with `posn-at-point` — so they need a real frame. `make test` runs Emacs
under a pty to get a TTY frame; batch mode has no frame that lays text out.

## Repository layout

```
emacs-tools.el          collection loader; adds each extension to load-path
md-table-align/         extension: display-only Markdown table alignment
tests/                  test suite and TTY test runner
```
