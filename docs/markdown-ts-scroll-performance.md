# markdown-ts-mode scrolling performance

Profiled 2026-08-19 on Emacs 31.0.90, in a real TTY frame (140x49, via the
same script(1) pty trick the test suite uses).  Harness lives in
`hacks/scroll-profile/` (untracked): `run.sh <config> [big10.md]` scrolls a
generated 1.6k-line (or 16k-line) markdown file of prose, headings, lists,
fenced code blocks (python/elisp/c/bash) and tables, timing every
`scroll-up-command` + forced redisplay, with the native profiler running.
Configs replicate the user init: mixed-pitch, visual-line, md-heading-scale,
md-bare-url, md-file-anchor, md-table-inline, md-table-align.

## Numbers (per scroll step, 16k-line buffer)

| config  | cold mean | cold p95 | cold max | warm mean |
|---------|-----------|----------|----------|-----------|
| vanilla | 6.5 ms    | 9.5 ms   | 47 ms    | 1.6 ms    |
| full    | 16.6 ms   | 55 ms    | 91 ms    | 2.7 ms    |

Single-feature runs (1.6k buffer, delta vs vanilla cold 7.7 ms / warm 1.7 ms):
table-align +3.6 ms, table-inline +3.1 ms, mixed-pitch +1.4 ms;
visual-line, heading-scale, bare-url, file-anchor each ~0.

## Findings

1. **All the cost is the cold path** (first fontification of newly exposed
   text under jit-lock).  Warm scrolling is pure C redisplay in every config
   — none of the extensions re-run per scroll step once a region is
   fontified.  Per-step cost is flat in buffer size (1.6k vs 16k identical),
   so no O(buffer) trap.

2. **Vanilla markdown-ts-mode is half the cost.**  Cold profile: ~33%
   treesit fontification, within which `treesit-update-ranges` re-creates
   embedded parsers (`treesit-parser-create` alone 7%) and the non-ts code
   block path (elisp) runs full font-lock in an indirect buffer.

3. **One-time hitches per code-fence language.**  The first time a fence
   language appears, `markdown-ts--harvest-mode-treesit-configuration`
   activates the full ts mode (bash-ts-mode ~27 ms, c-ts-mode ~12 ms,
   query compiles included) — visible 40–90 ms spikes when scrolling into
   new territory.  If the grammar is *missing*, harvesting prompts
   ("install it? (y or n)") mid-fontification — in the harness this hung the
   run until python/bash/c grammars were installed into
   `.test-env/tree-sitter` (recipes register on `(require 'python)` etc.,
   then `treesit-install-language-grammar`).

4. **md-table-align cold cost splits ~half finding, ~half laying out.**
   `md-table-align--tables` (11% of full-config profile) passes a *sexp*
   query to `treesit-query-capture`, recompiled every jit chunk.  Measured
   ~5x: 454 sexp queries 251 ms vs 54 ms precompiled.  Precompiling the
   `(pipe_table) @table` query with `treesit-query-compile` at load time is
   a free win (~0.4 ms/step).  The layout half is `string-pixel-width`
   measurement — irreducible in kind, though a TTY understates its GUI cost.

5. **GC is 22% of the cold profile** (default threshold; harness used 8 MB).
   Parser creation + measurement garbage.  A higher `gc-cons-threshold`
   would shave a meaningful slice.

## Caveats

TTY redisplay has no font shaping / variable-pitch glyph metrics, so
mixed-pitch's GUI-side cost (and `string-pixel-width` with real proportional
fonts) is understated here.  If GUI scrolling feels far worse than these
numbers suggest, the gap is in font rendering, not elisp.
