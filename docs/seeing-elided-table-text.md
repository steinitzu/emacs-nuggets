# Resolved: you can't see all the text in a fitted table

**Raised:** 2026-07-28, right after `md-table-align-fit-to-window` landed.
**Resolved:** 2026-07-28. Answer: **direction 2, horizontal scrolling.** Hiding
text with no way to reach it is not acceptable, so width capping is replaced by
a per-table horizontal viewport with `truncate-lines`-style scroll semantics.
Designed in `md-table-align/DESIGN.md` under "Horizontal scrolling (v4)"; not
yet implemented.

## The problem, as it stood

Fitting stopped wide tables wrapping, and that part worked. But it bought
alignment by **hiding text**. Reading a table where three columns end in `…`
tells you the shape of the data and not the data. The two escape hatches were
both poor: `C-h .` reveals one cell out of context, and widening the window is
exactly the thing you couldn't do.

## The decision

The policy question was "is hiding text acceptable at all, or must every
character stay reachable?" **Every character must stay reachable.**

Direction 1 (wrap cells into taller rows) was investigated first, because it is
the only option that hides nothing at all, and rejected — see below. Direction 2
answers the complaint at a fraction of the cost and reuses v3's overlay
machinery rather than replacing it. Direction 3 (reveal the cell at point) is
**subsumed**: with the viewport following point, the cell at point is visible by
construction, so it is dropped rather than deferred again. Direction 4 (shrink
the face) remains untestable here and unneeded.

Scroll semantics mirror what a `truncate-lines` buffer already does — continuous
and column-granular, viewport follows point, `hscroll-margin` and `hscroll-step`
honoured, `C-x <` / `C-x >` remapped inside a table. Nothing new to learn.

## Why direction 1 was rejected

Not for the reason the original note guessed. The blocking unknown it named —
whether injected newlines work under `word-wrap` — turned out **not to be the
obstacle**.

The obstacle is that `:align-to` cannot move text backwards, so screen order
must follow buffer order. A proper wrapped row needs screen order
`c1L1 c2L1 c3L1 / c1L2 c2L2 c3L2` against buffer order
`c1L1 c1L2 c2L1 c2L2 c3L1 c3L2`, which diverge as soon as **two** cells wrap.
Breaking cells in place gives a staircase, not a table.

It *can* be built, by hiding each over-long tail and re-emitting copies
row-major in a synthesized continuation string — verified working. But that
turns the package into something that re-emits text rather than positioning it,
and point inside a relocated tail collapses. Decisively, it does not even solve
the problem: a table with long cell text becomes a very tall table, which is no
more readable than a scrollable one.

## What is established — do not re-derive

All measured in a real TTY frame. The v3 rows are from the session that built
fitting; the v4 rows from the session that chose scrolling.

| Fact | Confidence |
|:-----|:-----------|
| Emacs has **no per-line or per-region wrapping control** — `truncate-lines` and `word-wrap` are buffer-level | Verified, 4 experiments |
| An overlay `display` *string* does **not** escape wrapping; it is laid out like text | Verified |
| Removing all break opportunities does not help — `word-wrap` falls back to char wrapping | Verified |
| Overlays accept a `window` property, giving genuine **per-window rendering** | Verified |
| Eliding a row's tail with an overlay `display` keeps it to one screen line | Verified |
| Point inside a span hidden by `display` renders **collapsed onto the overlay start** | Verified, twice |
| An injected `"\n"` breaks the line under **`word-wrap`**, not only under `truncate-lines t` | **Verified** — the v3 open question, now closed |
| `(space :align-to (N))` re-indents a continuation line to an absolute column | Verified |
| **`:align-to` cannot move text backwards** (align-to 5 from column 20 → stays at 20) | Verified — this is why direction 1 fails |
| A multi-line `display` string does occupy multiple screen lines | Verified |
| Hiding a row prefix with `display` `""` pulls the remainder to screen column 0 | Verified |
| Clipping table rows leaves surrounding **prose unmoved**, unlike native `hscroll` | Verified |
| A clipped row stays on **one screen line** under `word-wrap` | Verified |
| Scroll offsets must be computed in **aligned**, not buffer, coordinates | Verified — the buffer-column version visibly breaks the grid |
| Scaling the table's face `:height` to fit the window | **Untested** — GUI-only, and this sandbox has no display |

Environment constraint, unchanged: no X/Wayland display and no `Xvfb`, so
anything GUI-only cannot be validated in this repo's harness.

## Ruled out — don't revisit

- **Turning wrapping off for tables only.** Not possible; see the table above.
- **`truncate-lines t` buffer-wide, toggled by whether point is in a table.**
  Works, but every prose paragraph reflows on entering and leaving a table.
- **Inverting the default** — truncate buffer-wide and re-wrap prose by hand.
  Means reimplementing `fill` against every edit and resize.
- **Wrapping cells into taller rows.** See above. The mechanism exists; the
  layout does not follow, and the result would not be more readable.
- **Whole-column scroll steps.** Cannot reach the tail of a cell wider than the
  window, which reproduces the very problem this note exists about.
