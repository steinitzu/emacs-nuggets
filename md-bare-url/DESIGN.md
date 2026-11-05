# md-bare-url — planning and design

Make bare URLs in Markdown follow to the browser on `RET` and mouse clicks,
the way `[name](url)` links already do.

## Problem

In `markdown-ts-mode`, a plain URL written without link syntax —

    See https://example.com/foo for details.

— does not open in a browser when you press `RET` on it or click it, while a
tagged `[see](https://example.com/foo)` on the same line does.

## What is actually wrong

The obvious guesses are both false, and finding that out changed the shape of
this package. Established against real Emacs 31.0.90:

1. **There is no setting.** No `defcustom` in `markdown-ts-mode` governs bare
   URLs.
2. **The feature already exists, unconditionally.** `markdown-ts-mode` registers
   a `jit-lock` handler for exactly this (`markdown-ts-mode.el:5369`):

   ```elisp
   (unless (buffer-base-buffer)
     (jit-lock-register #'markdown-ts--fontify-bare-uri))
   ```
3. **Bare URLs really are buttons, and `RET` really does reach them.** At a
   bare URL, `RET`, `mouse-1` and `mouse-2` all resolve to `push-button`,
   identically to a tagged link. The button's `keymap` text property comes from
   `button-map`, which takes precedence over `markdown-ts-mode-map`'s
   `RET` → `markdown-ts-newline`.

So nothing is missing and nothing is shadowed. What is wrong is the *URL the
button carries*. `markdown-ts--fontify-bare-uri` scans with two regexps in turn
— `goto-address-url-regexp`, then `goto-address-mail-regexp` — and then decides
the scheme like this (`markdown-ts-mode.el:1789`):

```elisp
(markdown-ts--make-link-button
 uri-start uri-end
 (if (eq uri-start 0)
     uri
   (concat "mailto:" uri)))
```

`uri-start` is `(match-beginning 0)`, a **buffer position**. Buffer positions
start at 1, so `(eq uri-start 0)` is never true. The test was plainly meant to
ask *which of the two regexps matched*, and instead asks something that is
always false — so **every** bare URI is treated as an email address.

`markdown-ts--make-link-button` then dispatches on the string it was handed:
`mailto:` wins over the generic `[a-z]+:` branch, so a bare `https://` URL
calls `url-mail-command` instead of `browse-url`. If `url-vars` has not been
loaded, it does not even get that far — it fails with `Symbol's value as
variable is void: url-mail-command`. Either way, no browser opens, which is
what "not clickable" looks like from the outside.

Bare **email** addresses come out right, by accident: the always-taken branch
is the one they needed.

Measured in a buffer under real `markdown-ts-mode`, after real `jit-lock`
fontification (button `help-echo` carries the destination URL):

| Written | Destination on the button | Correct |
|---------|---------------------------|---------|
| `https://example.com/foo` | `mailto:https://example.com/foo` | no |
| `someone@example.com` | `mailto:someone@example.com` | yes |
| `[x](https://example.com/bar)` | `https://example.com/bar` | yes |
| `<https://example.com/baz>` | `https://example.com/baz` | yes |

The same line is present in Emacs master (checked on Savannah), so this is not
something a later 31.x pretest fixes.

## Scope: repair, don't reimplement

Since discovery, buttonization, node-type exclusions and key dispatch all work,
this package must **not** re-derive them. Writing our own "make bare URLs
clickable" pass would duplicate correct upstream code and fight it for the same
text.

The whole defect is one wrong string. That is all this package fixes.

This is a **shim against a specific upstream bug**, and it is meant to be
deleted once that bug is fixed upstream. Everything below is chosen to make
that deletion cheap and to make the intervening period safe.

## Mechanism

A `:filter-args` advice on `markdown-ts--make-link-button` that strips a
`mailto:` prefix when — and only when — the remainder starts with its own URI
scheme:

```elisp
"\\`mailto:\\([a-zA-Z][-a-zA-Z0-9+.]*:\\)"
```

`mailto:https://example.com/foo` matches and becomes `https://example.com/foo`.
Nothing else in the buffer does.

### Why this is safe for the other callers

The advice sits on a function every link button goes through — tagged links,
reference links, autolinks, image descriptions — so the discriminator has to be
airtight. It is, because a **real** `mailto:` URL can never match it:

- `goto-address-mail-regexp` is `[-a-zA-Z0-9=._+]+@\(...\)+[a-zA-Z0-9]+`, which
  contains no `:`. A bare email can never produce a second scheme.
- An `<foo@bar.com>` email autolink is prefixed to `mailto:foo@bar.com` by
  `markdown-ts--fontify-autolink` — again no second colon.
- An explicit `[x](mailto:foo@bar.com)` passes the destination through verbatim
  — no second colon.

A double scheme is producible only by the bug.

### Why not override `markdown-ts--fontify-bare-uri` instead

The direct alternative is `:override` on the buggy function with a corrected
copy. Rejected: that copy would have to carry the two regexps, the tree-sitter
parent/child node-type exclusion lists and the `button` guard, all of which are
upstream's business and are *correct*. It would silently rot as upstream edits
them.

The `:filter-args` advice touches none of that, and it has a property the copy
cannot have: **it neutralises itself.** When upstream fixes line 1789, no URL
will carry a double scheme any more, the regexp will stop matching, and the
advice becomes a no-op — rather than pinning a stale duplicate of a function
that has moved on. Removing this package then becomes bookkeeping instead of a
correctness question.

### Healing buffers that are already open

Buttons are text properties, already applied to visible text by the time the
mode is switched on, and `jit-lock` will not redo a region it has fontified.

`font-lock-flush` is enough, and that is not obvious — normally `font-lock`
strips only `face`. It works here because `markdown-ts-mode` declares its
button properties as font-lock's to manage (`markdown-ts-mode.el:5291`):

```elisp
(make-local-variable 'font-lock-extra-managed-props)
(dolist (prop '(invisible display button category action help-echo))
  (add-to-list 'font-lock-extra-managed-props prop))
```

So a flush removes the `button` property, which in turn releases
`markdown-ts--fontify-bare-uri`'s own `(get-text-property uri-start 'button)`
guard, and the next redisplay rebuilds the button — through the advice this
time. Without that declaration the stale buttons would survive the flush and
the mode would only take effect in freshly-visited buffers.

The mode therefore flushes every `markdown-ts-mode` buffer when switched on,
and again when switched off, so disabling reverts just as visibly as enabling.

## Feasibility (validated before implementation)

Run against real Emacs 31.0.90 in a real TTY frame driven through a pty, with
the buffer in a window and `redisplay` forced — so `jit-lock` ran on its own
rather than being called by hand.

| # | Question | Result |
|---|----------|--------|
| 1 | Does the bug reproduce through real `jit-lock`, not just a manual call? | Yes — `help-echo` on a bare URL is `mailto:https://example.com/foo`. |
| 2 | Does the advice fix it, leaving emails/tagged/autolinks alone? | Yes — bare URL repaired; the other three unchanged. |
| 3 | Does an already-fontified buffer heal on `font-lock-flush`? | Yes, on the next redisplay. |
| 4 | Does `RET` then browse? | Yes — `browse-url` called with `https://example.com/foo`. |
| 5 | Does removing the advice revert cleanly? | Yes — the `mailto:` destination returns. |

## Public interface

`md-bare-url-mode` — a **global** minor mode. Function advice is global state;
a buffer-local mode would be a lie about what it controls.

```elisp
(require 'md-bare-url)
(md-bare-url-mode 1)
```

`md-bare-url-unload-function` switches the mode off before `unload-feature`
strips the definitions, so `M-x nuggets-reload` cannot orphan the advice on
a function this file no longer defines a filter for.

No `defcustom`. There is nothing here a user would reasonably want to tune —
the behaviour is "match the tagged-link behaviour you already have".

## Testing strategy

Per repo convention, integration over mocks: real Emacs, real buffer, real
`markdown-ts-mode`, real tree-sitter parser, real button properties.

- **Reproduce the upstream bug** with the mode off, so the suite fails loudly
  the day upstream fixes it and this package can be deleted.
- **Repair** with the mode on: the bare URL's destination loses the prefix.
- **Non-interference**: bare emails, tagged links, `<autolinks>` and a
  `[x](mailto:a@b.com)` destination are byte-identical mode-on vs mode-off.
- **Dispatch, end to end**: put point on a bare URL, look up what `RET` is
  actually bound to there, and invoke it — asserting `browse-url` receives the
  right URL. This is the user's actual complaint, tested as stated.
- **Live healing**: fontify a buffer with the mode off, switch the mode on,
  and assert the already-built button changes destination.
- **Reversibility**: switching the mode off restores upstream behaviour, so a
  reload cycle leaves nothing behind.

`browse-url`/`compose-mail` are instrumented with `cl-letf` at the very edge of
the system, since a test suite must not actually open a browser. Everything
inside that boundary is real.

## Validation against implementation

Checked after implementing, against a real Emacs 31.0.90 in a TTY frame.

| Design claim | Verdict |
|---|---|
| The advice repairs bare URLs and nothing else | Holds — asserted per link shape in the suite |
| A real `mailto:` can never match the regexp | Holds — pinned directly for addresses with `.`, `+` and a multi-label domain |
| `RET` on a bare URL reaches `browse-url` | Holds — `RET` resolves to `push-button`, which dispatches to `browse-url` |
| `font-lock-flush` heals an already-fontified buffer | Holds |
| Switching the mode off restores upstream behaviour | Holds — destination reverts, advice removed |
| `nuggets-reload` leaves no orphaned advice | Holds — after a reload with the mode on, exactly one filter is installed, not two; `unload-feature` leaves none |

The suite was also mutation-checked: neutering
`md-bare-url--double-scheme-regexp` fails exactly the five tests that assert
the fix, and leaves the two upstream-bug tests and the non-interference tests
green. That is the intended shape — the upstream tests describe markdown-ts-mode,
not this package.

### Deviations

- **`md-bare-url-destination` is public**, where "Public interface" above named
  only the mode. It is the single point where a mistake would silently corrupt
  a real URL, so it is worth being able to test — and to call — directly. The
  advice wrapper around it stays private.
- **The `compile` target now discovers extension directories** the way the
  loader does, instead of naming `md-table-align` explicitly. Outside this
  package's scope, but adding the second extension is what made the hard-coding
  a problem.
- **`load-prefer-newer` is now set in the test driver.** Found the hard way:
  the first mutation check came back green because `load` prefers a stale
  `.elc` over newer source, so the suite was asserting on byte-compiled code
  from before the mutation. Any test run after a `make compile` was exposed to
  this, not just this package's.

## Deferred: face consistency

A bare URL gets the plain `button` face; tagged links get `markdown-ts-link`
(which inherits `link`). `markdown-ts--make-link-button` deliberately sets no
face — its docstring explains that `add-text-properties` would clobber the face
list appended by `treesit-fontify-with-override`, breaking a link inside a
heading. Bare URLs have no treesit rule to apply `markdown-ts-link`, so they
fall through to `make-text-button`'s default.

Fixing this cannot ride on the same advice: it would need to distinguish the
bare-URI caller from the others, which means going back to overriding
`markdown-ts--fontify-bare-uri` and taking on exactly the drift this design
avoids.

Left alone. Bare URLs are still underlined and mouse-highlighted, the reported
problem is behavioural rather than visual, and the cost of the fix is the
package's main design property.

## Known limitations

- Ties to a private upstream function, `markdown-ts--make-link-button`. If it
  is renamed, the advice silently stops applying. The test that reproduces the
  raw bug is what catches this: it starts failing when upstream moves, whether
  by fix or by rename, and either way the answer is to re-check upstream.
- Does not affect `markdown-mode` (the third-party package), which has its own
  bare-URI handling.
