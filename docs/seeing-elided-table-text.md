# Open question: you can't see all the text in a fitted table

**Raised:** 2026-07-28, right after `md-table-align-fit-to-window` landed.
**Status:** open. Nothing has been decided or built beyond what is in
`md-table-align/DESIGN.md` under "Fit to window (v3)".

## The problem

Fitting stops wide tables wrapping, and that part works. But it buys alignment
by **hiding text**, and it is not clear that is a good trade. Reading a table
where three columns end in `…` tells you the shape of the data and not the
data. The two escape hatches that exist today are both poor:

- `C-h .` (`display-local-help`) reveals one cell, as a message, out of context.
- Widening the window reveals everything, but that is exactly the thing you
  couldn't do — it's why the table was fitted.

So the honest framing is: **v3 solved wrapping, and traded it for a new
problem.** Whether that is a net win is undecided. It may be that fitting
should not default to `t` until there is a real way to read the hidden text.

## What is already established — do not re-derive

All of this was measured in a real TTY frame during the session that built v3.
`md-table-align/DESIGN.md` has the detail; this is the index.

| Fact | Confidence |
|:-----|:-----------|
| Emacs has **no per-line or per-region wrapping control** — `truncate-lines` and `word-wrap` are buffer-level | Verified, 4 experiments |
| An overlay `display` *string* does **not** escape wrapping; it is laid out like text | Verified |
| Removing all break opportunities does not help — `word-wrap` falls back to char wrapping | Verified |
| Overlays accept a `window` property, giving genuine **per-window rendering** | Verified (49- and 50-column windows showing one buffer rendered a row at 1 and 2 screen lines) |
| Eliding a row's tail with an overlay `display` keeps it to one screen line | Verified |
| Point inside an elided span renders **collapsed onto the ellipsis** (char 45 → column 41) | Verified |
| Under `truncate-lines t`, an injected `"\n"` — as `display` *or* `before-string` — creates a real visual line break | Verified, **but only under `truncate-lines t`**; never tested under `word-wrap` |
| Scaling the table's face `:height` to fit the window | **Untested** — GUI-only, and this sandbox has no display |

Note the environment constraint: there is no X/Wayland display and no `Xvfb`
here, so anything GUI-only cannot be validated in this repo's harness. The TTY
frame cannot scale font heights.

## Candidate directions

Roughly in order of how much of the problem they solve.

### 1. Wrap cell content instead of eliding it

Render an over-wide table as a *taller* table — each cell's text wrapped inside
its column, rows spanning several screen lines. **Nothing is hidden at all**,
which is the only option here that fully answers the complaint. It is what
every non-Emacs Markdown renderer does.

The mechanism plausibly exists: injected `"\n"` display properties do create
visual line breaks. But that was verified under `truncate-lines t`, and fitting
runs under `word-wrap`, so **step one is re-running that experiment under
`visual-line-mode`**. Even if it holds, this is by far the largest option —
multi-line row layout, continuation-line indentation to keep the column grid,
and every existing alignment overlay needs to cope with rows that are no longer
one line. Probably a v4 in its own right rather than an increment.

### 2. Horizontal scrolling for tables

Elide from the **left** as well as the right, driven by a command — so a table
scrolls sideways within its window. Native `hscroll` cannot do this (it needs
`truncate-lines`), but we own every overlay, so we can. All the text becomes
reachable, one screenful at a time, and alignment is preserved throughout.

Moderate size, and it composes with what exists rather than replacing it. This
is the best effort-to-payoff ratio of the four.

### 3. Reveal the cell at point

Already designed and deliberately deferred — see "Deferred: reveal the cell at
point" in `DESIGN.md`. The cell containing point is never elided, so moving
through a table reveals cells as you go. Cheapest of the four, and it is what
makes the feature tolerable for *editing* rather than just reading.

Partial by construction: you see one cell at a time and never the whole row.
Good complement to 2, not a substitute.

### 4. Shrink the table's face to fit

Scale the table region's `:height` by `window-width / table-width`. Nothing is
hidden and nothing wraps. Rejected as a *general* answer because it becomes
unreadable past roughly 0.7, and it is GUI-only — but as a **first resort for
tables that only slightly overflow** it is strictly better than eliding, and it
would fall back to 2 or 3 when the ratio gets too small.

Blocked on being unable to test it here.

## Ruled out — don't revisit

- **Turning wrapping off for tables only.** Not possible; see the table above.
- **`truncate-lines t` buffer-wide, toggled by whether point is in a table.**
  Works, but every prose paragraph in the buffer reflows on entering and
  leaving a table. Too jarring.
- **Inverting the default** — truncate buffer-wide and re-wrap prose by hand
  with injected newlines. Mechanically possible, but it means reimplementing
  `fill` against every edit and resize.

## Suggested next step

Decide the policy question before writing code: **is hiding text acceptable at
all, or must every character stay reachable?**

- If reachable-is-required → direction 2, with 3 folded in.
- If hiding is acceptable and this is really about polish → direction 3 alone,
  which is small and already designed.
- If the answer is "the table should just be shorter and wider" → direction 1,
  and budget for a real piece of work.

Until that is settled, consider whether `md-table-align-fit-to-window` should
default to `nil`.
