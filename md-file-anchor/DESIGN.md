# md-file-anchor — planning and design

Make a Markdown file link carrying a line or heading anchor —

    [builder.py:392–400](../src/builder.py#L392-L400)
    [notes](notes.md#deferred-decisions)

— open the file it names and jump to the anchored place, instead of visiting a
buffer for a file literally named `builder.py#L392-L400`.

## Problem

In `markdown-ts-mode`, `RET` (or a click) on a link whose destination is a
relative or absolute file path with a `#…` fragment opens a new, empty buffer:
the fragment is treated as part of the filename. The file exists; the link is
useless.

## What upstream does

`markdown-ts--make-link-button` builds every link button's action as a
four-way dispatch on the URL string (`markdown-ts-mode.el:891`):

```elisp
(cond
 ((string-prefix-p "#" url)          ; in-buffer fragment
  (markdown-ts--follow-fragment (substring url 1)))
 ((string-match-p "\\`mailto:" url)  ; mail
  (funcall url-mail-command ...))
 ((string-match-p "\\`[a-z]+:" url)  ; scheme -> browser
  (browse-url url))
 (t (find-file url)))                ; everything else is a file path
```

The last branch passes the URL through **verbatim**. There is no case for a
file path carrying a fragment, so `find-file` receives
`"sub/builder.py#L392-L400"` whole. Verified against real Emacs 31.0.90
through real `jit-lock` fontification: the button's action calls
`(find-file "sub/builder.py#L392-L400")`.

Unlike the md-bare-url defect, this is not a wrong test — it is a missing
feature. Upstream *has* fragment-following, but only for the in-buffer
`#heading` shape; a fragment attached to a path is simply never split off.

## Scope: take over one branch, leave the rest alone

Discovery, buttonization and key dispatch all work — as with md-bare-url,
this package must not re-derive them. What is missing is the behaviour of
one dispatch branch for one shape of URL: a scheme-less path that contains
`#`. This package supplies exactly that branch and passes every other URL
through untouched.

This is more feature than bug-fix, so unlike md-bare-url it is not written
to be deleted the day upstream changes — but the same self-neutralising
property is worth designing for: if upstream grows its own path-fragment
handling, its URLs will still route through this advice first, and the
sensible response is to delete this package, which the test canary
(see below) will prompt.

## Mechanism

A global minor mode installing one `:around` advice on
`markdown-ts--make-link-button`. When the URL is one this package handles,
build the button ourselves with our own action; otherwise call the original
untouched.

### The takeover predicate

`md-file-anchor--handles-p`: URL is a string, and

- does not start with `#` — that is upstream's in-buffer fragment branch;
- has no URI scheme, per RFC 3986: fails `` \`[a-zA-Z][-a-zA-Z0-9+.]*: `` —
  mailto:, https:, ftp: all keep their branches;
- contains a `#`.

Deliberate divergence: upstream's scheme test is `` \`[a-z]+: ``,
case-sensitively lowercase, so upstream would route `HTTP://x/a#b` to
`find-file`. We use the full RFC 3986 grammar and route any-cased schemes
*away* from the file branch — the defensible reading, and the divergence is
unreachable from sanely-written Markdown.

A scheme-less URL **without** `#` — the common `[x](file.md)` — is not
handled; it passes through to upstream's `find-file`, byte-identical
behaviour to today.

### The action, decided at click time

For a handled URL the button's action calls `md-file-anchor-visit`:

1. **Existing-file guard.** If the whole string names an existing file —
   someone really has a `notes#draft.md` on disk — open it verbatim.
   Today's behaviour for such a file is correct, and must not break.
   Checked at click time, not button-build time: files appear and
   disappear, and build time is inside `jit-lock`, where per-link disk IO
   does not belong.
2. Otherwise split at the **first** `#` (URI semantics) into PATH and
   ANCHOR, and `find-file` PATH. Relative paths resolve against the
   Markdown buffer's `default-directory`, exactly as upstream's own
   `find-file` call does.
3. Interpret ANCHOR in the newly-current buffer:
   - **Line anchor** (grammar below): push the mark (so `C-u C-SPC`
     returns, mirroring `markdown-ts--follow-fragment`), jump to the first
     line, `recenter`, and momentarily highlight the anchored lines with
     `pulse-momentary-highlight-region` — the visual confirmation GitHub
     gives, and for a range the only way to see where it ends.
   - **Heading anchor** (anything else): if the target buffer is
     `markdown-ts-mode`, delegate to upstream's own
     `markdown-ts--follow-fragment`, which already resolves slugs against
     the buffer's headings — no second slug implementation. Any other
     major mode: leave point alone and say so in a `message`; the file is
     open, which is the bulk of the value.
   - **Empty anchor** (`file.md#`): just the file.

### Anchor grammar

Line anchors follow the forge conventions, case-sensitively:

| Anchor | Meaning | Convention |
|---|---|---|
| `L392` | line 392 | GitHub, GitLab |
| `L392-L400` | lines 392–400 | GitHub |
| `L392-400` | lines 392–400 | GitLab |
| `L392C5-L400C10` | columns ignored → lines 392–400 | GitHub |

One regexp: `` \`L\([0-9]+\)\(?:C[0-9]+\)?\(?:-L?\([0-9]+\)\(?:C[0-9]+\)?\)?\' ``.
A reversed range is normalised (`L400-L392` → 392–400). A line past
end-of-buffer stops at end-of-buffer — where `forward-line` stops — rather
than erroring; the file is open either way. Anything the regexp rejects is
a heading anchor by definition; there is no error case in classification.

### Interaction with md-bare-url

Both packages advise `markdown-ts--make-link-button`, and compose in either
order: md-bare-url's `:filter-args` rewrites only `mailto:URI-scheme`
double-prefixes, which have a scheme and therefore fail our predicate; every
URL we take over passes its filter unchanged.

### Healing open buffers

Same situation and same remedy as md-bare-url: buttons are
`jit-lock`-applied text properties, and the changed thing — the `action`
closure — is in `font-lock-extra-managed-props`, so `font-lock-flush` on
every `markdown-ts-mode` buffer when the mode toggles makes the next
redisplay rebuild the buttons through (or without) the advice.

## Public interface

`md-file-anchor-mode` — a **global** minor mode, for the same reason as
md-bare-url: advice is global state.

```elisp
(require 'md-file-anchor)
(md-file-anchor-mode 1)
```

Also public, because each is a seam where a mistake silently corrupts
behaviour and each is worth calling directly:

- `md-file-anchor-split` — URL → `(PATH . ANCHOR)`.
- `md-file-anchor-line-range` — ANCHOR → `(BEG . END)` or nil.
- `md-file-anchor-visit` — the whole click-time behaviour, callable on any
  URL string.

`md-file-anchor-unload-function` switches the mode off before
`unload-feature` runs, so `M-x emacs-tools-reload` cannot orphan the advice.

No `defcustom`. The behaviour is "do what the link says"; there is nothing
to tune. (If the pulse ever grates, that is the first candidate — but not
speculatively.)

## Testing strategy

Real Emacs, real TTY frame, real `markdown-ts-mode` and tree-sitter parser,
real `jit-lock`-built buttons, and — unlike md-bare-url, whose endpoint had
to be stubbed — a **real `find-file` on real files**: the suite creates a
fixture directory holding a numbered-lines target file, a Markdown target
with headings, and a file with a literal `#` in its name, then presses
`RET` and asserts on `buffer-file-name`, `line-number-at-pos` and the pulse
overlay's bounds.

- **Upstream canary**, mode off: the button action `find-file`s the whole
  fragment-bearing string. Starts failing the day upstream handles
  fragments itself; the answer then is to reassess this package.
- **The fix**: `RET` on `target.py#L392-L400` visits the file, lands on
  line 392, and the pulse overlay spans exactly lines 392–400. Single-line
  and GitLab-style anchors likewise.
- **Heading anchor**: `notes.md#slug` opens the file and lands on the
  heading, via upstream's own resolver.
- **Existing-file guard**: a link to the literal `weird#L5.md` file opens
  that file, no split.
- **Non-interference**: scheme'd URLs with fragments still browse; pure
  `#fragment` links still jump in-buffer; plain file links still open —
  mode on vs off.
- **Reversibility and healing**: fontify with the mode off, enable, and the
  live button gains the new action; disable, and it reverts; reload leaves
  exactly one advice.
- **The parsers in isolation**: `md-file-anchor-split` and
  `md-file-anchor-line-range` pinned on their edges (first-`#` split,
  column anchors, reversed ranges, non-line anchors).

## Validation against implementation

Checked after implementing, against a real Emacs 31.0.90 in a TTY frame
(the full suite) plus batch-mode smoke runs during development.

| Design claim | Verdict |
|---|---|
| Upstream hands the fragment-bearing string to `find-file` whole | Holds — pinned by the canary test, mode off |
| `RET` on `target.py#L392-L400` lands on line 392 | Holds — and the pulse overlay spans exactly bol 392 to eol 400 |
| All four forge anchor shapes parse; near misses are slugs | Holds — pinned per shape in the grammar test |
| Heading anchors resolve through upstream's own resolver | Holds — `notes.md#deferred-decisions` lands on the heading |
| Existing-file guard keeps literal-`#` filenames working | Holds — a real `weird#L5.md` opens verbatim |
| Scheme'd URLs, in-buffer fragments and plain file links untouched | Holds — asserted per shape, mode on |
| Mark is pushed before the jump | Holds — `(goto-char (mark t))` returns to the pre-jump line |
| `font-lock-flush` heals already-fontified buffers both ways | Holds — enable heals, disable reverts, advice fully removed |

### Deviations

None of substance. `md-file-anchor-split` on a URL without `#` returns
`(URL . nil)` — the design left that case unstated since the advice never
produces it; the function documents it for direct callers.

## Known limitations

- Ties to the same private upstream function as md-bare-url,
  `markdown-ts--make-link-button`; a rename silently disables the feature.
  The upstream canary test is the tripwire.
- `%23`-escaped `#` in filenames is not decoded — upstream does no percent-
  decoding anywhere, and matching upstream is the contract.
- Heading anchors in a target file that opens in something other than
  `markdown-ts-mode` (e.g. third-party `markdown-mode`) are ignored with a
  message rather than resolved; that mode has its own link machinery.
