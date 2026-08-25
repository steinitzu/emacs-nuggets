# md-table-align: lockups opening / resizing a many-tables file

**Resolved** (md-table-align 0.5.0): all four causes below fixed — see the
"Many wide tables" section of `md-table-align/DESIGN.md`. `string-pixel-width`
calls fell 70–86% per scenario (`tests/bench-results.md`); the ad-hoc harness
described below became `tests/bench-tables.el` (`make bench`), which is the
tool to reach for if this class of problem recurs.

Profiled 2026-08-25 on Emacs 31.0.90, real TTY frames (80x23 and 400x59 via
the script(1) pty trick), against `hacks/many-tables-example.md` — 254 lines,
8 tables, longest line 895 chars, 69 lines over 150 chars, so at any realistic
window width **every table is clipped** by the hscroll viewport.  Harness:
`hacks/profile-tables.el` (untracked), which times open / post-command /
window-split / page-through under elp, the CPU profiler, and a call-counting
advice on `string-pixel-width`.

## Numbers

TTY wall times are all small (open ≈ 0.2 s, split ≈ 0.05 s) — the lockup does
not reproduce in a terminal frame.  What does reproduce is the *work*, and the
work is measurement volume:

| scenario (400-col frame)     | `string-pixel-width` calls | notes |
|------------------------------|---------------------------|-------|
| open (find-file + mode on)   | 2164                      | 8 tables, laid out 11 times total |
| split-window + undo + split  | 834                       | 3 window ops |
| page through file (80-col)   | 2973                      | 8 tables measured 16 times |

On a TTY each call is ~15–35 µs.  In a GUI, `string-pixel-width` runs the
layout engine with real font shaping against a work buffer (plus
face-remapping copies under mixed-pitch) — per-call costs of 0.1–1 ms are
normal, and `docs/markdown-ts-scroll-performance.md` already flagged this
exact TTY-understates-GUI caveat.  At those rates: **open ≈ 0.2–2 s frozen,
every resize increment ≈ 0.1–0.8 s** — and an interactive drag-resize is many
increments back to back.  That is the lockup.

## Where the calls come from (ranked)

1. **Every layout re-measures every cell, because the metrics cache holds one
   entry.**  `md-table-align--metrics-cache` memoises only the most recent
   table; with 8 tables processed in sequence every lookup misses (11
   layout-table calls at open → 11 parse+measure passes; paging: 16 measure
   passes for 8 tables).  The cache key (tick, node bounds, padding) is
   *window-width-independent* — cell pixel widths do not change on resize —
   so with a per-table cache a resize would re-lay from cached metrics and
   pay almost nothing.  Today it pays full price every time.

2. **`md-table-align--split-at` is quadratic in viewport width.**  It finds
   the clip boundary by measuring `[beg, beg+k)` for k = 1, 2, 3… — N
   `string-pixel-width` calls on strings up to N chars, O(N²) glyph work per
   straddling cell per row per layout.  Even on the TTY a single call
   averaged 8 ms at 400 cols (vs ~30 µs for everything else).  In a GUI at
   ~200 visible columns this path alone is hundreds of shaping calls per
   clipped row.  A binary search over the same measure (or one incremental
   pass) is O(log N) / O(N) with short strings.

3. **Opening lays the visible tables out twice, and offscreen tables
   eagerly.**  Mode enable calls `md-table-align-buffer` (whole buffer, all 8
   tables); the first redisplay then runs the jit-lock handler over the
   visible region and re-lays those tables again (layout-key goes nil→width
   is irrelevant here — jit simply hadn't fontified yet).  Replacing the
   eager `md-table-align-buffer` in the mode body with `jit-lock-refontify`
   would lay out only visible tables, once, and the rest on demand.

4. **A table spanning several jit chunks is fully re-laid once per chunk.**
   `--align-region` lays out the *whole* overlapping table for each ~1500-char
   jit chunk; with 895-char lines a table spans 2–4 chunks.  Mostly masked if
   (1) is fixed, since re-layout from cached metrics is cheap.

Secondary: GC was ~50% of the TTY open time at the default threshold
(measurement garbage — fixing (1) and (2) shrinks it proportionally);
573 alignment overlays after open at 400 cols, hundreds not thousands, so
overlay count itself is not the problem.

## Recommended order

Fix (1) per-table metrics cache and (2) binary-search split-at first — they
cut both open and resize by an order of magnitude and need no behavior
change.  Then (3) drop the eager full-buffer align on enable.  (4) is likely
free after (1).
