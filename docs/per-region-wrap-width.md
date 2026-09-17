# Resolved: giving one region a different wrap width from another

**Raised:** 2026-09-02, from "can tables be excluded from `visual-fill-column`
in `markdown-ts-mode`?" — a full-screen window whose tables were being clipped
to half the screen because the prose measure had taken the other half.

**First answer:** 2026-09-02. **Invert the mechanism.** Stop narrowing the
window and narrow the *prose* instead, with a display-only line break. Designed
and implemented as `md-prose-fill`; see `md-prose-fill/DESIGN.md`.

**Reopened:** 2026-09-17. In live use `md-prose-fill` is glitchy, and the
approach is judged a dead end: it rebuilds the line breaker for *all* prose,
and every feature that touches prose (hidden text, code spans, hard-wrapped
source, variable pitch) becomes a new way for it to break. The question is back
to the original framing: keep `visual-fill-column`, and let tables and other
wide blocks **out of** its measure.

**Resolved:** 2026-09-17. **Margin spill** — see the section of that name
below. Keep the margins, and render the part of a table row that does not fit
the text area in the right margin, where a `display` spec is allowed to go.
Built into `md-table-align` (`md-table-align-spill`); see "Margin spill" in
[md-table-align/DESIGN.md](../md-table-align/DESIGN.md).

`md-prose-fill` is **retired**: the question it existed to answer has a better
answer, and its own approach — rebuilding the line breaker for all prose — was
glitchy in live use in exactly the way that predicts.

## Why the question has no direct answer

`visual-fill-column` and `olivetti` narrow text by setting **window margins**.
Margins come out of the window's text area, and text is never rendered in them:

```
margins  0/0   → window-total-width 80, window-body-width 80
margins 10/20  → window-total-width 80, window-body-width 50
```

So the narrowing is a property of the *window*, and no region of the buffer can
opt out of it. `md-table-align` budgets tables against
`(window-body-width window t)` (`md-table-align.el:494`), which is the narrowed
measure, so a wide table starts clipping and scrolling at half the screen.

This is the width-shaped version of what `seeing-elided-table-text.md` already
recorded for wrapping: Emacs has no per-line or per-region wrapping control.

## What is established — do not re-derive

Facts about the **retired** injected-break approach, kept because they are
properties of Emacs rather than of the package that used them. All measured in
a real TTY frame, 60 columns, `visual-line-mode` + `visual-wrap-prefix-mode`,
on a list item so there is a prefix to preserve. Probes are
`hacks/prose-fill-probe{,2,3}.el`.

| # | Question | Result |
|---|----------|--------|
| 1 | Does a `display` property of `"\n"` on a space break the line under `word-wrap`? | **Yes**, as a text property *and* as an overlay — identical rendering |
| 2 | Is the line after an injected break a **continuation** line, so `wrap-prefix` applies? | **No.** `epsilon` renders at column 0, not 2 — `visual-wrap-prefix-mode` does not compose for free |
| 3 | Is it then a **fresh** line, so `line-prefix` applies? | **Yes** — column 2, exactly as a natural wrap. This is the fix |
| 4 | Does `:align-to` work inside an injected `display` *string*? | **No** — inert, indents by one space. Same silent failure DESIGN records for `wrap-prefix` strings |
| 5 | Can the prefix be restored with literal spaces in the injection? | Yes, but only correct in a monospace face — `line-prefix` (3) takes the real `(space :align-to (N . width))` spec and is correct under variable pitch |
| 6 | Can the break be made *natural* by stretching the space to the right edge, so the wrap is a real continuation? | **No.** The wrap happens, but the first glyph of the next word is stranded in the last column of the previous row (`- alpha beta` / `   amma delta`, `g` at column 59) |
| 7 | Do several injected breaks in one paragraph work? | Yes — three breaks, each starting at the prefix column |
| 8 | Does the tail still wrap naturally at the window edge after the last injected break? | Yes, and that wrap keeps its `wrap-prefix` |
| 9 | Does the injection reach `buffer-substring`? | **No** — copy and yank are unaffected, so this is safe in read-only buffers |
| 10 | Does motion agree with the rendering? | Yes — `vertical-motion`, `beginning-of-visual-line` and `end-of-visual-line` all treat the injected break as a screen-line boundary |
| 11 | Does `visual-wrap-prefix-mode` clobber our `line-prefix` when it re-runs? | **No** — `visual-wrap--remove-properties` removes `wrap-prefix` and `min-width` only |

Finding 6 is the one worth keeping: "make the display engine wrap for you" looks
like the elegant answer and fails in a way that is easy to miss in a screenshot.

## The consequence that made the retired approach cheap

History, kept because it is the one thing margin spill gives up: the fill was
priced per window resize, and spilling is not.

The fill width is an **absolute column**, not a function of the window. So —
unlike `visual-fill-column`, which recomputes margins on every window-state
change — a resize invalidates nothing. `jit-lock` covers edits; geometry only
matters at the one threshold where the window becomes narrower than the fill
column, at which point the breaks are dropped and the window edge takes over.

## Rejected on the way

- **Margins that yield to tables** (drop to 0 while point is in a table).
  Cheap, and `md-table-align` already tracks table-at-point — but the whole
  buffer's prose reflows on every entry and exit, and it does nothing for a
  table you are merely reading. Triggering on visibility instead makes the
  margins flap while scrolling.
- **Shrinking the table's face** to fit more columns into the narrowed area
  (`md-table-align/DESIGN.md` "direction 4"). Partial relief, and does not
  answer the question.

## Margin spill (2026-09-17)

Width is still a window property, and buffer text still cannot render in a
margin. But a `((margin right-margin) STRING)` display spec *can*, on the same
screen row as the text carrying it. So keep the margins. Let a wide line's
**head** render in the text area as real buffer text, and hide its **tail**
there. Then re-emit the tail as a string in the right margin, starting at the
margin's first column so it continues the head.

Prose is untouched: `visual-fill-column` narrows it and Emacs wraps it, and
`visual-wrap-prefix-mode` still applies. Only lines wider than the text area
pay anything, and those lines are rare.

### What is established — do not re-derive

TTY frame, 80 columns, margins 0/30 (text area 50), captured with
`screen -X hardcopy` so the evidence includes what the margins show. Probes:
`hacks/margin-spill-probe.{el,sh}` for the mechanism and
`hacks/margin-spill-table.el` for the end-to-end check.

| # | Question | Result |
|---|----------|--------|
| 1 | Can a stretch glyph push text past the text area into the margin? | **No.** `:align-to right-margin` and `:align-to (+ right 10)` both clamp at the text-area edge, and the next character wraps |
| 2 | Does a right-margin string on an overlay `before-string` at bol render on that line's first screen row, flush with the text area? | **Yes.** Head in columns 0–49, tail from column 50, one screen row |
| 3 | Left margin, for `visual-fill-column-center-text`? | **Yes.** With margins 15/15, a `(margin left-margin)` head followed by the text area reads as one row from column 0 |
| 4 | Is a margin string clipped at the margin's width? | Yes, silently |
| 5 | Do space specs work *inside* a margin string? | **No.** `:align-to`, `:width N` and `:width (N)` all render as one space. Padding in the tail must be literal characters, so the spilled part only lines up exactly in a fixed-pitch face |
| 6 | Can two windows with different margins each get their own split? | **Yes.** Give the overlays a `window` property. Verified with 0/30 and 0/10 windows on one buffer |
| 7 | On a TTY, can the head use all of `window-body-width`? | **No.** The text area's last column is kept for the continuation glyph, even when everything after it is hidden. Split at `window-max-chars-per-line`, which leaves a **one-column seam**. Shifting the tail one column right across the seam loses nothing. Dropping that column misaligns nothing but loses a character |
| 8 | Does `invisible` hide a tail that starts where a `display` overlay starts? | **No.** `display` is handled first, so the display string still renders and wraps onto a new row. Hide with a `display ""` overlay at a higher `priority` than the ones it covers |
| 9 | Does it work against real `md-table-align` output? | **Yes.** Make `md-table-align--available-width` add the right margin. Then flatten each row as it renders (stretches to spaces, display strings, `before-string` pads) and split it. Header, delimiter, data rows, and a table wider than the whole window (clipped with the ellipsis) all render correctly across 80 columns, while prose wraps at 50 |
| 10 | A display string straddling the split (a delimiter's dashes)? | Must be cut in two. Put a higher-priority overlay on the span that shows only the head part, and hide from the span's end |
| 11 | Where does point render on a spilled cell? | **Collapsed** onto the split column. The same collapse as any `display`-hidden span. The cursor cannot be drawn in a margin |
| 12 | What does a click in the margin report? | `posn-area` `right-margin`, and `posn-object` is `(STRING . INDEX)`. Knowing the piece each string index came from maps a click to the exact buffer position |
| 13 | Two packages both put a right-margin string on one line? | They are **concatenated** in buffer order (`OTHERours`). Another margin user on a table row would push the tail out of line |
| 14 | Does the buffer change? | No. Copy and yank see the source text |

### What it would cost

- **Point on a spilled cell is invisible** (11). This is the main design
  question. `md-table-align` already tracks the table at point. The candidates
  are to un-spill that one table while point is in it, so it falls back to the
  scrolling viewport inside the text area, or to accept it for reading-mode
  buffers. Un-spilling only affects that table, which is what the rejected
  margin-flapping idea could not do.
- **Fixed pitch for the tail** (5). A variable-pitch table can't be padded
  exactly in the margin. In a GUI, a blank image of exact pixel width might
  pad it, since the manual says margin specs take images. **Untested:** this
  sandbox has no GUI.
- **GUI geometry is unverified.** With a fringe there is no continuation
  column to lose, but the fringe sits *between* the text area and the margin
  unless `fringes-outside-margins` is non-nil, which `visual-fill-column` sets by
  default. Expect no seam in that configuration, but this has not been
  checked.
- **The tail is a copy.** It gets faces copied at build time, but not
  `hl-line`, region highlighting, isearch highlighting or anything else that
  overlays the source later. Per NEWS.31, margin strings take any face
  attribute they don't specify from the `margin` face, so copied faces must
  be complete.
- **One window per layout**, the same limit `md-table-align` already has (6
  makes per-window spill possible, but its alignment overlays are shared by
  the buffer).
- **Other margin users** on the same row break alignment (13). The left
  margin is the crowded one (flymake, diff-hl). Spilling **right only** avoids
  most conflicts. It also reads naturally: tables start at the prose's left
  edge and run to the window edge.
- **Refit trigger.** The split depends on margin widths, which
  `visual-fill-column` changes on window-state changes. The layout key has to
  include them, and the refit has to run after `visual-fill-column` has set
  them.

### Two ways to build it

- **Inside `md-table-align`.** The row plan already knows every step's x
  position and text, so it can emit the head overlays and the margin string
  directly without flattening anything. It is the cheapest and most accurate
  option, but it only covers tables.
- **A generic spill pass** over any line the tree-sitter policy marks as a
  block: table rows, code-block lines. It flattens whatever the line renders
  as, which is what `hacks/margin-spill-table.el` does. For code, only lines
  that fit in text area plus margin should spill. Clipping longer ones would
  hide characters with no way to reach them, which
  `seeing-elided-table-text.md` ruled out. Those lines keep wrapping.
