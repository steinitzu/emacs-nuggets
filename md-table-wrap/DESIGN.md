# md-table-wrap — planning and design

Draw a Markdown pipe table that is too wide for the window with its cells
**word-wrapped inside their columns**, so the whole table fits the text area
and reads like a table hand-aligned into multi-line cells. Display-only: the
buffer text never changes, so it works in read-only buffers too.

## Problem

`md-table-align`, this package's predecessor, aligned tables, and for a
table wider than the window it clipped to a viewport and scrolled sideways
(or spilled into the margin). Both kept every row on one screen line, so a
table whose cells hold sentences was read through a letterbox: most of each
row off screen at any moment.

What a reader wants is the table a person would type into a text file when
the cells are long:

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

while the buffer still holds the one-line-per-row Markdown it always did.

## Feasibility

Researched and prototyped before this design (2026-10-21/22). The
prototype, `table-wrap-poc.el`, was used in a GUI Emacs and judged good
enough to use daily. The findings that shaped this design:

- Emacs cannot interleave two cells' lines from buffer text: the buffer
  holds `c1 c2 c3`, the screen needs `c1L1 c2L1 c3L1 / c1L2 c2L2 …`. Any
  real-text layout must follow buffer order, so wrapped cells have to be
  **drawn as copies**, not shown in place.
- `(space :align-to …)` stretches work inside overlay **before-strings**
  but are inert inside `display` strings (xdisp.c). Copies therefore live
  in before-strings.
- A `cursor` text property on a copy puts the **real cursor** there, but
  only if the hidden span the copy belongs to holds point. Hence the
  per-line anchors below.

## Mechanism: per-line anchors

For each body row of a wrapped table:

- The row's source text is hidden in **one span per screen line**. Each
  span is an overlay whose `display` is `"\n"` (`""` for the last line),
  and whose `before-string` is that screen line, drawn from copies of the
  cell text, pipes and `:align-to` stretches.
- Because every screen line starts at a buffer position of its own,
  one-line scrolling steps through a tall row like ordinary text.
- At rest a row's spans are one character each. When point enters a row,
  it is **re-anchored around point**: the spans are moved so the line
  holding point holds point's position, and the copy of the character at
  point gets the `cursor` property. A `post-command-hook` re-anchors at
  most two rows per command: the one left and the one entered. It runs
  before the command loop's point adjustment, and sets
  `disable-point-adjustment`, so point is never pushed out of the hidden
  text.
- When several line overlays share a start (fewer characters after point
  than lines left), Emacs shows their strings in no fixed order, so a run's
  strings are concatenated onto its first overlay.
- The delimiter row is a single `display` string.

Every string the mode draws ends in the `default` face: cell copies,
rules, the top and bottom edges, the delimiter row and each line span's
newline. An overlay or display string's unfaced attributes are otherwise
taken from the buffer text at its anchor, so a line anchored in bold text
would turn bold.

*Changed:* at first only the cell copies got `default`, applied as each
line was built, and the rules and edges went without. A rule rides on the
last line of its row, which is anchored at point, so in a GUI it took the
height of whatever point was in. In a code span of a different size, `─`
came out narrower than the column unit: the bottom edge's `┴┘` slid left of
the pipes above, and rules changed width as point moved. Now `default` goes
on each finished before-string, in `md-table-wrap--show-row`, and on the
display strings. A terminal shows every face one column wide, so the test
checks the invariant (every drawn character carries `default`) rather than
the width.

## Layout

### Discovery

Tables come from the tree-sitter `markdown` parser (`pipe_table` and its
row nodes), which also keeps pipe lines in fenced code out. Without a
parser a regexp fallback
treats runs of pipe-led lines ending in a delimiter row as tables.

### Column widths

Greedy widening from minimum widths:

- A column's minimum is its longest word, capped at
  `md-table-wrap-word-cap` characters.
- Starting from the minimums, repeatedly widen the column whose next
  height-saving width saves the most table lines per unit of width.
  Leftover width goes to the columns furthest below their natural width.
- **Label columns** (widest cell at most `md-table-wrap-short-column`) are
  kept unwrapped when that costs at most `md-table-wrap-protect-tolerance`
  of the table's height.
- **Sticky widths while editing**: after an edit, the current widths are
  kept while they stay valid and within `md-table-wrap-sticky-slack` of
  the fresh optimum's height, so columns don't jump while typing.
- A table that fits is drawn at natural widths. A table whose minimums
  don't fit squeezes the widest minimums; words then break mid-word.

Against an exact optimum on 201 test tables, the greedy result is 2.2%
taller on average.

Break rules: words break at spaces; a word longer than its column breaks
after `/ . - _ ? & = # , ; :`; CJK breaks between any two characters;
code spans stay whole until wider than the column.

### Geometry

Widths are counted in characters of the table's face, measured once per
layout with `string-pixel-width`, so the table font must be fixed-pitch
(it is under `markdown-ts-mode` with `mixed-pitch`). The face is taken from
a delimiter cell, which has none of the bold or shadow a header cell or a
pipe may carry. A table's indentation (a table in a list item) is measured
in pixels as rendered, and every stretch aligns to it.

The width budget is the window's body width minus the indentation, less
one column for the wrap glyph.

### Lazy building

Redisplay cost is linear in the buffer's overlay count, and a wrapped row
holds one overlay per screen line. So a table's work is split in two:

- **The model is eager, but cheap.** Parsing, cell models and column
  widths are computed for the whole table at layout: they make no
  overlays, and widths depend on every row. Two things keep this from
  growing with the table, found by profiling a 1000-row table, where
  enabling took 8 s and C-n 30 ms:
  - Columns are **allocated from a sample** of at most
    `md-table-wrap--alloc-rows` body rows, evenly spaced. The greedy
    widener wraps every sampled row at every candidate width (38,000
    wraps at 1000 rows), so it is by far the costliest step. Minimum and
    natural widths still come from every row; they are one pass.
  - **Wrapping is lazy.** A row's lines are computed when it is built,
    or when motion passes through it, and dropped when widths change.
    Whether a table wraps at all, which decides its rules, is read off
    the widths: some cell's natural width exceeds its column.
- **Nothing per command walks every row.** Each row stores its index in
  its table and in the buffer's run of table rows, and the built rows are
  kept in a list. Eviction, face mirroring and the rule decision use
  those, not a scan.
- **Overlays are lazy.** A row's strings and overlays are built from a
  `jit-lock` function, registered after font-lock (depth 90:
  `jit-lock-register` prepends, and copies must be taken from text this
  pass has already fontified), for the rows intersecting the region redisplay is
  about to show. Laying out a table builds nothing: it marks the table's
  text unfontified, so jit-lock asks for whatever comes into view. The row
  holding point is also built on demand after each command, since its
  cursor anchoring can't wait for redisplay.
- **Far rows are evicted.** After each command, a built row more than
  `md-table-wrap--keep-rows` rows from point and from every window's start
  onto the buffer is torn down, and its text marked unfontified, so
  jit-lock rebuilds it if it is shown again. The overlay count is then
  bounded by the neighbourhood of the windows, not the buffer. Window
  starts are read after the command but before redisplay moves them, so
  after a jump the old neighbourhood stays built until the next command:
  the bound is two neighbourhoods, not one.

Invariant: a row in a laid-out table either is built or has its text
unfontified. Every path that leaves a row unbuilt (layout, eviction) marks
it so.

Rows are fontified for their copies with `font-lock-fontify-region`,
never `jit-lock-fontify-now` or `font-lock-ensure`. jit-lock points
`font-lock-ensure-function` at `jit-lock-fontify-now`, so both run
`jit-lock-functions`: that re-enters the builder (found as a
`max-lisp-eval-depth` error, with whole chunks built at a time), and marks
text fontified that the builder may not have built, breaking the
invariant. The builder skips a table
whose geometry is not yet set for the same reason. Inside the jit-lock
pass, font-lock has already covered the region; a row straddling its edge
is fontified first.

A width change re-wraps every row's model but rebuilds only the rows that
are built.

**Refontified rows are rebuilt.** When jit-lock asks for a row that is
already built, the builder builds it again. Built text is only marked
unfontified when something wants it fontified anew, such as a
`font-lock-flush` from a mode that adds faces, and the row's copies hold
the faces from before. The row holding point is rebuilt anchored around
point, so the cursor stays put. The rebuild is skipped while edits are
pending (`md-table-wrap--dirty`/`--full`): the row's model may not match
its text then, and the next command's update rebuilds the rows those edits
touch.

*Changed:* at first the builder skipped built rows. That went unnoticed
while `md-table-align` was the table mode `md-table-inline` was tested
against. Tested against this mode, it showed up: with `md-table-inline-mode`
turned on second, a code span's copy never got the code-span face.

**Painting.** `markdown-ts-mode` keeps a face overlay over the table point
is in (`markdown-ts-in-table`), so every row has foreign faces to mirror,
and every anchoring repainted every line of the row, character by
character. Faces now go on in runs, and each row caches its lines painted
with the current foreign faces: moving point through a row repaints only
the line holding the cursor.

Word break points (the pieces a too-long word may split into) are
computed on first use: most words never need them.

**Measured** in a 60×24 terminal, byte-compiled, on a 1000-row table whose
every row wraps:

| | |
|---|---|
| enable and first redisplay | 148 ms |
| C-n with redisplay | 3.9 ms (plain Emacs: 2.85 ms) |
| C-n stretching an active region | 4.9 ms |
| overlays | 168, for 56 built rows of 1002 |

Interpreted (no `.elc`), the same runs take about seven times as long.

## Borders

`md-table-wrap-style` picks how borders are drawn:

- `box` (default): box-drawing characters. `┌┬┐` above the header,
  `╞═╪═╡` for the delimiter row, `├─┼─┤` between rows and `└┴┘` below the
  last, with `│` for every pipe. Borders take the `md-table-wrap-border`
  face (`shadow`) merged over the table's own face, so they stay in the
  table's fixed-pitch font and join up.
- `ascii`: the Markdown characters, `|` and `-`.

**Rules between rows.** Without them, a column of long sentences reads as
one run-on paragraph, because nothing marks where one row ends. A wrapped
table therefore gets a rule below every body row (`md-table-wrap-row-rules`).
A table where every row fits on one line gets none: they would double its
height for nothing. The rule is appended to the row's last line string,
after a newline, with an `:align-to` to the table's indent, since nothing
real precedes it on its screen line.

### Rejected: a "web" style

Tried in the prototype: 1-pixel stretch verticals, rules as `:underline`
on each row's last line, a shaded header band, and short padding lines
(reduced `:height` on the line's glyphs and newline) between rows. It was
never verified to render as intended. The box style was judged cleaner,
works identically in a terminal, and needs none of the extra overlays,
so the web style was dropped.

## Interaction

| Behaviour | How |
|---|---|
| C-n / C-p | remapped; target computed from the layout model, goal column kept across repeats |
| C-a / C-e | remapped to the start and end of the screen line within the row |
| C-f / C-b, typing, DEL, yank, undo | native: point moves through source text; the row re-anchors after each command |
| scrolling | each screen line has its own buffer position; after a scroll command, point at `window-start` is mapped to the line it shows |
| mouse-1 on a copy | the copy's own `keymap` maps the click to the source character |
| region, isearch, show-paren… | foreign overlay faces over a row are mirrored onto its copies from `pre-redisplay-functions` (`md-table-wrap-mirror-faces`) |
| hl-line | `hl-line-range-function` is narrowed to point inside a table; the line holding point gets the `hl-line` face on its copy |
| markdown faces | copies are taken with `buffer-substring` after fontifying the row |

### Edits

- An edit inside a row re-parses and re-wraps only that row, then
  schedules an idle reallocation of the table's widths
  (`md-table-wrap-idle-delay`), sticky as above.
- An edit that adds or removes a newline near a table, or changes a row's
  shape (cell count, delimiter-ness), re-lays out the whole buffer.
  Elsewhere it schedules an idle rescan.
- A change of window width or `face-remapping-alist` (text scaling)
  re-allocates or re-lays out on the next command.

## Replacing md-table-align

This mode shipped alongside `md-table-align`. It switched
`md-table-align-mode` off in its buffers, and `global-md-table-align-mode`
skipped them. The plan was for wrapping to become `md-table-align`'s way
of fitting a wide table once it had seen daily use.

It did see daily use, and it covers what `md-table-align` was for: a table
that fits is drawn aligned, and one that doesn't is wrapped rather than
clipped. That made the rest of `md-table-align` redundant: the horizontal
viewport, the margin spill for `visual-fill-column`, and the many-tables
performance work behind them. On 2026-11-03 `md-table-align` was retired,
with the coexistence code above, and this mode became the only table
renderer. It lives on in git history.

Two things only `md-table-align` did went with it:

- **Column alignment markers.** `:---:` and `---:` centred and
  right-aligned a column; here every column is left-aligned.
- **The vertical records view** (`md-table-align-toggle-vertical`), a
  psql `\x`-style `label | value` rendering of a table, toggled per table.

## Limits

These are known and accepted for a first version:

- **Eager models.** Every table's model is rebuilt on enable and on each
  structural change near a table (see Lazy building). Parsing and cell
  models are still linear in the rows, though cheap.
- **Sampled widths.** A table over `md-table-wrap--alloc-rows` rows gets
  widths chosen for its sample, which can be a little taller than widths
  chosen for every row.
- **Source order.** C-f/C-b, M-f/M-b, the region and kill follow the
  buffer's cell-by-cell order, not the screen's. Display-only means the
  buffer holds the row as `c1 c2 c3`; this cannot change.
- **No drag-select** through copies: `mouse-drag-region` maps through
  `posn-point`, which is the anchor.
- **One window width per buffer**: in two windows of different widths the
  table fits the one used for layout.
- **Rendered vs raw width.** Hidden markup (`markdown-ts-hide-markup`)
  takes no space on screen, but wrapping counts the raw text.
- **Window start** can't sit on a rule line, so a one-line scroll steps
  over it.

## Lifecycle

- `md-table-wrap-unload-function` switches the mode off in every buffer,
  removing overlays, hooks and timers before the definitions go.
- Turning the mode off removes every overlay it made (they all carry the
  `md-table-wrap` property) and restores `hl-line-range-function`.

## Testing

Integration tests in a real TTY frame (`make test`), in real
`markdown-ts-mode` buffers:

- buffer text and modified flag unchanged; works in `buffer-read-only`
  and `read-only`-property buffers;
- the drawn lines fit the window and every border stands in the same
  column on every line, including in a list item;
- rules between rows of a wrapped table, none in a table that fits;
- C-n/C-p and C-a/C-e land on the model's positions, and the cursor
  shows on the row's right screen line;
- typing into a cell re-wraps it;
- refontifying a built row redraws it, with the cursor where it was, and
  faces `md-table-inline-mode` adds reach the copies in either order;
- turning off removes every overlay.

Deviation, found while writing them: `posn-at-point` can't locate the
cursor in a wrapped row. Point is inside hidden text there, so it reports
the anchor's glyph, not the copy the `cursor` property puts the cursor on.
The tests find the screen line holding that property instead. That the
terminal really draws the cursor there was checked in the prototype, by
driving `emacs -nw` on a pty and reading the terminal's own cursor.
