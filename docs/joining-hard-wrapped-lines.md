# Open: joining hard-wrapped lines in md-prose-fill

**Raised:** 2026-09-02, from the first render of `md-prose-fill` against a
Markdown file rather than a chat transcript.
**Status:** open, deliberately deferred. Nothing is broken; the fill is
raggedier than it needs to be on source that is already hard wrapped.

## The question

Should `md-prose-fill` render the newlines *inside* a paragraph as spaces, so a
hard-wrapped paragraph is filled as one flow instead of a line at a time?

## What hard-wrapped source is

Two ways the same paragraph can sit in a buffer:

```
one logical line   Emacs has no way to switch wrapping off for part of a buffer, so a package…

hard wrapped       Emacs has no way to switch wrapping off for part of a buffer, so a package that
                   wants a comfortable measure for prose has to narrow the whole window, and every
                   table in it goes along for the ride.
```

One paragraph to the parser; three logical lines to the buffer. Chat
transcripts — what this package was built for — are the first kind. Checked-in
`.md` files are usually the second.

## Why it fills raggedly

`md-prose-fill--fill-paragraph` walks a paragraph one logical line at a time
and fills each independently, so every source line keeps its own ending and
whatever is left over after the last break becomes a stub:

```
source line 2 (78 columns), filled to 40:

  wants a comfortable measure for prose      ← 36
  has to narrow the whole window, and        ← 34
  every                                      ← 5, the stub
```

78 columns does not divide into two 40-column lines. Repeat per source line and
the right edge goes to pieces.

Filling per logical line is not an accident — it is also what stops a break
from being computed across a hard line boundary, which the current design notes
as deliberate. Joining replaces that reason rather than removing it.

## What this is *not*

It is not a regression this package introduced. Point `visual-fill-column-mode`
or `olivetti-mode` at the same file with a measure of 40 and the stubs are
identical: the display engine wraps each logical line at the margin, and the
leftover is just as short. The raggedness is inherent in filling hard-wrapped
source to a **narrower** measure than it was wrapped at.

What is true, and narrower: `md-prose-fill` is the only one of the three that
*could* fix it, because it already reaches individual characters. A margin has
no per-character hook — it can only move the wall.

## The fix, if it is taken

The mirror of the break. A break renders a space as `"\n"`; a join renders a
newline as `" "`:

```elisp
;; the newline, plus the continuation line's own prefix, become one space
(put-text-property newline join-end 'display " ")
```

The span must cover the newline **and** the next line's leading prefix — the
`  ` under a list item, the `> ` in a block quote — or the join doubles the
whitespace. With the paragraph joined into one flow, the existing fill runs
over it and the stubs go away.

Every newline inside a paragraph then becomes one decision rather than a fixed
boundary: **join it, or break there and leave it as it is.** That is a tidier
model than the present one, which is part of why this is worth doing eventually.

## What is established — do not re-derive

Verified in Emacs 31.0.90, 2026-09-02.

| # | Fact | Consequence |
|---|------|-------------|
| 1 | `visual-wrap--safe-display-specs` is exactly `(space-width min-width height raise)` | A display **string** is unsafe by construction — the checker assumes so explicitly |
| 2 | `visual-wrap-prefix-function` tests the display property at `pos-eol` and skips the line when it is unsafe | A joined line carries a display string at exactly that position, so the line is skipped |
| 3 | On an unsafe line it skips to the end of the whole unsafe run, not just one line | The entire joined paragraph loses its prefix, not one line of it |
| 4 | `visual-wrap--remove-properties` strips `wrap-prefix` over the whole region **before** that loop runs, unconditionally | Indents would *vanish*, not merely fail to appear |
| 5 | `visual-wrap-prefix-mode` registers with `add-hook … 'append` (depth 90); `md-prose-fill` registers at depth 95 | We already run **after** it, so taking prefix duty over is possible |
| 6 | `visual-wrap--remove-properties` does not touch `line-prefix` | The existing break machinery is unaffected by any of this |

Facts 1–4 are the obstacle; fact 5 is why it is surmountable.

## What it would cost

Three things, in order of how much they bite.

1. **Owning the wrap prefix.** Because of facts 1–4, `md-prose-fill` would have
   to compute the prefix itself for a joined paragraph — `fill-match-adaptive-prefix`
   at the paragraph start — and set both `wrap-prefix` and `line-prefix`, rather
   than borrowing what `visual-wrap-prefix-mode` computed. Fact 5 says the
   ordering works. It is still a job we currently borrow and would then own,
   which is the real increase in surface area.

2. **The fill loop becomes paragraph-scoped.** `md-prose-fill--fill-line` is
   per logical line today, with the column budget resetting at each one. The
   scan would have to run across newlines, treating a joined one as a space of
   width 1.

3. **It changes what the package claims.** Today it only ever *adds* breaks:
   the rendering is always a subset of what the buffer says, which is an easy
   thing to defend in a read-only buffer. Joining means the display no longer
   corresponds line-for-line to the text.

## Decision

Deferred. It buys nothing in the transcript buffers this package is used in —
those hold long unwrapped lines — and it is a design pass with its own probe
rather than a patch.

**Revisit when** `md-prose-fill` is being used on checked-in Markdown often
enough for the ragged edge to be a daily annoyance.

**Probe first:** whether `md-prose-fill` taking over `wrap-prefix` for a joined
paragraph actually survives a `jit-lock` pass in practice — fact 5 says the
depths are right, but the interleaving of the two handlers over a region that
one of them skips has not been watched.

See also `md-prose-fill/DESIGN.md` ("Known gap: hard-wrapped source") and
`docs/per-region-wrap-width.md` for why the injected break exists at all.
