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

## Fit to window (v3)

A table wider than the window wraps, and a wrapped row is not merely ugly —
alignment is destroyed, because the continuation lines restart at the window's
left edge with no relation to the column grid. Under `visual-line-mode`, which
is how prose Markdown is usually read, this is the common case rather than the
exceptional one.

### What was asked for, and why it can't be done

The natural framing is "keep word wrap, but turn it off for tables." **Emacs
cannot do this.** Wrapping is a property of the buffer and window
(`truncate-lines`, `word-wrap`), with no per-line or per-region equivalent.
Four experiments in a real TTY frame, 105-character row in a 60-column frame:

| # | Attempt | Result |
|---|---------|--------|
| 1 | Baseline `visual-line-mode` | wraps — 2 screen lines |
| 2 | Whole row replaced by an overlay `display` string | still wraps — a display string is laid out like text |
| 3 | Row containing no break opportunities at all | still wraps — `word-wrap` falls back to char wrapping |
| 4 | `truncate-lines` as a window parameter | no such parameter; the variable is buffer-local only |

Two mechanisms *do* give one screen line per row: `truncate-lines t`
(buffer-wide, so all prose unwraps too — rejected as too disruptive) and an
overlay `display` property eliding part of the row. The latter is the design.

For the record, one further option was tested and rejected: under
`truncate-lines t`, an injected `"\n"` — as either `display` or `before-string`
— *does* create a real visual line break, so prose could in principle be
re-wrapped by hand. That means reimplementing `fill` against every edit and
resize. Not worth it.

### Prior art

`org-table--shrink-field` (Emacs `lisp/org/org-table.el`) solves the same
problem and settles two objections that otherwise sink the approach:

- **Elided content stays reachable.** Each overlay carries `help-echo` with the
  field's full text, so a mouse hover or `C-h .` (`display-local-help`) reveals
  it. Hiding text is acceptable when it can be read back on demand.
- **Editing inside an elided span is survivable.** Org installs
  `modification-hooks`, `insert-in-front-hooks` and `insert-behind-hooks` that
  delete the whole column's overlays, so editing near a shrunk field expands it.

Also borrowed: a private overlay-type tag for sweeping, a defcustom indicator
string, and `priority` so shrinking overlays order predictably against others.

Org's *policy* is not borrowed. It shrinks on explicit command or a `<N>` width
cookie, never to fit the window, so the fitting rule below is ours.

For the resize half, `visual-fill-column` is the established pattern:
buffer-local `window-configuration-change-hook` plus `window-state-change-functions`
(Emacs > 27.1), with a handler that takes a window and recomputes for it.

`valign` — the closest sibling package, same stretch-glyph technique — does not
address wide tables at all, so there is nothing to borrow and nothing to
conflict with.

### Mechanism

A **fit step** sits between width computation and overlay placement. It leaves
`md-table-align--column-widths` alone and reduces its result to a budget:

1. Measure the row's natural width: indent, plus each column's border, padding,
   content and padding, plus the closing border.
2. Compare with the window's text area in pixels.
3. If it overflows, cap column widths (below), then lay out against the capped
   widths.
4. Any cell whose content exceeds its column's cap gets a **shrink overlay**
   replacing the tail of its text with the ellipsis, sized so that visible
   prefix + ellipsis fits the cap.

Alignment is otherwise unchanged: the existing stretch glyphs position content
against whatever widths they are handed.

### Shrink policy: cap the widest

Columns are capped at a single value `C` chosen so `Σ min(wᵢ, C) = budget` —
found by binary search on `C`. This spends the shortfall on the widest columns
first and leaves narrow columns (`Status`, `Yes`/`No`) untouched, which is what
makes the result readable rather than uniformly mangled. Proportional shrinking
was rejected for clipping columns that had room to spare; dropping trailing
columns was rejected for losing whole fields.

`C` has a floor of `md-table-align-min-column-width` characters. If every
column is at the floor and the row still overflows — a table with more columns
than the window has room for — fitting gives up and the row wraps as it does
today. Failing back to the status quo is the right failure mode.

### Measurement is not corrupted by shrinking

Org needs `org-table-with-shrunk-columns` — expand, operate, re-shrink —
because its shrink state persists across operations. This package needs no such
dance, for two independent reasons: `md-table-align--clear-region` wipes every
overlay before a table is laid out afresh, and measurement goes through
`buffer-substring`, which carries text properties but **not** overlays. Widths
are therefore always measured against unshrunk text.

### Which window a table is fitted to

Overlays belong to the buffer, not a window, so a buffer displayed in two
windows of different widths can only be laid out for one of them. Verified
that overlays accept a `window` property restricting them to a single window
(a 49-column and a 50-column window showing the same buffer rendered the row at
1 and 2 screen lines respectively), so a full per-window layout is possible.

v3 does **not** do that. It fits to the window the buffer is currently being
viewed in — the selected window when it shows the buffer, otherwise the first
one — and re-fits when that changes. Since `window-state-change-functions` also
fires on a change of selected window, moving between two windows re-fits to
whichever you are in, which covers the case that actually bites. The cost is
that a table simultaneously visible in two differently-sized windows is correct
in only one. The `window` property is the upgrade path if that proves annoying;
it costs one set of overlays per window, which is why it is not the default.

### Re-render triggers

`jit-lock` covers edits but not geometry: resizing a window does not invalidate
fontification. Fitting therefore adds buffer-local
`window-configuration-change-hook` and `window-state-change-functions`, both
routed to a handler that compares the fitting window's pixel width against the
width the current layout was computed for and does nothing when they match.
That guard matters — these hooks fire often, and re-aligning unconditionally
would re-lay every visible table on every window operation.

### Deferred: reveal the cell at point

The obviously desirable refinement is that the cell containing point is never
shrunk, so moving through a table reveals cells in passing. This is a better
rule than Org's edit-triggered expansion and fits the re-layout model, but it
needs a `post-command-hook` and cursor-motion-triggered relayout. Deferred to
keep v3 reviewable; `help-echo` and `C-h .` cover reading in the meantime.

### Interface added

- `md-table-align-fit-to-window` — enable fitting. Default `t`: a wrapped table
  is never what anyone wanted.
- `md-table-align-ellipsis` — indicator for elided text, default `…`.
- `md-table-align-min-column-width` — floor for the cap, in characters.

### Validation against implementation (v3)

40 tests pass in a real TTY frame; `make compile` is clean with
`byte-compile-error-on-warn`. Rendered output was read back at several frame
widths, reconstructed from `posn-at-point` geometry:

```
=== fitting OFF (frame 40) ===   === fitting ON (frame 40) ===
 tatus  | Description       |S    | Name  | Description        | Status |
|-------|-------------------|--   |-------|--------------------|--------|
|pen ha | first item descr… |o    | alpha | first item descri… | open   |
 one a  | second item desc… |d    | beta  | second item descr… | done   |
```

The left-hand column is what the wrapping actually looks like once
reconstructed — the second screen line of each row starts at the window edge,
which is the failure this feature exists to remove.

Held up as designed: the cap falls on the widest column only (`Name` and
`Status` are untouched at 40 columns); widening restores the full table with no
explicit refresh; `buffer-string` and `buffer-modified-p` are unaffected; a
window too narrow for floor-width columns falls back to wrapping.

#### Deviations

**Borders are budgeted from one measurement, not per pipe.** The fit step
computes fixed overhead as `(columns + 1) × width-of("|")`, while the layout
pass measures each pipe individually. Every `|` in a table renders in the same
face, so these agree; they would diverge only if a single table's pipes were
faced differently, which the grammar gives no way to express. Budgeting per
pipe would mean measuring the whole table twice for no gain.

**`md-table-align--layout-row` takes a context plist.** It had five positional
arguments and fitting needed a sixth. Grouping the per-table layout constants
into one `ctx` plist was cheaper than growing the signature further.

**`md-table-align--space-width` became `md-table-align--glyph-width`.** It now
converts the ellipsis and the minimum column width as well as padding, so a
name naming only spaces was wrong. Internal, so no compatibility concern —
unlike a `defcustom`, which the repo conventions require renaming rather than
redefining.

**The floor is inclusive.** A table that fits with *every* column exactly at
`md-table-align-min-column-width` is fitted rather than abandoned. The design
text ("if every column is at the floor and the row still overflows") already
implies this, but it was ambiguous enough to write the first test backwards.

### Testing

The TTY frame makes this directly assertable, with the frame narrowed to force
overflow:

- every row of an overflowing table occupies exactly **one screen line**
  (`count-screen-lines`), where without fitting it occupies more;
- pipes still align across rows — fitting must not break the v1 guarantee;
- widening the frame restores the unshrunk table;
- `buffer-string` is unchanged and `buffer-modified-p` is nil, as ever;
- a table that already fits gets no shrink overlays at all;
- a table with more columns than can fit falls back to wrapping rather than
  producing a degenerate layout.

## Horizontal scrolling (v4)

v3 stopped wide tables wrapping by hiding text, and that trade was never
settled — see [docs/seeing-elided-table-text.md](../docs/seeing-elided-table-text.md).
It is now settled: **hiding text with no way to reach it is not acceptable.**
Width capping is replaced by a horizontal **viewport** per table, scrolled with
the same semantics a `truncate-lines` buffer already has.

The table still never wraps — that v3 guarantee is kept — but the text that
does not fit is now *scrolled to* rather than *lost*.

### Why not wrap cells into taller rows

The obvious alternative — reflowing each cell so a wide table becomes a tall
one — was investigated first and rejected. It is mechanically possible; it is
not worth it. Measured in a real TTY frame:

| # | Question | Result |
|---|----------|--------|
| A | Does an injected `"\n"` break the line under `word-wrap`, not just `truncate-lines t`? | **Yes** — the v3 doc's open question, resolved |
| B | Does `(space :align-to (N))` re-indent the continuation line? | **Yes**, to an absolute column |
| C | Can `:align-to` move text *backwards*? | **No** — asked to align to 5 from column 20, text stayed at 20 |

C is the constraint that decides it. Screen order must follow buffer order, so
a proper wrapped row — screen order `c1L1 c2L1 c3L1 / c1L2 c2L2 c3L2` against
buffer order `c1L1 c1L2 c2L1 c2L2 c3L1 c3L2` — is unreachable as soon as **two**
cells wrap. Breaking cells in place instead yields a staircase, each break
shoving every later cell down a line:

```
| alpha beta | first item
              description | open
                                      now |
```

A real wrapped row can be built, by hiding each over-long tail with `display`
`""` and re-emitting copies of them row-major in one synthesized continuation
string (verified: the row then occupies two screen lines and later cells stay
on line 1). But that makes the package *re-emit* text rather than position it,
and point inside a relocated tail collapses onto the overlay start — three
distinct buffer positions all rendered at column 20. Editing and cursor motion
inside a wrapped cell would go blind.

Decisive, though, is that it does not solve the problem: a table with genuinely
long cell text becomes a very tall table, which is not more readable than a
scrollable one.

### Mechanism

Scrolling is expressed as an **offset in the aligned coordinate space**, not in
buffer columns. Each table has a viewport `[offset, offset + window-width)`,
and each row is laid out as:

1. Everything left of `offset` in the aligned grid is one **contiguous buffer
   prefix** — a *different* prefix on each row, since cell contents differ in
   length. Hide it with a `display` `""` overlay.
2. Every remaining pipe and cell start gets its existing stretch glyph, with
   the target computed as `aligned-column - offset`.
3. Everything right of the viewport is clipped the way v3 elides a tail —
   otherwise the row still wraps.

Step 1 is what makes step 2 sound. With the prefix rendered at zero width the
remaining text lays out compactly, so every element sits *left* of its shifted
target and each `:align-to` still pushes forward. That forward-only property is
exactly the invariant v1 already depends on; nothing new is required of it.

Getting this wrong is easy and was caught in probing: picking the clip point in
*buffer* columns while the targets are in *aligned* columns leaves a different
amount of each row visible, and the column grid collapses. Verified correct
against the aligned rule at four offsets on a three-row table — every row
agreed on every visible pipe column, matching the shifted grid exactly:

```
offset  0 -> (8 20 31 40) (8 20 31 40) (8 20 31 40)   agree: YES
offset 10 -> (10 21 30)   (10 21 30)   (10 21 30)     agree: YES
offset 20 -> (11 20)      (11 20)      (11 20)        agree: YES
offset 31 -> (9)          (9)          (9)            agree: YES
```

Two properties fall out that native `hscroll` cannot offer, both verified:
prose around the table **does not move** (only table rows are clipped), and the
row stays on **one screen line** under `word-wrap`, with no `truncate-lines`
anywhere.

### Scroll semantics: mirror `truncate-lines`

The model is the one Emacs users already have, so there is nothing new to
learn. Concretely:

- **Continuous and column-granular.** Not column-at-a-time: a cell wider than
  the window must be readable to its end, and whole-column stepping would show
  its first screenful and no more — which is v3's complaint again.
- **The viewport follows point**, as `auto-hscroll-mode` does, honouring
  `hscroll-margin` for edge proximity and `hscroll-step` for step size. Reusing
  the built-in variables means an existing config carries over.
- **`C-x <` / `C-x >`** (`scroll-left` / `scroll-right`) are remapped inside a
  table. They do nothing useful in a wrapped buffer, so there is no behaviour
  to displace.

Point-following is not a refinement here, it is load-bearing. Text hidden by a
`display` `""` overlay collapses point onto the overlay start, so a viewport
that ignored point would make cursor motion inside scrolled-off text
meaningless. Defining the viewport to contain point means point is never inside
hidden text, and the problem cannot arise.

It also **subsumes "reveal the cell at point"**, deferred in v3 — the cell at
point is visible by construction, so that feature is dropped rather than
implemented.

### Scope of an offset

One table at a time: the table containing point. Leaving a table resets its
offset to zero.

Per-table persistent offsets were considered and rejected. Keyed by buffer
position they go stale on the first edit above the table, and the extra state
buys little — coming back to a table you scrolled earlier is rare, and a table
left scrolled is a table whose first columns are mysteriously missing.

### Interaction with existing machinery

- **jit-lock** re-lays a table as a unit already, and the offset is an input to
  layout, so an edit re-renders at the current offset with no extra plumbing.
- **Window resize** already re-fits via `window-configuration-change-hook` and
  `window-state-change-functions`; the same handler clamps the offset when the
  window widens enough to make it unnecessary.
- **Point-following** needs `post-command-hook`, which v3 deliberately avoided.
  It runs before redisplay, so an offset change is applied without flicker.
  The handler must be cheap: it exits immediately unless point is in a table
  and the offset actually needs to change.

### Interface

New:

- `md-table-align-hscroll` — enable the viewport. Default `t`.
- `md-table-align-hscroll-indicator` — whether to mark clipped edges. Default `t`.
- `md-table-align-hscroll-table-at-point` / `-left` / `-right` — commands.

Obsoleted rather than redefined, per the repo's live-reload rule — a stale
value in a running session or a user's config must go inert, not be silently
reinterpreted:

- `md-table-align-fit-to-window` → `make-obsolete-variable`; fitting is gone.
- `md-table-align-min-column-width` → obsolete with it; there is no cap to floor.

`md-table-align-ellipsis` is kept and reused as the clipped-edge indicator. Its
meaning — "text is present here but not shown" — is unchanged, so it does not
need renaming.

### Deferred: pin the first column

Keeping column 1 fixed while later columns scroll past it is genuinely useful
on a wide table, since a scrolled row otherwise loses its row label. Deferred
to keep v4 reviewable. It needs no rework to add: the hidden span becomes a
*middle* span rather than a leading prefix, which the overlay mechanism handles
identically.

### Testing

The TTY frame makes all of this directly assertable, as with v3:

- at every offset, all rows agree on the rendered column of each visible pipe,
  and those columns equal the aligned grid shifted by the offset;
- an over-wide table occupies exactly one screen line per row at every offset;
- prose above and below the table renders at column 0 regardless of offset;
- moving point into a scrolled-off cell brings it into view, and point never
  renders inside a hidden span;
- `buffer-string` is unchanged and `buffer-modified-p` is nil, as ever;
- a table narrower than the window gets no clip overlays and ignores scrolling;
- widening the window past the table's natural width clamps the offset to zero.

### Validation against implementation (v4)

48 tests pass in a real TTY frame; `make compile` is clean with
`byte-compile-error-on-warn`. Rendered output was read back at several
offsets, reconstructed from `posn-at-point` geometry, in a 40-column frame
against a table needing 48:

```
=== offset 0 ===                        === scrolled 10 columns ===
prose before the table                  prose before the table
| Name  | Description…                  …Description                 | Status |
|-------|-----------------------------… …----------------------------|--------|
| alpha | first item description here…   …first item description here | open   |
| beta  | second item description…       …second item description     | done   |
prose after the table                   prose after the table
```

Held up as designed: rows stay on one screen line at every offset; all rows
agree on every visible pipe column at every offset; the prose above and below
renders at column 0 throughout; point moved into a clipped cell brings the
viewport to it; `buffer-string` and `buffer-modified-p` are unaffected.

#### Deviations

**No `md-table-align-hscroll-table-at-point` command.** The interface section
listed one without saying what it would do, and nothing turned out to need it:
the viewport follows point on its own, and the explicit commands act on the
table at point already. `md-table-align-hscroll-reset` was added instead, which
is the operation that was actually missing.

**The commands are named for the direction the *text* moves,** matching
`scroll-left` and `scroll-right`, whose bindings they take over. Naming them
for the viewport instead would have been clearer in isolation and inconsistent
with the two commands a user is holding in their head at the time.

**An explicit scroll drags point along with it.** Not in the design, and not
optional: the viewport follows point, so scrolling away from point would simply
be undone by the very next command. This mirrors the vertical case, where
`scroll-up` also refuses to leave point off screen.

**The clipped-edge indicators are budgeted, not drawn over the table.** They
occupy space inside the viewport rather than covering the leftmost or rightmost
character, so a column is never half-hidden behind one. The clamp on the offset
is defined against the budget that applies *at* the rightmost offset, which
makes it a fixed point: laying out at `maxoff` reproduces exactly that budget,
and the table's right edge lands exactly on the viewport's.

**There is a floor after all, though not the one v3 had.** A window with no
room for even two characters of table is left to wrap rather than clipped to
nothing. v3 gave up when its columns hit a minimum width; this gives up only
when the viewport itself would be degenerate.

**Table measurements are memoised against the buffer's modification tick.**
Not anticipated, and needed: the viewport consults the grid on every command to
decide whether point is still inside it, and re-measuring every cell that often
made cursor motion visibly slow. Layout and point-following share the cache.

**Clip overlays carry a private `md-table-align-clip` tag** in addition to the
`md-table-align` one every overlay has, so that the one kind that takes text
away can be told from the kinds that only move it.

## Known limitations

- The delimiter row is character-quantised, as above.
- `markdown-mode` (the MELPA package) is not supported — it has no tree-sitter
  parser. Use `markdown-ts-mode`, or create a `markdown` parser in the buffer.
- A table visible in two differently-sized windows at once is laid out for one
  of them (see "Which window a table is fitted to").
- Only one table holds a scroll offset at a time, and leaving it resets that
  offset (see "Scope of an offset").
- The first column is not pinned while the rest scrolls, so a scrolled row
  loses its row label (see "Deferred: pin the first column").
- Clipping still hides text at the viewport's edges — but every character is
  now reachable by scrolling to it, which is what
  [docs/seeing-elided-table-text.md](../docs/seeing-elided-table-text.md)
  required. It also remains readable in place via `C-h .` or a mouse hover.

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
