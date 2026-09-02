# md-prose-fill — design

Fill Markdown prose to a column without narrowing the window, so tables, code
blocks and everything else keep the full screen width.

## The problem

`visual-fill-column-mode` (and `olivetti-mode`) give prose a comfortable
measure by setting **window margins**. Margins are subtracted from the window's
text area, so the narrowing applies to the whole window and nothing in the
buffer can opt out of it. In a `markdown-ts-mode` buffer with `md-table-align`
on, a wide table is budgeted against `(window-body-width window t)` — the
narrowed measure — so on a full-screen frame a table that would have fitted is
clipped to half the screen and has to be scrolled.

The ask was "exclude tables from the narrowing". That cannot be done: width is
a window property. What *can* be done is to stop asking the window to be narrow.

## The approach

Leave the window at full width and break prose lines early, in the display
only, at `md-prose-fill-column`. Tables, code blocks and headings are never
broken, so they render against the whole text area — exactly as they do with
`visual-fill-column-mode` switched off.

Two text properties per break, both display-only, so this works in the
`read-only`-text-property buffers this repo targets and never touches buffer
text:

| Property | Where | Value |
|:---------|:------|:------|
| `display` | the space being broken at | `"\n"` |
| `line-prefix` | that space's successor, to the end of the logical line | the `wrap-prefix` spec `visual-wrap-prefix-mode` computed for the line |

`display "\n"` makes a real screen-line break under `word-wrap`. The line that
follows it is *not* a continuation line, so `wrap-prefix` does not apply to it
and a list item's continuation would restart at column 0 — this was the
blocking unknown, and it fails. It is a *fresh* line, though, so `line-prefix`
does apply, and taking `visual-wrap-prefix-mode`'s own
`(space :align-to (N . width))` spec as the `line-prefix` reproduces the indent
exactly, including under a variable-pitch or scaled face.

Evidence for all of that, and for the alternatives that failed, is in
`docs/per-region-wrap-width.md`. The two worth naming here:

- Reproducing the indent with **literal spaces** in the injected string works
  but is only correct in a monospace face; `:align-to` inside an injected
  display string is silently inert, the same failure `md-table-align/DESIGN.md`
  records for `wrap-prefix` strings.
- Making the break **natural** — stretching the broken space to the right
  window edge so the next word overflows and wraps as a true continuation line
  — renders the wrap correctly but strands the next word's first glyph in the
  last column of the previous row.

## What gets filled

Only `paragraph` nodes, found with a compiled tree-sitter query, in the same
style as `md-table-align--tables`. That one node type is the whole policy:

- **Tables, fenced and indented code blocks** are not paragraphs, so they are
  never touched — which is the point of the package.
- **Headings** are not paragraphs either. They are short, and `md-heading-scale`
  scales them, so a column budget would be wrong for them anyway.
- **List items and block quotes** contain paragraphs, so their prose is filled
  and picks up the right indent from `visual-wrap-prefix-mode`.

A paragraph may span several logical lines (Markdown source is often hard
wrapped); each is filled independently, which is also what stops a break from
being computed across a hard line boundary.

## Break points

A column scan, not a pixel measurement:

1. The budget for the first screen line of a logical line is
   `md-prose-fill-column`; for every line after a break it is that minus the
   prefix indent, so **every rendered line ends at or before the same column**.
2. Walk forward accumulating `char-width`, remembering the last space seen.
3. When the accumulated width passes the budget, break at that last space and
   start the next segment after it.
4. A token wider than the whole budget — a long URL — has no space to break
   at. It is never cut: it overflows to the window edge and wraps there, which
   is what `fill-column` does too. Filling then **resumes** at the first space
   past the overflow, so one long token costs one long line rather than
   switching the fill off for the rest of the paragraph.

A space that already carries a `display` property from somewhere else is never
chosen as a break point, so this cannot fight `md-bare-url`, `md-file-anchor`
or `md-table-inline` over the same character.

The column scan assumes prose renders in a fixed-pitch face. That is true of
the transcript buffers this is for, and false under `mixed-pitch-mode`, where
the fill will be ragged. Pixel-accurate break points are possible — measure
with `string-pixel-width` per candidate — and are deliberately not in v1; the
cost is a measurement per word rather than a `char-width` per character.

## Invalidation

The fill column is absolute, so **a window resize invalidates nothing**. This
is the structural advantage over the margin approach, which recomputes on every
window-state change.

- **Edits** are covered by `jit-lock`, registered the way `md-table-align`
  registers: re-added at a late depth so the fill runs after `font-lock` and
  after `visual-wrap-prefix-mode` has had a chance to compute prefixes.
- **Geometry** matters at exactly one threshold. In a window narrower than
  `md-prose-fill-column` the injected breaks would land past the window edge
  and produce a ragged double wrap, so below that threshold the breaks are
  dropped entirely and the window edge takes over — which is the correct
  rendering for a narrow window anyway. `window-configuration-change-hook` and
  `window-state-change-functions` watch for the crossing, guarded by a stored
  state so an ordinary resize costs a comparison.

The threshold is evaluated against the **widest** window showing the buffer,
because the properties are buffer-wide while windows are not. A buffer shown in
one wide and one narrow window is filled for the wide one.

## Composition with `visual-wrap-prefix-mode`

The `line-prefix` value is read from the `wrap-prefix` text property
`visual-wrap-prefix-mode` installs. That mode deliberately registers itself at
the end of `jit-lock-functions`, so on a first pass over a chunk the property
may not be there yet; when the mode is on and the property is missing,
`visual-wrap-prefix-function` is called for the region first. It is idempotent,
and `visual-wrap--remove-properties` removes only `wrap-prefix` and `min-width`,
never our `line-prefix`, so its later pass does not undo the fill.

Without `visual-wrap-prefix-mode` the fill still works; continuation lines just
start at column 0, exactly as they would without the package.

## Interface

| Name | Default | Meaning |
|:-----|:--------|:--------|
| `md-prose-fill-column` | `80` | Column prose is filled to. |
| `md-prose-fill-modes` | `(markdown-ts-mode)` | Modes `global-md-prose-fill-mode` switches the mode on in. |
| `md-prose-fill-mode` | — | Buffer-local minor mode, lighter `" ¶"`. |
| `global-md-prose-fill-mode` | — | Globalized version. |

`md-prose-fill-column` is a new variable, so the live-reload trap in
`CLAUDE.md` does not apply; if its meaning ever changes from columns to
something else it must be renamed rather than reinterpreted.

`md-prose-fill-unload-function` switches the mode off in every buffer before
`unload-feature` runs, since the injected properties and the `jit-lock`
registration would otherwise outlive the code that removes them.

## Deviations from this design

Recorded after implementation.

- **The first line's budget needed a starting column.** A `paragraph` inside a
  list item starts *after* the marker, so measuring the budget from the node
  start left the marker's columns uncounted and the first line ended one column
  past the fill column. `md-prose-fill--fill-line` takes the column the line
  already occupies at its start and subtracts it. Caught by the test that
  asserts every rendered row ends inside the column, which is why that test
  exists separately from the one asserting the indent.

- **A long token stopped the fill instead of overflowing within it.** The
  first implementation returned "no break" both when the rest of the line fits
  and when a token is wider than the budget, and the caller's loop read the
  second as "this line is done" — so a URL turned the fill off for everything
  after it on that line. Found in live use, not by the suite, whose long-token
  fixture had nothing after the token. The two cases are now distinguished, and
  the overflow case resumes at the first space past the token.

- **`visual-wrap-prefix-mode` hands back a string here, not a spec.** Under
  `markdown-ts-mode` the `wrap-prefix` for a list item comes out as `"  "`
  rather than `(space :align-to (2 . width))`, because the marker matches
  `adaptive-fill-first-line-regexp`. `md-prose-fill--indent` handles both.
  Reusing whatever that mode computed — rather than deciding for ourselves —
  means the indent matches a natural wrap exactly either way.

## Known gap: hard-wrapped source

A paragraph is filled one logical line at a time, so a Markdown file that is
already hard wrapped at, say, 80 columns and is then filled to 40 breaks each
*source* line separately and leaves a short line where each one ended:

```
every
table in it goes along for the ride.
```

The transcript buffers this package is for hold long unwrapped lines, where
this does not arise, and it is unrelated to the width question the package was
built to answer — so it is recorded rather than fixed.

The fix is the mirror of the break: render the newline *between* two lines of
one paragraph as a space (`display " "`), joining them into one flow before
filling it. The obstacle is that `visual-wrap-prefix-function` skips any line
whose end-of-line `display` property is not on its `visual-wrap--safe-display-specs`
list, so a joined line would silently lose its wrap prefix — the same
composition problem this design solved for breaks, in the other direction.

## Open questions

- Joining hard-wrapped source lines, per the gap above.
- Pixel-accurate break points for `mixed-pitch-mode`, per "Break points" above.
- Whether headings should be filled after all when they are long enough to wrap.
- Whether the narrow-window threshold should fall back to filling at the window
  width rather than dropping the fill, which would keep the measure stable when
  a window is dragged narrow.
