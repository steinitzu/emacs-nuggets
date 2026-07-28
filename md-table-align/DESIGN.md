# md-table-align — planning and design

Render Markdown pipe tables visually aligned **without modifying buffer text**,
so alignment works in read-only buffers.

## Problem

`markdown-mode` aligns tables by rewriting the buffer (`markdown-table-align`,
bound to `TAB` via `markdown-table-align-p`). That is unusable when:

- the buffer is read-only (help buffers, `vc` revision buffers, `magit` blobs,
  gzipped/archived files, generated docs, `rgrep` previews);
- you don't want to dirty a file just to read it;
- the file is under version control and whitespace churn is unwelcome.

Goal: a **display-only** alignment. Buffer text stays byte-identical,
`buffer-modified-p` stays `nil`, and it works when `buffer-read-only` is `t`.

## Feasibility (validated before design)

Four experiments were run against real Emacs 31.0.90 before committing to this
design. All in a **real TTY frame** driven through a pty (`script -qc`), so the
actual redisplay engine ran and positions were read back with `posn-at-point`.

| # | Question | Result |
|---|----------|--------|
| 1 | Can text properties be set in a read-only buffer? | Plain `put-text-property` signals `buffer-read-only`; wrapped in `with-silent-modifications` it succeeds, text unchanged, `modified-p` stays `nil`. |
| 2 | Does `(space :align-to N)` actually move rendered text? | Yes. A pipe rendered at column 4 moved to column 10; downstream text shifted with it. |
| 3 | Can a `display` **string** re-render a dash run at a different length? | Yes. `\|---\|` rendered as `\|---------\|`. |
| 4 | Do overlay `before-string` stretch spaces work where text props can't? | Yes — `\|a\|bb\|` with *zero* padding whitespace aligned correctly. |

Conclusion: **yes, this is possible.** Experiment 4 decides the mechanism.

## Mechanism

For each table cell, place an **overlay** whose `before-string` is a single
space carrying `display` = `(space :align-to TARGET-COLUMN)`. The stretch glyph
expands to push the following text to `TARGET-COLUMN`.

### Why overlays rather than text properties

Text properties were the obvious first choice; they lose on four counts:

1. **Zero-padding cells.** `|a|` has no spare whitespace to stretch. A text
   property would have to hijack the `a` or the `|` and hide a real character.
   An overlay `before-string` *inserts* display content without covering
   anything.
2. **No `display` collision.** `font-lock` in `markdown-mode` uses the `display`
   text property (e.g. hiding markup). Overlays live in a separate plane.
3. **Never dirties the buffer.** Overlays cannot mark a buffer modified, so no
   `with-silent-modifications` dance and no undo interaction at all.
4. **Wholesale removal is trivial** — tag every overlay with a private property
   and sweep by region.

### Padding placement and alignment

The delimiter row encodes per-column alignment:

| Delimiter | Alignment | Padding goes |
|-----------|-----------|--------------|
| `---`     | left (default) | after content, before the closing `\|` |
| `:---`    | left      | after content |
| `---:`    | right     | before content, after the opening `\|` |
| `:---:`   | center    | split before/after |

The delimiter row itself gets an overlay with a `display` **string** — `:` and
`-` rebuilt to exactly the target width — rather than a stretch space, so it
renders as a continuous rule instead of a gap (experiment 3).

### Width measurement

Cell width is measured with `string-pixel-width` against the buffer, which
handles CJK double-width characters, combining marks, per-face metrics and font
fallback in one go. Target column width is the max over all rows.

`:align-to N` with a bare number is in units of the frame's canonical character
width. **This is not good enough**, and v1 shipping it was a bug — see
"Pixel units" below. Alignment uses `(space :align-to (N))`, the list form,
which is pixels, with widths from `string-pixel-width`.

### Absolute columns

`:align-to` is measured from the left edge of the window's text area, so target
columns are computed **absolutely**, including any leading indentation of the
table (tables nested in list items or blockquotes). Line-number margins don't
interfere since they sit outside the text area.

## Table discovery — tree-sitter only

**Scope decision:** this package targets `markdown-ts-mode` (or any buffer with
a `markdown` tree-sitter parser) exclusively. A regexp backend for
`markdown-mode` was considered and deliberately dropped — the grammar does
enough work that supporting a hand-rolled scanner would roughly double the
discovery code and carry all the edge-case risk.

What the grammar provides, verified against the real parse tree:

```
pipe_table
  pipe_table_header          | [1-2]  pipe_table_cell [3-8] "Name "  | [8-9] ...
  pipe_table_delimiter_row   pipe_table_delimiter_cell
                               pipe_table_align_left  ":"
                               pipe_table_align_right ":"
  pipe_table_row             ...
```

- Exact table bounds, so no fenced-code-block false positives (verified: pipe
  rows inside a ``` fence produce no `pipe_table` node).
- Anonymous `|` nodes with **exact buffer positions** — no pipe scanning needed.
- `pipe_table_cell` content bounds.
- `pipe_table_align_left` / `pipe_table_align_right` marker nodes — no delimiter
  parsing needed.
- Escaped pipes (`a\|b`) are natively kept in one cell.
- Pipes inside code spans (`` `x|y` ``) **do** split cells — this is
  GFM-correct (cell splitting precedes inline parsing, matching GitHub), and it
  means rows can be ragged, which the layout handles.

Discovery is therefore: `treesit-query-capture` for `(pipe_table) @t` over the
region, then walk each table's row/cell/pipe children.

### Requirements

Emacs 31+, where `markdown-ts-mode` is built in. It registers the grammar
sources itself and calls `treesit-ensure-installed`, so the grammar needs no
manual setup — Emacs offers to build it on first use. The mode here refuses to
enable (with a clear message) when no parser is available.

## Application strategy

Register with `jit-lock` so only tables intersecting the region Emacs is about
to display get aligned. This keeps large files responsive and makes
re-alignment on edit automatic — jit-lock re-invokes on changed regions.

A table is re-aligned as a unit: widths depend on every row, so touching one row
invalidates the whole table. The handler therefore expands the jit-lock region
to full table bounds.

## Public interface

- `md-table-align-mode` — buffer-local minor mode. Works in read-only buffers.
- `global-md-table-align-mode` — enables in markdown-ish modes.
- `md-table-align-buffer` / `md-table-align-clear` — one-shot commands.
- Customization: `md-table-align-pixel-width-function`, minimum cell padding,
  which modes the global mode activates in.

## Testing strategy

Per repo convention, e2e is the priority. The valuable assertion here is about
*rendered layout*, which no mocked unit test can reach.

**e2e (primary).** Real Emacs, real TTY frame via pty, real file in a real major
mode, `redisplay`, then read back geometry with `posn-at-point`:

- every pipe belonging to column *N* renders at the **same screen column**
  across all rows of the table;
- `buffer-modified-p` is `nil` and `buffer-string` is byte-identical after
  alignment;
- alignment works with `buffer-read-only` set to `t`;
- disabling the mode restores the original rendered columns;
- pipe rows inside a fenced code block are left untouched.

This exercises the genuine redisplay engine — the only thing that can confirm
the feature actually works.

**Integration (secondary).** Real buffers in real modes, batch mode, asserting
on discovered table structure, parsed alignment specs, and computed widths.
No stubbing of Emacs internals.

The tree-sitter `markdown` / `markdown-inline` grammars install into a
gitignored `.test-env/` and are built by `make deps`.

## Pixel units (v2)

v1 aligned in character-width units and documented proportional fonts as a
known limitation. That framing was wrong: the limitation bites **monospace**
tables too, and it produced a real bug.

Under `mixed-pitch-mode`, the buffer's `default` face is remapped with a scaled
`:height` (e.g. `1.15`). Neither `markdown-ts-table` nor `fixed-pitch`
specifies a height, so the table inherits the scaled one and renders ~1.15x
wider per character — while `frame-char-width`, which drives bare-number
`:align-to`, stays unscaled. Measured on a real config: **19 px/char rendered
against a 17 px grid**. The error accumulates across a row, and the widest cell
in each column — which by construction has only one space of slack — overflows.
Shorter cells in the same column still fit, which is what makes the failure
look sporadic rather than systematic.

The fix is to stop counting characters:

- cells are measured with `string-pixel-width` against the **current buffer**,
  so face remapping and font fallback are included;
- `md-table-align-padding` is converted from spaces to pixels using the width
  of a space *in the table's own face*;
- the opening border's width is measured rather than assumed;
- the indent is measured, not taken from `current-column`;
- positions are emitted as `(space :align-to (PIXELS))`.

On a TTY the canonical character width is 1, so every measurement reduces to a
character count and the layout is identical to v1 — which is why the existing
tests continued to pass unchanged.

### Instruments matter

Two measurements pointed the wrong way during diagnosis and cost real time:

- `window-font-width` reports **17** for the table face where the text actually
  renders at **19**; it does not reflect the buffer-local remap the face
  inherits its height from. It looked like proof the fonts matched.
- `window-text-pixel-size` clamps at the window edge, so every over-long
  trailing cell reported an identical width and looked like a uniform defect.

`string-pixel-width` with the buffer argument has neither problem and is the
instrument to reach for.

### Delimiter row quantisation

A run of dashes can only be a whole number of characters wide, so it cannot hit
an arbitrary pixel target. The count is rounded **down** — overshooting could
not be undone — and the closing border is pinned with a stretch glyph that
absorbs the shortfall. Any residue shows as a sub-character gap before the
border.

## Known limitations

- The delimiter row is character-quantised, as above.
- Very long lines that wrap will still wrap; alignment does not imply
  horizontal scrolling.
- `markdown-mode` (the MELPA package) is not supported — it has no tree-sitter
  parser. Use `markdown-ts-mode`, or create a `markdown` parser in the buffer.

## Validation against implementation

Checked after implementing. 20 tests pass in a real TTY frame; `make compile`
is clean with `byte-compile-error-on-warn`.

Held up as designed:

- Overlay stretch glyphs align tables with buffer text byte-identical,
  `buffer-modified-p` nil, and `buffer-read-only` set.
- Tree-sitter discovery skips fenced code blocks and needs no fence scanning.
- Delimiter rows re-render across the full inner width, matching the
  `|:------|----:|` output of `markdown-table-align`.
- `string-width` measurement aligns CJK cells correctly.
- jit-lock registration re-aligns whole tables after an edit with no stale
  overlays.

### Deviations

**Discovery returns table nodes, not parsed rows.** The design had each backend
returning a full row/cell structure. With a single tree-sitter backend that
indirection bought nothing, so `md-table-align--tables` returns `pipe_table`
nodes and parsing is one shared code path over their children.

**Column index is derived from pipe count, not cell order.** Not anticipated.
The grammar emits *no* `pipe_table_cell` node for some empty cells, so counting
cell nodes silently shifted every column after a gap. Column index now comes
from how many `|` nodes precede a cell, which is correct whether or not a node
exists. Caught by `md-table-align-test-handles-empty-cells`.

**Empty cells are padded from the opening border.** Also not anticipated. When a
cell *is* emitted but empty, its trimmed bounds collapse onto the closing pipe,
so the content overlay consumed the entire gap and left the border overlay
zero-length and ineffective. Empty cells now skip content positioning and
stretch the whole inter-border span instead.

**All tests run in the TTY frame.** The design split tests into e2e (TTY frame)
and integration (batch). Running the whole suite in the TTY frame is strictly
better — every test then asserts against real redisplay — and costs nothing, so
there is no batch tier.

**The loader is exercised by the test harness.** `tests/run-tests.el` loads
extensions via `emacs-tools.el` rather than adding directories itself, so every
run also smoke-tests the documented install path.
