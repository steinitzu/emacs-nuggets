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

## Read-only text and command-loop robustness (v4.1)

Three defects found together while diagnosing "scrolling does nothing in this
buffer". Only the first is about read-only text; the other two are what made it
so hard to see, and the third is independent of read-only entirely.

### Read-only is a text property, not just a buffer flag

v1 claimed read-only support and tested it — but only via `buffer-read-only`.
The other way a buffer is made read-only is a `read-only` **text property** over
a region, which is what a chat or transcript UI uses to lock down what it has
already printed while leaving an input area editable.

That property is fatal here for a non-obvious reason. Measurement deliberately
keeps text properties (see "Width measurement") because faces are the whole
point of measuring rather than counting characters. `buffer-substring` therefore
carries `read-only` into the measured string, and `string-pixel-width` measures
by **inserting the string into a work buffer** — where read-only text signals
`text-read-only`. Measurement is the foundation everything else stands on, so
this took out alignment, clipping and scrolling in one go.

The fix strips a small set of properties from the measured copy
(`md-table-align--unmeasurable-properties`): `read-only` and the three insertion
hooks. The distinction is *display* versus *modification* — `face`, `display`,
`invisible` and `composition` are kept because they change how wide the text
renders; properties that govern modification have no bearing on width and only
misfire against a work buffer. The copy is what `buffer-substring` already
returned, so the buffer is never touched.

A whitelist was considered and rejected: the set of properties that legitimately
affect rendered width is open-ended (anything a display engine or an input
method might add), so enumerating what to *keep* would silently drop widths.
The failure mode of a blacklist — a new modification-ish property appearing and
signalling — is loud, and the same fix applies.

### A `post-command-hook` that signals uninstalls itself

Emacs responds to an error in `post-command-hook` by **removing the offending
function from the hook**. Point-following runs there, so one signal disabled it
for the rest of the session, in every buffer, leaving nothing behind but a
single message that a busy buffer scrolls away in seconds. The observable
symptom was a feature that worked in one buffer and was permanently dead in
another, with no error in sight.

`md-table-align--follow-point` now catches its own errors and reports once per
buffer, latching on `md-table-align--follow-failed`. Degrading to "the table
stopped following point" beats silently uninstalling the feature, and reporting
once keeps a persistent fault from spamming the echo area on every keystroke.

This is defence in depth rather than a fix for the above — with measurement
repaired there is nothing left to signal — but the failure mode is bad enough,
and cheap enough to close, to be worth closing regardless.

### `hscroll-margin` made the explicit scroll commands no-ops

Unrelated to read-only, and present since v4: `C-x <` and `C-x >` did nothing in
any buffer.

`md-table-align--point-into-view` parked point on the viewport's cut, exactly at
`x = offset`. `md-table-align--desired-offset` then saw point within
`hscroll-margin` (default 5) of the left edge on the very next command and
scrolled back — and with the default `hscroll-step` of 0 "scroll back" means
re-centre, which clamps to zero. Every press scrolled and was undone before
redisplay.

Point is now placed `hscroll-margin` *inside* the edge, via a
`md-table-align--margin` helper shared with `desired-offset` so the two halves
cannot drift apart again. The margin is applied only at an edge the viewport can
actually scroll past: at offset zero there is nothing to the left to reveal, so
pushing point off the first column would be gratuitous.

### Why the tests missed all of this

`md-table-align-tests--scroll` calls `md-table-align-hscroll-left` as a plain
function. `post-command-hook` never ran, so every scrolling test asserted on a
state the real command loop discarded a moment later. The suite was blind by
construction to any interaction between a command and the hook.

Tests added: a `read-only`-text-property fixture covering measurement,
alignment, clipping and scrolling; two tests that point-following survives and
recovers from a signal without leaving the hook; and four that drive `C-x <` /
`C-x >` through `execute-kbd-macro`, so the command loop and its hooks are in
the loop being tested.

## Face remapping arriving after layout (v4.2)

`md-table-align-mode` before `mixed-pitch-mode` produced a misaligned table;
the other order was fine. The asymmetry is the bug.

### Why order mattered

Measurement was always right: `string-pixel-width` runs against the buffer, so
`face-remapping-alist` is in force and the widths reflect what the text really
renders as (see "Width measurement"). What was missing is *invalidation*.
Layout stores pixel targets in `:align-to`, which are absolute numbers frozen at
layout time. `mixed-pitch-mode` arriving afterwards remaps the buffer's `default`
face, every glyph changes width, and those frozen targets no longer describe the
grid the text now needs.

Nothing noticed. `jit-lock` invalidates on buffer *text* changes and a face
remapping is not one; the re-fit hooks watched window geometry only. Measured on
a stand-in for a proportional font, the same buffer laid out as `(0 16 28)` when
remapped first and `(0 9 16)` when remapped afterwards — and a command did not
recover it, while a window resize and a manual `md-table-align-clear` +
`md-table-align-buffer` both did.

That last observation settles the mechanism: the existing clear-and-refontify
path is already correct and already lazy. It needed a trigger, not a rewrite.

### Generalising the re-fit guard

`md-table-align--refit` compared the window width against
`md-table-align--layout-width` and re-rendered on a change. Width is not the
only input a layout depends on, so the scalar becomes a **layout key**:

```elisp
(cons (and md-table-align-hscroll width) face-remapping-alist)
```

Re-fit when the key changes. Window width still only participates when
`md-table-align-hscroll` is on, exactly as before — with clipping off, width
does not affect the grid and a resize should not cost a re-render. Face
remapping always participates, because it always changes the grid.

The variable is renamed `md-table-align--layout-key` rather than reinterpreted.
A live session holding the old scalar in `--layout-width` would otherwise have
it silently compared against a cons, which is the trap the repository
conventions call out for `defcustom` and which applies just as well here.

### Trigger: `post-command-hook`, not a variable watcher

`add-variable-watcher` on `face-remapping-alist` was considered and rejected.
Watchers are per-symbol and global, so every buffer in the session using face
remapping — a great many — would call into this package. Worse,
`mixed-pitch-mode` builds its remapping through repeated
`face-remap-add-relative` calls, so a watcher fires many times per activation
and needs debouncing on top.

`post-command-hook` is already in use for point-following, is already
buffer-local to buffers with the mode on, and is debounced by construction: one
check per command, however many times the remapping was mutated inside it. The
check is an `equal` against a usually-nil alist plus a `window-body-width` call.

The cost is that a remapping installed outside the command loop — from a timer
or a process filter — is picked up on the next command rather than instantly.
For a font change that is imperceptible.

The two per-command jobs are folded into one hook entry,
`md-table-align--post-command`, so they share the single error guard added in
v4.1 and run in a defined order: re-fit first, since point-following consults
the metrics that re-fit invalidates. `md-table-align--follow-point` remains the
unguarded body, which is also what the tests drive directly.

### What this does not cover

A change to the *underlying* faces rather than the buffer's remapping of them —
loading a theme, `set-face-attribute` on `fixed-pitch`, a frame font change —
also changes rendered widths and is not in the layout key. Catching it needs a
measured fingerprint (the pixel width of a reference string) rather than a
comparison of configuration, which costs a measurement per command instead of an
`equal`. Deferred: it is a rare, deliberate, session-wide act, after which
`md-table-align-clear` and `md-table-align-buffer` — or any edit — restore the
grid. Recorded under "Known limitations".

## Vertical records view (v5)

A toggle, per table, between the normal horizontal layout and a vertical one
modelled on psql's `\x` expanded display: each data row becomes a block of
`label: value` lines under a record separator, with the labels taken from the
header row, rendered bold, and the values aligned to a common column:

```
-[ row 1 ]---
a: value1
b: Value2
c: value3
-[ row 2 ]---
a: value4
b: value5
c: value6
```

Wide tables are the obvious beneficiary — a vertical record is never wider
than its longest single value — but the toggle is a reading preference, not a
fitting rule, so it is a command rather than anything automatic.

### Display-only, like everything else here

A textual transformation was rejected without much contest: it fails in the
read-only transcript buffers this package exists to serve, it dirties files,
and the vertical form is no longer a Markdown table, so toggling back needs a
bespoke parser for a format nothing else understands. The vertical view is a
*rendering* of the same buffer text, produced by the same overlay machinery,
and toggling back merely re-lays the table out horizontally.

### Feasibility

The insight that makes this cheap: a vertical layout does not reorder buffer
text. Reading the buffer left to right, row by row, already visits the values
in exactly the order the vertical view presents them. Only the labels appear
out of buffer order — repeated once per record — and labels are *synthesized*
strings, not buffer text. So the values stay real, visible buffer text (point
motion, isearch and editing keep working in them), and everything injected is
overlay strings, which v1 already established never dirty a buffer.

Three primitives carry the layout. Two were verified in earlier rounds; the
third was probed in a real TTY frame before this design was committed:

| # | Question | Result |
|---|----------|--------|
| 1 | Does an injected `"\n"` in an overlay string create a real visual line break? | Yes — v3/v4, under both `truncate-lines` and `word-wrap` |
| 2 | Does `display ""` over a *multi-line* region (newlines included) remove those screen lines entirely? | **Yes** — header + delimiter rows collapsed to zero screen lines |
| 3 | Is a stretch glyph embedded in an overlay string honored? | **Only in a `before-string`.** Inside a `display` string it is silently inert — see below |

The probe rendered a three-column row as one separator line plus three
`label: value` lines — `count-screen-lines` reported 4 for the one buffer
line — with surrounding prose unmoved.

Primitive 3 took three probes to get right, and the first gave a wrong
answer worth recording (see "Instruments matter" under v2 for the pattern).
The initial probe embedded the stretch in a `display` string, asked for
column 3, and saw the text land on column 3 — but 3 was also the *natural*
width of "label plus one space", so the probe could not distinguish a working
stretch from an ignored one, and it was ignored: Emacs does not process the
`display` properties of text inside a `display` string. The e2e tests, whose
fixture has labels of different lengths, caught it immediately. A second
probe with a target nothing lands on naturally confirmed every variant inert
(`:align-to` in both forms, `:width`, with and without a preceding newline).
A `before-string`'s text *does* get its `display` properties processed — it
is what every `md-table-align--pad` stretch already rides on — and a third
probe confirmed the full injection works there, including alongside a
`display ""` on the same overlay. When probing a layout primitive, pick a
target that nothing reaches naturally.

### Mechanism

For a table toggled vertical, layout places:

1. **One hiding overlay** over the header row and delimiter row, from the
   header's line start to the first data row's line start, newlines included
   (primitive 2). The header text lives on as the labels; the delimiter row's
   alignment markers are meaningless vertically and vanish with it.
2. **Per cell, one overlay** covering the span from the previous cell's
   content end to this cell's content start — the region holding the pipe and
   its padding, never empty since it contains at least the pipe. Its
   `display` is `""`, hiding the span, and its `before-string` carries the
   injection: `"\n"` + a stretch to the table's indent + the bold label + a
   stretch to the value column (primitive 3 — the string must be a
   `before-string`, since a `display` string's own `display` properties are
   inert). For a row's first cell the string opens with the record separator
   line instead of the bare newline.
3. **A `display ""` overlay** over the closing pipe and trailing whitespace.

The value column is the indent plus the widest label plus
`md-table-align-vertical-gap` spaces, measured in pixels with the same width
function as everything else, so the v2 lessons (face remapping, CJK,
proportional fonts) carry over unchanged.

*Deviation, recorded after v5 shipped:* the gap was originally one space,
hardcoded — the psql tradition. In use it read as no separation at all: every
value starts at the same column, so the longest label gets exactly the
minimum, and a bold label ending in a colon followed by one space looks
joined to its value (screenshot review, `hacks/vertical-table.png`). The gap
is now a `defcustom` defaulting to two spaces. Labels come
from the header cells' buffer text, re-propertized with the label face; a
column with no header cell — ragged tables — falls back to its 1-based column
number.

Cells that are empty or absent get their label line like any other, with
nothing after the colon: the spans between pipes still exist, so the overlay
placement is identical.

A long value wraps at the window edge like prose. That is correct rather than
tolerated: a vertical record is a paragraph-shaped thing, its continuation
lines are ordinary visual wrapping, and no column grid exists to destroy —
which is why none of the viewport machinery applies.

### Per-table state

`md-table-align--vertical-tables` holds one marker per toggled table, at the
table's start. Layout consults it exactly the way the hscroll offset consults
its marker: a `pipe_table` node whose start equals a marker position is laid
out vertically. Markers survive edits elsewhere in the buffer, and jit-lock
re-layout — which re-runs on every edit inside the table — reapplies the
vertical layout with no extra plumbing, the same way it reapplies an offset.

Unlike the hscroll offset, vertical state is *meant* to persist while point is
elsewhere — a table you flipped stays flipped — which is why it is a list
rather than a single marker, and why leaving the table resets nothing.

### Interaction with the horizontal machinery

- **The viewport does not apply.** A vertical table has no column grid to
  clip or scroll; `md-table-align--layout-table` branches before any viewport
  is computed. Point-following and the explicit scroll commands skip vertical
  tables, so `C-x <` falls through to `scroll-left` as it does outside a
  table.
- **Toggling a scrolled table to vertical drops its offset.** The offset is
  meaningless in the vertical layout, and holding it silently would make the
  table come back scrolled — the "mysteriously missing first columns" problem
  the offset-reset rule exists to prevent.
- **Re-fit triggers carry over.** The layout key already invalidates on face
  remapping; the value column is measured, so it re-lands correctly. Window
  width does not participate for vertical tables any more than it did with
  hscroll off.
- **The toggle enables the mode if needed.** Toggling implies wanting the
  display machinery; failing with "enable the mode first" would be pedantry.
  With no parser it refuses the way the mode does.

### Interface

- `md-table-align-toggle-vertical` — command; toggles the table at point.
  No default binding.
- `md-table-align-vertical-record-format` — separator format, default
  `"-[ row %d ]---"`, `%d` the 1-based record number.
- `md-table-align-vertical-gap` — spaces between the widest label and the
  value column, default 2.
- Faces: `md-table-align-vertical-label` (inherits `bold`) and
  `md-table-align-vertical-record` (inherits `shadow`).

### Testing

All e2e in the TTY frame, as ever:

- after toggling, each value renders on its own screen row, all at the value
  column, and a data row's buffer line occupies columns + 1 screen lines;
- the header and delimiter rows occupy no screen lines;
- `buffer-string` is unchanged and `buffer-modified-p` nil; the same holds
  over `read-only` text properties;
- toggling back restores the horizontal grid exactly;
- an edit inside a vertical table re-renders it still vertical;
- the toggle is per-table: the other table's grid is untouched;
- a wide table toggled vertical in a narrow frame gets no clip overlays and
  no offset;
- label strings carry the label face;
- cursor motion through a vertical table driven by real key events leaves the
  `post-command-hook` machinery installed and unlatched.

### Known limitations (v5)

- A stale marker — the table it named was deleted and a *different* table's
  start later lands on exactly that position — would flip the newcomer
  vertical. The same class of staleness the hscroll marker accepts, with the
  same answer: toggling it back costs one command.
- Point inside the hidden header or delimiter row renders at the record
  separator, where the collapse put it. Values — the text one actually moves
  through — are unaffected.

### Validation against implementation (v5)

14 tests added; 143 pass in the TTY frame; `make compile` is clean with
`byte-compile-error-on-warn`. Geometry read back from `posn-at-point` against
a three-column, two-row fixture: every value renders on its own screen row at
the common value column; a data row's buffer line occupies four screen lines;
the header and delimiter rows occupy none, so the prose below the table lands
nine rows under the prose above it; toggling back restores the horizontal
grid exactly; an edit re-renders the table still vertical; the second table
in the buffer keeps its grid; everything holds over `read-only` text
properties with the buffer unmodified throughout.

#### Deviations

**The injection rides a `before-string`, not a `display` string.** The design
as first committed had each cell's span replaced by a `display` string
carrying the newline, label and stretches. That mechanism does not exist:
Emacs ignores `display` properties on text inside a `display` string, so the
stretches were inert and the labels simply abutted their values. The span is
hidden with `display ""` and the injection moved to a `before-string` on the
same overlay, whose text does get its `display` properties processed. The
feasibility section records how the initial probe missed this. One helper,
`md-table-align--inject`, encapsulates the pairing.

Everything else — the per-table markers, the viewport guards, the toggle
command's offset handling, faces and record format — held up as designed.

## Known limitations

- The delimiter row is character-quantised, as above.
- Changing the underlying faces — loading a theme, `set-face-attribute` on
  `fixed-pitch`, a frame font change — is not noticed, only the buffer's
  `face-remapping-alist` is (see "Face remapping arriving after layout"). Any
  edit, or `md-table-align-clear` then `md-table-align-buffer`, re-measures.
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
  `buffer-modified-p` nil, and `buffer-read-only` set. (Read-only via a text
  property did *not* hold up — see "Read-only text and command-loop
  robustness".)
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

## Measuring against live fontification (v5.1)

Prompted by `md-table-inline`, which gives table cells real inline markup —
faces that change glyph widths, and `invisible` delimiters that change what a
cell renders at when `markdown-ts-hide-markup` is on. Measurement has always
sampled text properties (that is the point of pixel measurement), but three
pieces of plumbing quietly assumed properties do not change between passes:

**Alignment now runs after font-lock inside a shared jit-lock pass.**
`jit-lock-register` prepends to `jit-lock-functions`, so `md-table-align--jit`
— registered after font-lock's own function, since the minor mode comes up
after the major mode — ran *first*, measuring cells whose faces and
invisibility that same pass was about to (re)write. The mode now re-adds its
hook entry at depth 90. `jit-lock-unregister' is unaffected: it removes by
function, not by depth.

**The metrics cache keys on `buffer-modified-tick`.** It keyed on
`buffer-chars-modified-tick`, chosen so cursor motion (which consults the
grid every command) could not trigger re-measurement — but property-only
writes advance the chars tick not at all, so a fontification pass that
changed what cells measure left the cache stale. The plain modified tick
advances on property writes — `with-silent-modifications`, which font-lock
wraps them in, spares the modified *flag* but not the tick — while still
standing still during pure cursor motion, so the cache keeps paying for the
case it was built for.

**`buffer-invisibility-spec` joined the layout key.**
`markdown-ts-toggle-hide-markup` works by toggling a member of that spec; the
properties stay put. Width and face remapping were already in the key for
exactly this shape of reason — state that redisplay consults but no tick
records — and the post-command re-fit now notices the toggle the same way it
notices `mixed-pitch-mode` arriving.

Measurement itself needed no change: `string-pixel-width''s work buffer has
the default `buffer-invisibility-spec' of `t', under which any non-nil
`invisible' property hides, so a hidden delimiter measures at zero exactly
when the real buffer draws it at zero, and when hiding is off the property
does not exist at all (font-lock manages it via
`font-lock-extra-managed-props').

## Many wide tables: open/resize lockups (v6)

A file of 8 tables with ~900-char rows locked Emacs up on open and on every
window resize. Profiled in a TTY frame (harness now lives in
`tests/bench-tables.el`; findings in
`docs/many-tables-open-resize-performance.md`): the elisp is fast, but it
issued ~13k `string-pixel-width` calls to open the file and ~12k per window
operation — and in a GUI each call does real font shaping at 0.1–1 ms.  The
volume, not the per-call cost, is the bug.  Three sources, three changes:

**The metrics cache is per-table, and keys on what measurement sees rather
than on the modification tick.** The single-entry cache meant that with more
than one table every layout pass evicted the previous table's entry — nothing
was ever cached across passes (21 full measure passes for 8 tables on open).
The variable is renamed (`md-table-align--metrics-caches`, a hash keyed by
table start) so a stale binding of the old cons in a live session goes inert,
per the repo's reload rules.

The tick had to leave the key for the cache to survive a resize.  A width
change re-fits by re-running the shared jit-lock pass, and font-lock's
property rewrites bump `buffer-modified-tick` even when they re-apply
identical faces — so on a pure resize, which changes nothing any cell
measures, every cell re-measured anyway.  The key is now a summary of what
measurement actually consumes: the table's text plus its intervals of the
display-affecting properties (`face`, `display`, `invisible`,
`composition`), hashed with `sxhash-equal`.  Hashing a few KB of text per
lookup is C-speed noise next to a single shaping call; re-fontification with
identical results now hits, and any change measurement could see still
misses.  This supersedes the v4.1 tick-vs-chars-tick reasoning above: both
ticks were proxies for "did the measurable content change", and the key now
tests that directly.  What the key cannot see — face *remapping* and
`buffer-invisibility-spec`, which change rendered widths without touching
properties — was already the layout key's job: a re-fit whose non-width
components changed drops the metrics caches wholesale; a pure width change
keeps them.

**The clip-boundary search is a binary search.** `md-table-align--split-at`
walked the boundary one character at a time, measuring `[beg, beg+k)` for
k = 1, 2, 3… — O(chars) shaping calls on strings of O(chars) length, per
straddling cell, per row, per layout, and every row of a 900-char table
straddles the viewport at any realistic width.  The measure is monotone
non-decreasing in the end position (adding a character never narrows a
string), which is the same assumption the linear walk already made, so the
largest position that fits is found by bisection in O(log chars) measures.

**Enabling the mode defers layout to jit-lock.** The mode body called
`md-table-align-buffer` — every table in the buffer, eagerly, including ones
never scrolled into view, and *before* first fontification, so the visible
tables were measured once unfontified and again after font-lock ran.  It now
calls `jit-lock-refontify`, which serves the original purpose of that call
(text fontified before the handler registered would otherwise never reach
it) while keeping the work lazy and after font-lock.  `md-table-align-buffer`
remains eager for interactive use.

Not changed: a table spanning several jit chunks is still re-laid once per
chunk, and a width re-fit still re-runs font-lock over the visible region to
reach the jit handler.  Both are overlay-placement and font-lock costs, cheap
once the measurements they consume are cached; the benchmark keeps a
`layout-table` column so the count stays visible.

Regression guard: `make bench` (tests/run-bench.sh) runs open/resize/scroll
scenarios at a pinned 400x60 frame and reports call counts, which are
deterministic per fixture and code; recorded runs accumulate in
`tests/bench-results.md`.
