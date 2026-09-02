# Resolved: giving one region a different wrap width from another

**Raised:** 2026-09-02, from "can tables be excluded from `visual-fill-column`
in `markdown-ts-mode`?" — a full-screen window whose tables were being clipped
to half the screen because the prose measure had taken the other half.

**Resolved:** 2026-09-02. Answer: **invert the mechanism.** Stop narrowing the
window and narrow the *prose* instead, with a display-only line break. Designed
and implemented as `md-prose-fill`; see `md-prose-fill/DESIGN.md`.

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

All measured in a real TTY frame, 60 columns, `visual-line-mode` +
`visual-wrap-prefix-mode`, on a list item so there is a prefix to preserve.
Probes are `hacks/prose-fill-probe{,2,3}.el`.

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

## The consequence that makes this cheap

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
