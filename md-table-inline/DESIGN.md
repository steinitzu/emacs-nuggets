# md-table-inline — inline markup inside Markdown table cells

## Problem

In `markdown-ts-mode`, inline markup inside a pipe table cell is dead text.
A `` `code span` ``, `**emphasis**` or `[link](url)` in a cell gets no face,
and `markdown-ts-toggle-hide-markup` leaves its delimiters visible — the
backticks sit there raw while the same markup one line above the table hides
correctly. Observed in `hacks/vertical-table.png`, where every cell value is
a code span and every backtick shows.

## Root cause

`markdown-ts-mode` runs two grammars: `markdown` for block structure and
`markdown-inline` for spans. The inline parser only sees regions the range
rules hand it, and the mode's one rule (`markdown-ts--range-settings`) is:

```elisp
(treesit-range-rules
 :embed markdown-inline
 :host markdown
 :local t
 ((inline) @markdown-inline))
```

Table cells never match it. The `tree-sitter-markdown` block grammar parses a
table into `pipe_table_cell` nodes with *no* `inline` child:

```
(pipe_table
  (pipe_table_header (pipe_table_cell) (pipe_table_cell))
  (pipe_table_delimiter_row ...)
  (pipe_table_row (pipe_table_cell) (pipe_table_cell)))
```

so no inline parser ever covers a cell, no `code_span`/`emphasis`/link node
ever exists there, and every inline font-lock rule — face and markup-hiding
alike — has nothing to fire on. Upstream `markdown-ts-mode` even documents
that cells "can contain the usual Markdown inline" (its own commentary), so
this reads as an oversight, not a decision. Worth an upstream report; this
package is the fix for the Emacs we run today (31.0.90).

## Fix

Append one more range rule to the buffer's `treesit-range-settings`:

```elisp
(treesit-range-rules
 :embed 'markdown-inline
 :host 'markdown
 :local t
 '((pipe_table_cell) @markdown-inline))
```

`:local t` matches the upstream rule: each captured node gets its *own*
little parser, so this adds parsers per cell without touching the ranges of
the per-`inline`-node parsers the mode already maintains — two `:local`
settings for the same embed language do not interfere. Per-cell parsers also
mean a cell is parsed in isolation, which is exactly right: inline state must
not bleed across cells, and a cell's bounds already exclude its pipes.

Everything downstream is upstream's own machinery, untouched: the
`markdown-inline` font-lock rules fontify whatever nodes exist wherever that
parser has ranges, and the hide-markup fontifiers apply `invisible`
text properties that `markdown-ts--set-hide-markup`'s invisibility-spec
toggle controls. Verified in a batch probe: before the rule, a `` `POST` ``
cell has no invisible property and only table faces; after it, the backtick
carries `invisible markdown-ts--markup` and the span
`markdown-ts-code-span`.

`pipe_table_delimiter_cell` is deliberately not captured — a delimiter cell
holds `---` dashes, and handing those to the inline parser invites false
matches for no benefit.

### Rejected alternatives

- **Advising `markdown-ts--range-settings`** to return the extended rule.
  Global state for a per-buffer feature, and the advice only takes effect for
  buffers initialized after it — existing buffers would need their settings
  rebuilt anyway, which is the whole of the direct approach.
- **Re-implementing cell fontification** with our own queries and fontifiers.
  Duplicates upstream's faces, hide-markup behaviour and its
  `font-lock-extra-managed-props` bookkeeping, and drifts as upstream moves.
  The range rule reuses all of it.
- **Waiting for upstream.** Right thing to also do, wrong thing to only do.

## Switching off

Enabling is rule + `font-lock-flush`; jit-lock refontification updates ranges
lazily and the managed-props machinery (`invisible`, `display`, … are in
`font-lock-extra-managed-props`) keeps property cleanup automatic.

Disabling is the part with a trap. Removing the rule does not remove the
per-cell parsers it created: `treesit-update-ranges` garbage-collects a local
parser's overlay only when its timestamp is older than the buffer's
chars-modified tick, so in an unmodified buffer the orphaned parsers survive
— and font-lock consults local parsers through their overlays, so cells would
just stay fontified. The mode therefore deletes every local
`markdown-inline` parser itself, then runs `treesit-update-ranges` over the
buffer so the surviving upstream rule recreates the legitimate per-`inline`
parsers, then flushes. Deleting *all* of them rather than trying to tell
cell parsers from `inline`-node parsers is deliberate: recreating the
legitimate ones is one call, and distinguishing them is guesswork.

## Interplay with md-table-wrap

`md-table-wrap` draws every cell as a copy of its text, taken with
`buffer-substring` after the row is fontified. The faces this mode gives a
cell therefore ride along on the copy with no change to either package.
One case needed one: with this mode turned on *after* a table was drawn,
its `font-lock-flush` refontified rows whose copies were already built, and
md-table-wrap's jit-lock function only built unbuilt rows. It now rebuilds
a refontified row (see "Lazy building" in md-table-wrap's DESIGN.md).

md-table-wrap wraps by the raw text width, so hidden markup still takes
room in the column it is wrapped to. That is a known md-table-wrap
limitation, not something this mode can fix.

*Changed:* this section described `md-table-align` until that package was
retired (2026-11-03). It measured cells in pixels, so a hidden backtick
measured zero, and it added `buffer-invisibility-spec` to its layout key
so that toggling hide-markup re-aligned.

## Interface

- `md-table-inline-mode` — buffer-local minor mode; adds the range rule on,
  removes rule and parsers off. Refuses, with a message, in a buffer
  without both grammars.
- `global-md-table-inline-mode` — enables it in the modes named by
  `md-table-inline-modes` (default `markdown-ts-mode`).
- `md-table-inline-unload-function` — switches the mode off everywhere
  first, so `unload-feature` does not strip definitions out from under live
  range settings.

## Testing

E2e in the suite's real TTY frame, real `markdown-ts-mode`, nothing stubbed:

- a code span in a cell gets `markdown-ts-code-span`, and with
  `markdown-ts-hide-markup` its backticks go invisible;
- emphasis in a header cell is fontified;
- the copies md-table-wrap draws carry a cell's code-span face, whether
  this mode comes on before md-table-wrap or after it;
- switching the mode off restores upstream behaviour: no cell faces, no
  stray local parsers, and text under the table's `inline` nodes still
  fontified;
- buffer text stays byte-identical and unmodified throughout.
