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

Cell width uses `string-width`, not `length`, so CJK double-width characters and
combining marks measure correctly. Target column width is the max over all rows.

`:align-to N` with a bare number is in units of the frame's canonical character
width. On a TTY and on any monospace GUI font this is exact. Variable-pitch
fonts would need pixel units (`(space :align-to (N))` with `string-pixel-width`).

**v1 scope:** character-width units. The measurement is isolated behind
`md-table-align-width-function` so a pixel backend can drop in later without
touching the layout code. Non-goal for v1.

### Absolute columns

`:align-to` is measured from the left edge of the window's text area, so target
columns are computed **absolutely**, including any leading indentation of the
table (tables nested in list items or blockquotes). Line-number margins don't
interfere since they sit outside the text area.

## Table discovery

Pluggable, because the two target modes offer very different facilities.

- **tree-sitter backend** — used when a `markdown` parser exists in the buffer
  (i.e. `markdown-ts-mode`). Query for `pipe_table` nodes; children are
  `pipe_table_header`, `pipe_table_delimiter_row`, `pipe_table_row`, with
  `pipe_table_cell` leaves and `pipe_table_align_left`/`_right` markers.
  Verified: the grammar correctly does **not** match pipe-looking lines inside a
  fenced code block.
- **regexp backend** — used otherwise (`markdown-mode`, `gfm-mode`, plain
  `text-mode`). Scan for maximal runs of lines matching a pipe-row regexp whose
  second line is a delimiter row, skipping fenced code blocks.

Both backends return the same shape: a list of tables, each a list of rows, each
row a list of `(cell-beg . cell-end)` plus delimiter positions.

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
- Customization: `md-table-align-width-function`, minimum cell padding,
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
- runs against **both** `markdown-mode` and `markdown-ts-mode`;
- disabling the mode restores the original rendered columns.

This exercises the genuine redisplay engine — the only thing that can confirm
the feature actually works.

**Integration (secondary).** Real buffers in real modes, batch mode, asserting
on discovered table structure, parsed alignment specs, and computed widths.
No stubbing of Emacs internals.

Test dependencies (`markdown-mode` from MELPA, tree-sitter markdown grammars)
install into a gitignored `.test-env/` and are built by `make deps`.

## Known limitations (documented, not fixed in v1)

- Variable-pitch fonts: alignment is in character units, so proportional fonts
  will not align exactly. Pixel mode is the planned follow-up.
- Very long lines that wrap will still wrap; alignment does not imply
  horizontal scrolling.
- Escaped pipes (`\|`) inside cells: the regexp backend must not split on them;
  the tree-sitter backend handles this natively.
