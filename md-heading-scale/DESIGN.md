# md-heading-scale — planning and design

Size Markdown headings by their level in `markdown-ts-mode`, the way
`markdown-mode`'s `markdown-header-scaling` does — and let it be switched on
and off.

## Problem

`markdown-mode` (the MELPA package) has `markdown-header-scaling`: a boolean
that makes a level-1 heading render large, a level-2 heading a little smaller,
and so on down to body size. `markdown-ts-mode`, which ships with Emacs 31, has
no equivalent. A heading there is distinguishable only by counting `#`
characters.

## What markdown-ts-mode actually provides

Established against real Emacs 31.0.90
(`lisp/textmodes/markdown-ts-mode.el`, and by reading back text properties in a
real buffer after real fontification):

1. **There is no option.** No `defcustom` in `markdown-ts-mode` mentions
   height or scaling, and no face it defines carries a `:height` at all.
2. **But six distinct faces already exist**, one per level, and they are
   byte-for-byte identical:

   ```elisp
   (defface markdown-ts-heading-1 '((t (:inherit font-lock-function-name-face :weight bold))) ...)
   ;; ... -2 through -6, the same definition each time
   ```

   So the levels are already told apart in code, and thrown away again in
   appearance.
3. **The right face really does reach the text.** `markdown-ts--fontify-atx-heading`
   interns `markdown-ts-heading-N` from the width of the `#` run and applies it
   across the whole heading node. Read back from a fontified buffer:

   | Line | `face` on the text |
   |------|--------------------|
   | `# One` | `(markdown-ts-heading-1)` |
   | `### Three` | `(markdown-ts-heading-3)` |
   | `###### Six` | `(markdown-ts-delimiter markdown-ts-heading-6)` |
   | `Setext` (over `======`) | `(markdown-ts-setext-heading)` |
   | `plain body` | `nil` |

That is the whole reason this package is small: nothing needs to be detected,
parsed or fontified. Six faces are already in the right places and want for one
attribute.

## Scope

Give those six faces a height, per level, switchable. Nothing else — no
variable-pitch heading option, no `markdown-mode` support (different faces, no
tree-sitter parser), no new fontification.

## Mechanism: buffer-local face remapping

`md-heading-scale-mode` calls `face-remap-add-relative` on each level's face
with a **relative** `:height`, and keeps the cookies in a buffer-local
variable. Switching the mode off feeds every cookie back to
`face-remap-remove-relative`.

### Why not markdown-mode's approach

`markdown-mode` mutates the global faces (`markdown-mode.el:2193`):

```elisp
(defun markdown-update-header-faces (&optional scaling scaling-values)
  (dotimes (num 6)
    (let* ((face-name (intern (format "markdown-header-face-%s" (1+ num))))
           (scale (cond ((not scaling) 1.0) ...)))
      (unless (get face-name 'saved-face)   ; Don't update customized faces
        (set-face-attribute face-name nil :height scale)))))
```

Three properties of that we do not want:

- **It is frame-global.** One buffer cannot be scaled differently from another,
  and there is no way to have it in the buffers you read and not in the ones
  you edit.
- **Off is not off.** Disabling writes `:height 1.0`, an explicit attribute,
  rather than restoring `unspecified`. A face that had a height before is
  quietly flattened; the `saved-face` guard rescues only heights set through
  Customize, not one set from an init file with `set-face-attribute`.
- **It cannot be undone precisely.** There is no record of what was there
  before, so "restore" has to mean "guess".

A remapping cookie has none of these problems: it is buffer-local, it is
removed by identity, and the face definition itself is never touched. The
underlying `markdown-ts-heading-N` faces are exactly as the user left them,
whether the mode is on, off, or was never loaded.

### Why relative heights (floats), not absolute ones

A float `:height` is a multiplier applied to whatever the text would otherwise
have been, and multipliers compose. Verified with `merge-face-attribute`, the
same primitive the display engine uses to fold a relative attribute into an
underlying value:

| Merge | Result |
|-------|--------|
| `(merge-face-attribute :height 2.0 100)` | `200` |
| `(merge-face-attribute :height 1.5 1.2)` | `1.8` |
| `(merge-face-attribute :height 1.0 100)` | `100` |

The second row is the one that matters: `text-scale-mode` works by remapping
`default` with its own relative height, so scaling the buffer scales the
headings with it and the ratios hold. An absolute height would pin headings to
one size and break under `text-scale-adjust`, `mixed-pitch-mode` and a user's
own `:height` on the heading faces.

### Setext headings come along for free

`markdown-ts-setext-heading` carries no height of its own — it is
`(:inherit markdown-ts-heading-1)`. Whether a remapping of `markdown-ts-heading-1`
reaches text that only *inherits* it decides whether this package must remap
setext explicitly (if remapping does not follow `:inherit`) or must **not** (if
it does, since remapping both would scale setext headings twice).

The environment here has no graphical display, and `:height` is invisible on a
terminal — so the question was settled with an attribute a terminal *does*
render. A buffer with an atx heading and a setext heading, with
`markdown-ts-heading-1` remapped to `(:underline t)` and nothing else touched,
displayed in a real TTY frame under a pty, writes this to the terminal:

```
^[[4m^[[90m#^[[0m^[[39;49m^[[1m^[[4m^[[38;5;21m AAAAA^[[0m...   <- atx, underlined
^[[1m^[[4m^[[38;5;21mBBBBB^[[0m^[[39;49m^[[K                     <- setext, underlined
CCCCC plain^[[K                                                <- body, not
```

`BBBBB` is the setext heading. It has only `markdown-ts-setext-heading` on it,
and it came out underlined — **face remapping is followed through `:inherit`**.

So: remap the six `markdown-ts-heading-N` faces and nothing else. Setext
headings follow level 1, which is what they mean.

### No refontification is needed

Faces are resolved at display time, not at fontification time, so a remapping
takes effect on the next redisplay without disturbing what `jit-lock` has
already done. (This is the opposite of `md-bare-url`, which changes what
fontification *produces* and therefore has to flush it.) `face-remap-add-relative`
already calls `force-mode-line-update`; the mode adds
`(force-window-update (current-buffer))` as `text-scale-mode` does, so a buffer
that is visible but otherwise idle repaints at once.

## Lifetime

Both `face-remapping-alist` and the mode variable are ordinary buffer-local
variables — neither is `permanent-local` (checked). Re-running a major mode
therefore clears the remappings and the mode flag together, so scaling can
never outlive the flag that says it is on. Where the mode was switched on by
`global-md-heading-scale-mode`, `after-change-major-mode-hook` puts it straight
back.

## Public interface

```elisp
(require 'md-heading-scale)
(add-hook 'markdown-ts-mode-hook #'md-heading-scale-mode)
;; or
(global-md-heading-scale-mode 1)
```

| Name | What it is |
|------|-----------|
| `md-heading-scale-mode` | Buffer-local minor mode. |
| `global-md-heading-scale-mode` | Turns it on in `md-heading-scale-modes`. |
| `md-heading-scale-refresh` | Re-apply in every buffer that has the mode on. |
| `md-heading-scale-values` | Multipliers for levels 1–6. |
| `md-heading-scale-modes` | Modes the globalized mode activates in. |

`md-heading-scale-values` defaults to `(1.6 1.4 1.25 1.1 1.0 1.0)`. The first
default was `markdown-mode`'s own `(2.0 1.7 1.4 1.1 1.0 1.0)`, on the reasoning
that someone arriving from `markdown-header-scaling` should see what they saw
before; in use it read as too big, so the ramp was pulled in. Parity is one
`setopt` away and the README says so.

What the defaults must be, as opposed to what they happen to be, is what the
tests pin: six values, never growing as the level goes down, ending at body
size. The numbers themselves are taste.

Two rules make the list forgiving, and both are deliberate:

- **A level whose multiplier is 1 gets no remapping at all**, rather than a
  no-op `(:height 1.0)` entry. So the default scales the first four levels and
  leaves levels 5 and 6 untouched — their faces are not merely unchanged in
  effect, they are not mentioned in `face-remapping-alist`.
- **Levels past the end of the list are not scaled.** `'(1.6)` is a legal value
  meaning "make h1 bigger, leave the rest alone".

Changing `md-heading-scale-values` through Customize (or `setopt`) re-applies
live, via a `:set` function calling `md-heading-scale-refresh`. The custom
`:initialize` is `custom-initialize-default` so this does not fire while the
file is still loading.

The units are **multipliers of the height the text would otherwise have**. Per
`CLAUDE.md`, if that meaning ever changes the variable gets a new name rather
than a reinterpreted value.

### Why the mode does not refuse in non-Markdown buffers

`md-table-align` declines when the buffer has no `markdown` parser, because
without one it cannot work. This mode has no such dependency: it remaps faces
that only `markdown-ts-mode` ever applies, so switching it on somewhere else is
inert rather than wrong. Refusing would cost a check and buy nothing.

## Feasibility (validated before implementation)

Against real Emacs 31.0.90, real buffers, real `markdown-ts-mode`, real
tree-sitter parser.

| # | Question | Result |
|---|----------|--------|
| 1 | Does `markdown-ts-mode` offer any scaling? | No — no `:height` anywhere in the file, no relevant `defcustom`. |
| 2 | Does each level get its own face on the text? | Yes — table above, read back after real fontification. |
| 3 | Does remapping follow `:inherit`, i.e. do setext headings track h1? | Yes — proved on a TTY frame with `:underline`. |
| 4 | Do relative heights compose (so `text-scale` still works)? | Yes — `merge-face-attribute` multiplies. |
| 5 | Is `face-remapping-alist` permanent-local (could remaps outlive the mode)? | No — cleared with the mode flag on a major-mode change. |
| 6 | Can the `#` markers be kept at body size? | No — see below. |

## Known limitations

- **The `#` markers scale with their heading.** Upstream applies the heading
  face across the entire node, markers included, and then *prepends*
  `markdown-ts-delimiter` — which specifies no height, so the height falls
  through to the heading face. Nothing short of overriding
  `markdown-ts--fontify-atx-heading` changes that, which is exactly the kind of
  upstream-duplicating override `md-bare-url`'s design argues against. Users who
  dislike big markers have `markdown-ts-hide-markup`, which hides them
  entirely.

  Shrinking them with a fixed relative remapping of `markdown-ts-delimiter` was
  considered and rejected: one face serves all six levels, so no single factor
  can bring the markers of every level back to body size, and the face is used
  for other delimiters too.
- **A setext heading's underline row (`======`) scales too**, for the same
  reason — it carries `(markdown-ts-delimiter markdown-ts-setext-heading)`.
- **Not `markdown-mode`.** That package has its own scaling, its own faces, and
  no tree-sitter parser.
- **`:height` does nothing on a terminal frame.** The mode is harmless there,
  but there is nothing to see.

## Interaction with md-table-align

`md-table-align--layout-key` includes `face-remapping-alist`, precisely so that
a face change re-measures tables. Turning this mode on or off therefore
triggers a re-layout of visible tables on the next command, which is the
correct response: heading faces do not affect table cells, but the key is
deliberately coarse and a needless re-layout is cheap.

## Testing strategy

Per repo convention, real Emacs, real buffer, real `markdown-ts-mode`, real
tree-sitter parser, real `jit-lock`.

The awkwardness is that **`:height` is only observable on a graphical frame**,
and the suite runs on a TTY frame under a pty (which is what `posn-at-point`
needs elsewhere). Terminals have one character cell size; nothing about a
height remapping is visible there. So the evidence is assembled in three
layers:

1. **Upstream's half of the contract**, in a real buffer: the text of a
   level-N heading carries `markdown-ts-heading-N`, and body text carries no
   heading face. If upstream ever renames or stops applying these faces, this
   fails and says so.
2. **Our half**, in a real buffer: the mode installs a relative `:height`
   remapping for exactly the levels it should, on exactly those faces, in that
   buffer only; switching it off restores `face-remapping-alist` to the value
   it had, `equal`-identically.
3. **The join**, with the display engine's own primitive: `merge-face-attribute`
   is what folds a relative height into an underlying one, so asserting on it
   pins the arithmetic that turns layer 2 into pixels.

Plus a fourth layer when the machine running the tests can provide it: a test
that opens a **real graphical frame** (skipped when there is no display, as the
`termdex` tests skip without `vterm`), displays the fixture, and measures
rendered line heights with `window-text-pixel-size` — a level-1 heading line
must render taller than a level-3 one, which must render taller than body text,
while an unscaled level (5) matches body text exactly. That is the only
assertion that observes the actual point of the package, so it is worth having
even though it cannot run everywhere.

Also covered: buffer-locality, live refresh when `md-heading-scale-values`
changes, composition with a pre-existing remapping (as `mixed-pitch-mode` and
`text-scale-mode` leave behind), and a reload cycle leaving exactly one set of
remappings rather than two.

## Validation against implementation

Checked after implementing, against real Emacs 31.0.90 in a TTY frame under a
pty — the whole suite, plus the mutation checks below.

| Design claim | Verdict |
|---|---|
| One relative `:height` remapping per scaled level, on `markdown-ts-heading-N` | Holds |
| A multiplier of 1 installs nothing at all | Holds — levels 5 and 6 are absent from `face-remapping-alist` under the defaults |
| A short list leaves the remaining levels alone | Holds |
| Switching off restores `face-remapping-alist` `equal`-identically | Holds |
| A remapping from elsewhere (`text-scale`, `mixed-pitch`) survives untouched | Holds — asserted against a `default` remapping made before and checked after |
| Scaling is buffer-local | Holds |
| Changing the values re-applies live, without stacking the old cookie under the new | Holds |
| Relative heights multiply, so `text-scale` composes | Holds — `merge-face-attribute` gives 300 for 1.5 then 2.0 over 100 |
| Setext headings need no remapping of their own | Holds — `markdown-ts-setext-heading` specifies no `:height` and inherits `markdown-ts-heading-1` |
| A reload leaves exactly one set of remappings | Holds |
| `unload-feature` leaves no buffer scaled | Holds |

The suite was mutation-checked. Each of these fails exactly the tests that
describe it, and nothing else:

| Mutation | Caught by |
|---|---|
| Multiplier not floated | `integers-are-accepted` |
| Multiplier-of-1 guard removed | `a-multiplier-of-one-installs-nothing`, and three more |
| `--apply` does not clear first | `refresh-takes-up-a-changed-value` |
| Switching off does not clear | `switching-off-restores-exactly`, `leaves-foreign-remappings-alone`, `reload-…`, `unloading-…` |

### Deviations

- **Multipliers are floated on the way in.** Not in the design, and a real
  hazard rather than tidiness: `:height` is relative only when it is a float.
  An integer is an absolute size in units of 1/10 pt, so a perfectly reasonable
  `(setopt md-heading-scale-values '(2 1.5 …))` would have rendered level-1
  headings at 0.2pt instead of doubling them. `md-heading-scale--factor` returns
  `(float factor)`, and a test pins it.
- **`md-heading-scale-max-level` is public**, where the interface table lists
  only the mode, the refresh command and the two options. It is a constant of
  the markup rather than a knob — six levels is CommonMark — but it is worth
  being able to read, and the tests do.
- **The graphical test has not been run.** The machine this was written on has
  no display, so `headings-render-taller` skipped every time. Its failure modes
  are conservative — no display, or a frame that reports no measurable line
  height, both skip rather than fail — but it has never gone green, and the
  first run on a machine with a display is what will confirm it.
- **A pre-existing flake was observed, not fixed:**
  `termdex-follows-a-nested-shell` fails intermittently (roughly one run in
  three), reporting `bash` where it expects `sleep`. `termdex-tests--busy`
  returns as soon as the terminal is busy, which the nested shell briefly is
  before it has spawned the job. Unrelated to this package, and left alone.
