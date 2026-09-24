;;; md-table-align.el --- Display-only alignment of Markdown tables -*- lexical-binding: t; -*-

;; Author: Steinthor Palsson
;; Version: 0.7.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: markdown, faces, convenience

;;; Commentary:

;; Render Markdown pipe tables visually aligned without touching buffer text.
;;
;; `markdown-mode' aligns tables by rewriting the buffer.  That is unusable in
;; read-only buffers, and it dirties files you only wanted to read.  This
;; package instead places overlays whose `before-string' / `display' properties
;; are stretch glyphs -- `(space :align-to COLUMN)' -- so the redisplay engine
;; lays cells out on a grid while `buffer-string' stays byte-identical and
;; `buffer-modified-p' stays nil.
;;
;; Table discovery uses tree-sitter, so a `markdown' parser must be available
;; (see `markdown-ts-mode').  This gets fenced code blocks, escaped pipes and
;; per-column alignment markers right without any hand-rolled parsing.
;;
;; A table wider than the window is clipped to a horizontal viewport rather
;; than left to wrap, and that viewport scrolls the way a `truncate-lines'
;; buffer already does: it follows point, and \\[scroll-left] and
;; \\[scroll-right] move it by hand.  See `md-table-align-hscroll'.
;;
;; `md-table-align-toggle-vertical' flips the table at point into psql's
;; `\x'-style expanded display -- one `label | value' line per cell, one record
;; block per row -- and back.  Also a rendering, not an edit.
;;
;; Usage:
;;
;;   (add-hook 'markdown-ts-mode-hook #'md-table-align-mode)
;;
;; or globally:
;;
;;   (global-md-table-align-mode 1)

;;; Code:

(require 'treesit)
(require 'cl-lib)
(require 'jit-lock)

(declare-function treesit-parser-list "treesit")
(declare-function treesit-query-capture "treesit")
(declare-function treesit-query-compile "treesit")

(defgroup md-table-align nil
  "Display-only alignment of Markdown tables."
  :group 'markdown
  :prefix "md-table-align-")

(defcustom md-table-align-padding 1
  "Number of spaces rendered between a cell border and its content."
  :type 'natnum)

(defcustom md-table-align-pixel-width-function #'md-table-align-pixel-width
  "Function measuring the rendered width of a cell's text.
Called with one propertized string, returns a width in pixels.

The default measures with `string-pixel-width' against the current
buffer, so the result reflects the faces actually in play -- including
buffer-local face remapping from `mixed-pitch-mode' or
`variable-pitch-mode', and any font fallback.  Character counting is not
good enough here: a table whose face inherits a scaled `:height' renders
wider per character than the frame's canonical character width, and
alignment computed from character counts drifts by that ratio."
  :type 'function)

(defcustom md-table-align-modes '(markdown-ts-mode)
  "Major modes in which `global-md-table-align-mode' enables alignment."
  :type '(repeat symbol))

(defcustom md-table-align-hscroll t
  "Non-nil means clip wide tables to the window and scroll them sideways.

A table wider than the window would otherwise wrap, and a wrapped row is
not merely ugly: its continuation lines restart at the window's left edge
with no relation to the column grid, so alignment is destroyed.  Emacs
cannot turn wrapping off for part of a buffer, so each table is instead
clipped to a horizontal viewport that scrolls.

Scrolling follows the model a `truncate-lines' buffer already uses, so
there is nothing new to learn: the viewport follows point, honouring
`hscroll-margin' and `hscroll-step', and \\[scroll-left] and
\\[scroll-right] move it explicitly."
  :type 'boolean)

(defcustom md-table-align-spill t
  "Non-nil means a table may render into the window's right margin.

`visual-fill-column-mode' and `olivetti-mode' give prose a comfortable
measure by setting window margins, which come out of the window's text
area -- so a table is fitted to the narrowed width and a wide one is
clipped, however much screen there is beside it.

Ordinary text never renders in a margin, but a `display' spec can, so the
part of a row that does not fit the text area is hidden there and
re-emitted as a string in the margin, continuing the row.  Prose keeps
the narrow measure it was given; only rows too wide for it are affected.

Requires `md-table-align-hscroll', which is what keeps point inside the
text area -- Emacs cannot draw the cursor in a margin.  Tables rendering
in a proportional face are never spilled: every space `display' spec is
inert inside a margin string, so their padding could not be reproduced."
  :type 'boolean)

(defcustom md-table-align-ellipsis "…"
  "String marking table content clipped away by the window's edge."
  :type 'string)

(defcustom md-table-align-hscroll-indicator t
  "Non-nil means mark a table's clipped edges with `md-table-align-ellipsis'.
The indicator occupies space inside the viewport, so turning this off
gives the table itself slightly more room."
  :type 'boolean)

(defcustom md-table-align-vertical-record-format "-[ row %d ]---"
  "Format for the separator line above each record of a vertical table.
`%d' is the record's 1-based number.  See `md-table-align-toggle-vertical'."
  :type 'string)

(defcustom md-table-align-vertical-pipe-gap 2
  "Spaces on each side of the pipe separating a vertical table's columns.

Every value in a record block starts at the same column, so on the label
side this gap is what separates the *longest* label from the pipe; the
shorter labels get correspondingly more.  One space each side is the
psql tradition, but next to a bold label it reads too tight, which is
why the default is two.

Renamed from `md-table-align-vertical-gap', which counted the whole
span between the widest label and its value -- back when a colon ended
the label and nothing else stood in between."
  :type 'natnum)

(defface md-table-align-vertical-label
  '((t :inherit bold))
  "Face for the column labels of a table rendered vertically.")

(defface md-table-align-vertical-pipe
  '((t nil))
  "Face for the pipes between labels and values of a vertical table.
Unstyled by default -- psql's pipes are plain text -- but customizing
it to inherit `shadow' dims the rail if you prefer.")

(defface md-table-align-vertical-record
  '((t :inherit shadow))
  "Face for the record separator lines of a table rendered vertically.")

(make-obsolete-variable
 'md-table-align-fit-to-window
 "wide tables are now clipped and scrolled rather than elided in place;
see `md-table-align-hscroll'."
 "0.2.0")

(make-obsolete-variable
 'md-table-align-min-column-width
 "columns are no longer capped, so there is no width to floor;
see `md-table-align-hscroll'."
 "0.2.0")

(make-obsolete-variable
 'md-table-align-vertical-gap
 "the label-to-value span now holds a pipe with the same spacing on
both sides, counted per side; see `md-table-align-vertical-pipe-gap'."
 "0.6.0")

(defvar-local md-table-align--layout-key nil
  "What the current layout was computed against, besides the buffer text.
See the function `md-table-align--layout-key'.  Nil when the buffer has
not been laid out, or was laid out with no window to lay it out against.

Renamed from `md-table-align--layout-width', which held a bare pixel
width: a live session carrying the old scalar would otherwise have it
compared against the cons this now holds, and silently never re-fit.")

(defvar-local md-table-align--hscroll 0
  "Horizontal offset, in pixels, of the table currently scrolled.")

(defvar-local md-table-align--hscroll-table nil
  "Marker at the start of the table `md-table-align--hscroll' applies to.

Only one table is scrolled at a time: the one point is in.  Per-table
offsets were considered and rejected -- keyed by position they go stale
on the first edit above the table, and a table left scrolled is one whose
first columns are inexplicably missing.

A marker rather than a plain position, so that editing above the table
cannot silently hand its offset to whatever moves into its place.")

(defvar-local md-table-align--vertical-tables nil
  "Markers at the starts of the tables currently rendered vertically.
Consulted the way the hscroll marker is: a table whose start equals a
marker position is laid out vertically.  Unlike the hscroll offset this
state is meant to persist while point is elsewhere -- a table you flipped
stays flipped -- which is why it is a list and leaving a table resets
nothing.")

(defvar-local md-table-align--metrics-caches nil
  "Hash from table start position to (KEY . CONTEXT), memoising measurement.
KEY is what `md-table-align--metrics' computed the context against; see
there.  Nil until the first table is measured.

Renamed from `md-table-align--metrics-cache', which held a single
\(KEY . CONTEXT) cons: with more than one table in the buffer every
layout pass evicted the previous table's entry, so nothing was cached
across passes -- and a live session holding the old cons would have it
misread as a hash.")

(defvar-local md-table-align--follow-failed nil
  "Non-nil once point-following has signalled an error in this buffer.
Latches so that the failure is reported once rather than on every
command; see `md-table-align--post-command'.")

;; Defined by the minor mode below, but consulted by the scrolling code above
;; it -- the hooks that drive scrolling must do nothing in buffers where the
;; mode was switched off.
(defvar md-table-align-mode)

;;;; Measurement

(defun md-table-align-pixel-width (string)
  "Return the rendered width of STRING in pixels.
STRING keeps its text properties, so its faces are accounted for, and it
is measured against the current buffer so face remapping applies.

On a terminal the canonical character width is 1, so this returns the
same number a character count would, and everything downstream reduces
to character columns."
  (if (string-empty-p string)
      0
    (string-pixel-width string (current-buffer))))

(defconst md-table-align--unmeasurable-properties
  '(read-only nil
    modification-hooks nil
    insert-in-front-hooks nil
    insert-behind-hooks nil)
  "Text properties stripped before a string is handed to the width function.

`string-pixel-width' measures by inserting the string into a work buffer,
so any property that governs *modification* rather than display fires
there.  `read-only' is the one that actually breaks: inserting read-only
text into the work buffer and erasing it again signals `text-read-only',
and the measurement -- and with it all alignment -- dies.  Buffers that
mark regions read-only with a text property rather than
`buffer-read-only' are the case in point; a chat or transcript UI locking
down what it has already printed is the usual source.

The insertion hooks are stripped for the same reason: they are arbitrary
code, they have no bearing on how wide the text renders, and running them
against a work buffer is meaningless at best.  Display-affecting
properties -- `face', `display', `invisible', `composition' -- are
deliberately kept, since they are the whole reason for measuring the
propertized string.")

(defun md-table-align--measure (beg end)
  "Return the rendered pixel width of the buffer text between BEG and END."
  (if (>= beg end)
      0
    ;; Deliberately keeps text properties: faces are what make this differ
    ;; from a character count.  All except the ones that would make the
    ;; measurement itself fail -- see
    ;; `md-table-align--unmeasurable-properties'.  `buffer-substring'
    ;; returns a fresh string, so stripping in place cannot touch the
    ;; buffer.
    (let ((string (buffer-substring beg end)))
      (remove-text-properties 0 (length string)
                              md-table-align--unmeasurable-properties string)
      (funcall md-table-align-pixel-width-function string))))

(defun md-table-align--glyph-width (node string)
  "Return the pixel width of STRING as rendered inside table NODE.
Everything specified in characters -- padding, the minimum column width,
the ellipsis -- has to be converted using the font the table actually
renders in, not the frame's canonical character."
  (let* ((start (treesit-node-start node))
         (face (get-text-property start 'face))
         (s (if face (propertize string 'face face) string)))
    (max 1 (funcall md-table-align-pixel-width-function s))))

;;;; Overlays

(defun md-table-align--clear-region (beg end)
  "Delete alignment overlays between BEG and END."
  (dolist (ov (overlays-in beg end))
    (when (overlay-get ov 'md-table-align)
      (delete-overlay ov))))

(defun md-table-align--clear-table (node)
  "Delete the alignment overlays of the table at NODE.
From the start of its first line, not of the node: inside a list item or
a blockquote the node starts at the first pipe, past the indentation,
and a row's margin copy rides on an empty overlay at its line start.
`overlays-in' only finds an empty overlay inside the region, so the
header's copy would outlive every re-layout and the margin would fill
with stale ones, one more per scroll."
  (md-table-align--clear-region
   (save-excursion (goto-char (treesit-node-start node))
                   (line-beginning-position))
   (treesit-node-end node)))

(defun md-table-align--stretch (x)
  "Return a one-space string rendering as a stretch glyph out to pixel X.
The `(X)' list form of `:align-to' means pixels; a bare number would mean
multiples of the frame's canonical character width, which is not what the
table renders in."
  (propertize " " 'display `(space :align-to (,x))))

(defun md-table-align--pad (from to x)
  "Render the text at TO as starting at pixel X.

The region [FROM, TO) is whitespace to be replaced by a stretch glyph.
When that region is empty there is nothing to replace, so a stretch glyph
is inserted before TO instead -- this is what lets cells with no padding
at all, such as `|a|', still be aligned."
  (let ((ov (if (> to from)
                (make-overlay from to)
              (make-overlay to (min (point-max) (1+ to))))))
    (overlay-put ov 'md-table-align t)
    (overlay-put ov 'evaporate t)
    (if (> to from)
        (overlay-put ov 'display `(space :align-to (,x)))
      (overlay-put ov 'before-string (md-table-align--stretch x)))
    ov))

(defun md-table-align--replace (from to string)
  "Render the region [FROM, TO) as STRING."
  (when (> to from)
    (let ((ov (make-overlay from to)))
      (overlay-put ov 'md-table-align t)
      (overlay-put ov 'evaporate t)
      (overlay-put ov 'display string)
      ov)))

(defun md-table-align--split-at (beg end limit)
  "Return the largest position in [BEG, END] whose text from BEG fits LIMIT.
LIMIT is in pixels.  In a proportional font there is no fixed
relationship between characters and pixels, so the boundary has to be
found by measuring -- but not one character at a time: that costs one
`string-pixel-width' per character, on ever longer strings, and with
every row of a wide table straddling the viewport it was the single
hottest path in the profile.  Adding a character never narrows a string,
so the width is monotone in the end position and the boundary bisects in
O(log chars) measurements."
  (let ((lo beg) (hi end))
    (while (< lo hi)
      (let ((mid (/ (+ lo hi 1) 2)))
        (if (<= (md-table-align--measure beg mid) limit)
            (setq lo mid)
          (setq hi (1- mid)))))
    lo))

(defun md-table-align--hide (beg end indicate &optional x)
  "Render the buffer text between BEG and END as nothing.
With INDICATE, it renders as `md-table-align-ellipsis' instead, so the
edge reads as clipped rather than as the end of the row.  With X too,
the indicator stands at pixel X rather than wherever the row stopped.

This is what keeps a clipped row on one screen line: text left outside
the viewport would still be laid out, and would still wrap."
  (when (> end beg)
    (let ((ov (make-overlay beg end)))
      (overlay-put ov 'md-table-align t)
      ;; Tagged apart from the alignment overlays: this is the one kind that
      ;; takes text away rather than moving it.
      (overlay-put ov 'md-table-align-clip t)
      (overlay-put ov 'evaporate t)
      ;; A stretch inside the `display' string would be inert, so it rides
      ;; in front of it, the way `md-table-align--inject' pairs them.
      (when (and indicate x)
        (overlay-put ov 'before-string (md-table-align--stretch x)))
      (overlay-put ov 'display (if indicate md-table-align-ellipsis ""))
      ;; Clipped text stays readable without scrolling to it: both
      ;; `display-local-help' and a mouse hover surface `help-echo'.
      (overlay-put ov 'help-echo (buffer-substring-no-properties beg end))
      (overlay-put ov 'priority 1)
      ov)))

;;;; Table model
;;
;; A table is parsed into a list of rows.  Each row is a plist:
;;
;;   :delimiter  non-nil for the `|---|:--:|' row
;;   :pipes      buffer positions of the row's `|' characters
;;   :cells      list of cell plists, in column order
;;
;; and each cell is:
;;
;;   :beg :end   bounds of the trimmed cell text
;;   :width      rendered pixel width of that text
;;   :colons     (LEFT . RIGHT) colon markers, delimiter cells only
;;
;; All widths and positions below are in pixels.

(defun md-table-align--trimmed-bounds (beg end)
  "Return (BEG . END) shrunk past surrounding whitespace."
  (save-excursion
    (goto-char beg)
    (skip-chars-forward " \t" end)
    (let ((s (point)))
      (goto-char end)
      (skip-chars-backward " \t" s)
      (cons s (point)))))

(defun md-table-align--parse-cell (node delimiter)
  "Parse cell NODE into a cell plist.  DELIMITER marks a delimiter-row cell."
  (let* ((bounds (md-table-align--trimmed-bounds
                  (treesit-node-start node) (treesit-node-end node)))
         (beg (car bounds))
         (end (cdr bounds)))
    (list :beg beg
          :end end
          :width (md-table-align--measure beg end)
          :colons
          (when delimiter
            (cons (and (treesit-search-subtree
                        node "\\`pipe_table_align_left\\'" nil t)
                       t)
                  (and (treesit-search-subtree
                        node "\\`pipe_table_align_right\\'" nil t)
                       t))))))

(defun md-table-align--parse-row (node)
  "Parse a table row NODE into a row plist, or nil if it has no pipes.
The `:cells' list is indexed by column and holds nil for empty columns."
  (let ((delimiter (equal (treesit-node-type node) "pipe_table_delimiter_row"))
        (seen 0)
        pipes cells)
    (dotimes (i (treesit-node-child-count node))
      (let* ((child (treesit-node-child node i))
             (type (treesit-node-type child)))
        (cond
         ((equal type "|")
          (push (treesit-node-start child) pipes)
          (setq seen (1+ seen)))
         ((member type '("pipe_table_cell" "pipe_table_delimiter_cell"))
          ;; Which column a cell belongs to follows from how many pipes precede
          ;; it, not from how many cells we have seen: an empty cell produces
          ;; no node at all, so counting cells would shift every later column.
          (push (cons (max 0 (1- seen))
                      (md-table-align--parse-cell child delimiter))
                cells)))))
    (when pipes
      (setq pipes (nreverse pipes))
      (let* ((ncols (max (1- (length pipes))
                         (if cells (1+ (apply #'max (mapcar #'car cells))) 0)))
             (vec (make-vector ncols nil)))
        (dolist (cell cells)
          (when (< (car cell) ncols)
            (aset vec (car cell) (cdr cell))))
        (list :delimiter delimiter
              :pipes pipes
              :cells (append vec nil))))))

(defun md-table-align--parse-table (node)
  "Parse a `pipe_table' NODE into a list of row plists."
  (delq nil
        (mapcar #'md-table-align--parse-row
                (treesit-node-children node t))))

;;;; Layout

(defun md-table-align--quantise (pixels unit)
  "Return PIXELS rounded up to a whole number of UNIT-wide characters."
  (* unit (ceiling pixels unit)))

(defun md-table-align--quantise-widths (rows unit)
  "Round every cell width in ROWS up to a whole character.  Returns ROWS.

A margin copy can only be built from literal spaces -- a stretch glyph
inside a margin string collapses to one column, whatever width it asks
for -- so every run of padding in a copy is a pixel width divided by
UNIT.  Unless the grid is whole characters that division rounds, each row
rounds its own padding its own way, and the copies drift apart by up to a
character.

A terminal cannot show this: there one character is one pixel and every
width divides exactly.  A GUI font whose advance is not a whole pixel --
fractional display scaling is the usual way to get one -- makes a cell of
ten characters wider than ten single characters, and then nothing
divides.

Only for a fixed-pitch table, which is the only kind that can spill
anyway, and where a whole-character grid is what the table already looks
like it has."
  (dolist (row rows rows)
    (dolist (cell (plist-get row :cells))
      (when cell
        (plist-put cell :width
                   (md-table-align--quantise (plist-get cell :width) unit))))))

(defun md-table-align--column-widths (rows unit)
  "Return a vector of target content widths in pixels for the columns of ROWS.
UNIT is the pixel width of one space, used as the minimum column width.
Delimiter rows do not contribute, since their dashes are re-rendered to
whatever width the data requires."
  (let* ((n (apply #'max 0 (mapcar (lambda (r) (length (plist-get r :cells))) rows)))
         (widths (make-vector n unit)))
    (dolist (row rows widths)
      (unless (plist-get row :delimiter)
        (let ((i 0))
          (dolist (cell (plist-get row :cells))
            (when cell
              (aset widths i (max (aref widths i) (plist-get cell :width))))
            (setq i (1+ i))))))))

(defun md-table-align--alignments (rows n)
  "Return a vector of N alignment symbols taken from the delimiter row of ROWS."
  (let ((aligns (make-vector n 'left))
        (delim (seq-find (lambda (r) (plist-get r :delimiter)) rows)))
    (when delim
      (let ((i 0))
        (dolist (cell (plist-get delim :cells))
          (when (and cell (< i n))
            (let ((colons (plist-get cell :colons)))
              (aset aligns i (cond ((and (car colons) (cdr colons)) 'center)
                                   ((cdr colons) 'right)
                                   (t 'left)))))
          (setq i (1+ i)))))
    aligns))

(defun md-table-align--indent-pixels (rows)
  "Return the pixel offset at which ROWS should start.
Measured rather than derived from the column, so an indented table lands
correctly whatever its leading whitespace renders as."
  (let ((first (apply #'min (mapcar (lambda (r) (car (plist-get r :pipes))) rows))))
    (md-table-align--measure
     (save-excursion (goto-char first) (line-beginning-position))
     first)))

(defun md-table-align--delimiter-string (inner unit colons)
  "Return a delimiter spanning at most INNER pixels, honouring COLONS.
UNIT is the pixel width of one character.  A run of dashes can only be a
whole number of characters wide, so the count is rounded *down*: any
shortfall is taken up by the stretch glyph that pins the closing border,
whereas overshooting could not be undone."
  (let* ((n (max 1 (floor inner unit)))
         (s (make-string n ?-)))
    (when (car colons) (aset s 0 ?:))
    (when (cdr colons) (aset s (1- n) ?:))
    s))

(defun md-table-align--window ()
  "Return the window this buffer should be fitted to, if any.
Overlays belong to the buffer rather than to a window, so a table can only
be laid out for one of the windows showing it.  The selected window is the
one the user is reading in; `window-state-change-functions' fires when that
changes, so moving between windows re-fits to whichever you are in."
  (if (eq (window-buffer (selected-window)) (current-buffer))
      (selected-window)
    (car (get-buffer-window-list nil nil nil))))

(defun md-table-align--available-width ()
  "Return the pixel width available to a table, or nil if no window shows it."
  (when-let* ((window (md-table-align--window)))
    (window-body-width window t)))

(defun md-table-align--margin-pixels ()
  "Return the width in pixels of the right margin of the fitted window.
Nil when no window shows the buffer.  Margins are measured in the frame's
canonical characters, whatever face the buffer renders in."
  (when-let* ((window (md-table-align--window)))
    (* (or (cdr (window-margins window)) 0)
       (frame-char-width (window-frame window)))))

(defun md-table-align--continuation-reserve (unit)
  "Return the pixels at the text area's right edge redisplay keeps for itself.

A line that carries on past the window has to say so somewhere.  Where
the window has a right fringe, that is where the indicator goes and the
text area can be filled to its last pixel.  Without one -- a terminal, or
a GUI window with its fringes turned off -- the last column is kept back,
and a line filling the text area exactly wraps onto a second screen line.

This is the one thing between a spilled row and a seamless join: the
margin copy begins where the text area ends, so a column held back here
is a column of blank at the seam."
  (if (when-let* ((window (md-table-align--window)))
        (> (nth 1 (window-fringes window)) 0))
      0
    unit))

(defun md-table-align--fixed-pitch-p (node)
  "Return non-nil when the table at NODE renders in a fixed-pitch face.
Two glyphs at opposite ends of the width range are measured the way
everything else here is measured, so face remapping counts."
  (= (md-table-align--glyph-width node "l")
     (md-table-align--glyph-width node "W")))

(defun md-table-align--spill-pixels (ctx)
  "Return the pixels of right margin the table under CTX may render into.

Zero unless every condition `md-table-align-spill' names holds: the
option is on, there is a margin to spill into, the table is fixed pitch,
and scrolling is available to keep point inside the text area."
  (or (when-let* (((and md-table-align-spill md-table-align-hscroll))
                  ((plist-get ctx :fixed-pitch))
                  (pixels (md-table-align--margin-pixels))
                  ((> pixels 0)))
        pixels)
      0))

(defun md-table-align--table-width (ctx)
  "Return the pixel width the table described by CTX renders at.

Borders are budgeted from one measurement rather than per pipe.  Every
`|' in a table renders in the same face, so the two agree; they could
only diverge if a single table's pipes were faced differently, which the
grammar gives no way to express."
  (let ((widths (plist-get ctx :widths)))
    (+ (plist-get ctx :indent)
       (* (1+ (length widths)) (plist-get ctx :pipe))
       (* (length widths) 2 md-table-align-padding (plist-get ctx :unit))
       (seq-reduce #'+ widths 0))))

(defun md-table-align--viewport (ctx offset)
  "Return the viewport a table with context CTX is clipped to at OFFSET.

The result is a plist of `:offset' (clamped so scrolling cannot run past
the table's right edge), `:budget' -- the pixels left for the table --
`:head', `:lead' and `:trail' for the clipped-edge indicators,
`:phase' -- what the whole grid is shifted right by, so that a column
boundary lands on the text area's edge -- `:clipped' for whether anything
is hidden past the right edge whether or not an indicator says so,
`:quantum' for the granularity `:offset' moves in, and `:maxoff'.

`:budget' and `:head' are widths in the table's own coordinates, measured
from `:offset'; a step at grid X renders at X plus
`md-table-align--shift'.  The split between text area and margin is
therefore at `:head' plus that shift -- which is the text area's right
edge exactly, `:phase' being what makes it a column boundary.

`:budget' is what the table may render into, which under
`md-table-align-spill' includes the right margin.  `:head' is the part of
that inside the text area: where the spill splits each row, and the
viewport point is kept within, since Emacs cannot draw the cursor in a
margin.  Without spilling the two are equal and everything below reduces
to fitting the text area, which is what this did before margins came into
it.

Nil when nothing should be clipped: no window to measure against, or
scrolling turned off.  The indicators are folded into the budget rather
than drawn over the table, so that a column is never half-hidden behind
one."
  (when-let* (((and md-table-align-hscroll (> (length (plist-get ctx :widths)) 0)))
              (avail (md-table-align--available-width)))
    (let* ((unit (plist-get ctx :unit))
           (ell (if md-table-align-hscroll-indicator (plist-get ctx :ellipsis) 0))
           (width (plist-get ctx :table-width))
           ;; Whole characters of margin: a copy is a string, so a fraction of
           ;; a character at the margin's outer edge is width no column can be
           ;; put in.
           (spill (let ((px (md-table-align--spill-pixels ctx)))
                    (* unit (floor px unit))))
           ;; The copy of a spilled row starts at the text area's right edge,
           ;; in whole characters, and a string cannot be nudged by a fraction
           ;; of one.  So the join is seamless only if the table's grid has a
           ;; column boundary exactly at that edge, which is a property of the
           ;; window rather than of the table: shift the whole grid right by
           ;; the remainder, less than one character, and it does.
           (phase (if (> spill 0)
                      (mod (- avail (plist-get ctx :indent)) unit)
                    0))
           ;; Reserve one character cell: a wrapped line spends one on the
           ;; continuation glyph, and it absorbs rounding at the window edge.
           ;; A spilled row is the one case where that column can be had back
           ;; -- see `md-table-align--continuation-reserve' -- and it is worth
           ;; having back, because the copy starts at the text area's edge
           ;; whatever the head did, so a column kept here is blank at the
           ;; seam and every column past it stands a character off the grid.
           (head-avail (- avail phase
                          (if (> spill 0)
                              (md-table-align--continuation-reserve unit)
                            unit)))
           (available (+ head-avail spill))
           ;; At the rightmost offset a lead indicator is showing, so that is
           ;; the budget the limit has to be computed against.  Choosing it
           ;; this way makes the clamp a fixed point: laying out at `maxoff'
           ;; reproduces exactly this budget, and the table's right edge lands
           ;; exactly on the viewport's.
           ;;
           ;; Against the *head*, not the whole budget: the limit's job is to
           ;; let point reach the last column, and point can only stand in the
           ;; text area.  A table that fits the full width still scrolls once
           ;; point moves into the part rendered in the margin -- and only
           ;; then, since an offset belongs to the table point is in.
           ;; A spilled table scrolls in whole characters.  The offset is a
           ;; pixel count, and the head can render at any pixel -- but the copy
           ;; in the margin is a string, laid out from the margin's edge in
           ;; whole characters, with no way to express a fraction of one.  At a
           ;; fractional offset the two drift apart by that fraction, on every
           ;; column of every row.  Quantising is also what this claimed to do
           ;; all along: scrolling "mirrors what a `truncate-lines' buffer
           ;; already does", and Emacs scrolls those by columns.  It is safe
           ;; precisely when spilling is, since both need a fixed pitch.
           (quantum (if (> spill 0) unit 1))
           (limit (if (<= width head-avail) 0 (max 0 (- width (- head-avail ell)))))
           ;; Down, so the clamp stays a fixed point; the ellipsis reserve is
           ;; wider than the character this gives up.
           (maxoff (* quantum (floor limit quantum)))
           (o (max 0 (min maxoff (* quantum (round offset quantum)))))
           (lead (if (> o 0) ell 0))
           ;; Kept apart from `trail': with the indicators off there is no
           ;; indicator to read the clipping off, and the scrolling commands
           ;; still have to know whether anything is hidden.
           (clipped (> (- width o) (- available lead)))
           (trail (if clipped ell 0))
           (budget (- available lead trail))
           ;; A trail indicator sits at the right edge of what renders, which
           ;; is inside the margin when spilling and inside the text area
           ;; otherwise.
           (head (if (> spill 0) (- head-avail lead) budget)))
      ;; A window with no room for even a couple of characters of table would
      ;; clip it to nothing.  Leaving it to wrap is the better failure: it is
      ;; what happened before any of this existed, and it hides nothing.
      (when (>= head (* 2 unit))
        (list :offset o
              :lead lead
              :trail trail
              :budget budget
              :head head
              :phase phase
              :clipped clipped
              :quantum quantum
              :maxoff maxoff)))))

(defun md-table-align--shift (view)
  "Return the pixels a step's grid position is shifted by to render under VIEW.
Scrolling moves the grid left by the offset, a lead indicator moves what
is left of it right, and `:phase' aligns the whole thing to the text
area's right edge.  Nil VIEW -- an unclipped table -- shifts nothing."
  (if view
      (+ (plist-get view :phase)
         (- (plist-get view :lead) (plist-get view :offset)))
    0))

(defun md-table-align--content-offset (align width cell-width unit)
  "Return leading padding for CELL-WIDTH text in a WIDTH column under ALIGN.

Centring halves the slack, which is the one place a whole-character grid
can produce half a character, so it rounds down to UNIT -- the extra half
goes to the right of the text, where the column's own padding already
is."
  (pcase align
    ('right (max 0 (- width cell-width)))
    ('center (* unit (/ (max 0 (- width cell-width)) (* 2 unit))))
    (_ 0)))

(defun md-table-align--pipe-width (ctx pos)
  "Return the rendered width of the pipe at POS, memoised on CTX.
Measured rather than assumed, for the same reason cell widths are --
markup hiding can render every pipe at zero -- but measured *once* per
context: every `|' in a table renders in the same face (the reasoning in
`md-table-align--table-width'), and one measurement per pipe per layout
pass was a visible slice of the many-tables profile.  The memo rides on
CTX, so it lives exactly as long as the measurements it accompanies: a
cached context keeps it across passes, and anything that drops or
recomputes the context drops it too."
  (or (plist-get ctx :pipe-render)
      (let ((w (md-table-align--measure pos (1+ pos))))
        (plist-put ctx :pipe-render w)
        w)))

(defun md-table-align--row-plan (row ctx)
  "Return the layout steps for ROW under context CTX, in buffer order.

Each step is a plist describing one thing that has to land somewhere
definite on the grid: `:kind' is `pipe', `content' or `dashes', `:beg'
and `:end' bound the buffer text it covers, `:x' is the pixel column its
rendering starts at and `:width' how wide that rendering is.

Computing the grid separately from placing it is what makes horizontal
scrolling possible.  The coordinates here are absolute -- what the table
would look like in an unbounded window -- and the viewport is a
transformation applied to them afterwards.  Deriving a scroll offset from
buffer columns instead looks equivalent and is not: cells differ in
length, so the same buffer column is a different grid column on every
row, and the alignment the package exists to provide collapses."
  (let* ((widths (plist-get ctx :widths))
         (aligns (plist-get ctx :aligns))
         (unit (plist-get ctx :unit))
         (pipes (plist-get row :pipes))
         (cells (plist-get row :cells))
         (delimiter (plist-get row :delimiter))
         (pad (* md-table-align-padding unit))
         (x (plist-get ctx :indent))
         (i 0)
         steps)
    (dolist (cell cells)
      (let ((width (aref widths i))
            (open (nth i pipes)))
        ;; Without an opening pipe there is no border to align against.
        (when open
          ;; A column may have no cell node at all, and an empty cell's
          ;; trimmed bounds collapse onto the closing border.
          (let* ((beg (if cell (plist-get cell :beg) (1+ open)))
                 (end (if cell (plist-get cell :end) (1+ open)))
                 (cell-width (if cell (plist-get cell :width) 0))
                 (close (nth (1+ i) pipes))
                 (inner (+ pad width pad))
                 (pw (md-table-align--pipe-width ctx open)))
            (push (list :kind 'pipe :beg open :end (1+ open) :x x :width pw)
                  steps)
            (setq x (+ x pw))
            (cond
             (delimiter
              ;; The dashes are re-rendered across the full inner width,
              ;; matching the `|:------|----:|' style `markdown-table-align'
              ;; produces.
              (push (list :kind 'dashes
                          :beg (1+ open) :end (or close (1+ end))
                          :x x :width inner
                          :colons (and cell (plist-get cell :colons)))
                    steps))
             ;; Nothing to position when the cell is empty: the stretch to the
             ;; closing border takes care of the whole gap.
             ((> end beg)
              (push (list :kind 'content :beg beg :end end
                          :x (+ x pad (md-table-align--content-offset
                                       (aref aligns i) width cell-width unit))
                          :width cell-width)
                    steps)))
            (setq x (+ x inner))))
        (setq i (1+ i))))
    ;; The pipe closing the last column belongs to no cell of its own.
    (when-let* ((last (nth (length cells) pipes)))
      (push (list :kind 'pipe :beg last :end (1+ last) :x x
                  :width (md-table-align--pipe-width ctx last))
            steps))
    (nreverse steps)))

(defun md-table-align--clip-steps (steps lo hi)
  "Return the members of STEPS rendering inside the pixel span [LO, HI).

Steps wholly outside it are dropped, and steps straddling an edge are
trimmed according to what they are: `content' is split at a character
boundary and keeps the part inside, `dashes' is simply regenerated
narrower, and a `pipe' is all-or-nothing, since half a border reads as a
mistake rather than as a clipped edge.

A dropped pipe is never stranded between two visible steps.  At the left
edge everything before it is further left still, so it falls inside the
hidden prefix; at the right edge, inside the hidden suffix."
  (delq
   nil
   (mapcar
    (lambda (step)
      (let ((x (plist-get step :x))
            (w (plist-get step :width))
            (beg (plist-get step :beg))
            (end (plist-get step :end)))
        (unless (or (<= (+ x w) lo) (>= x hi))
          (pcase (plist-get step :kind)
            ('pipe (and (>= x lo) (<= (+ x w) hi) step))
            ('content
             (let ((b beg) (e end) (nx x))
               (when (< x lo)
                 (setq b (md-table-align--split-at beg end (- lo x))
                       nx (+ x (md-table-align--measure beg b))))
               (when (> (+ x w) hi)
                 (setq e (md-table-align--split-at beg end (- hi x))))
               (when (> e b)
                 (list :kind 'content :beg b :end e :x nx
                       :width (md-table-align--measure b e)))))
            ('dashes
             ;; A dash run's rendered width has no relation to how many
             ;; characters back it, so it cannot be split at a character the
             ;; way content can.  It is regenerated at the visible width
             ;; instead, and keeps only the alignment colons whose end of the
             ;; run survived.
             (let ((vx (max x lo))
                   (vend (min (+ x w) hi))
                   (colons (plist-get step :colons)))
               (when (> vend vx)
                 (list :kind 'dashes :beg beg :end end :x vx
                       :width (- vend vx)
                       :colons (cons (and (car colons) (>= x lo))
                                     (and (cdr colons) (<= (+ x w) hi)))))))))))
    steps)))

(defun md-table-align--place (step from shift unit first)
  "Place the overlays rendering STEP, shifted by SHIFT pixels.
FROM is the buffer position the preceding step ended at, UNIT the pixel
width of one character, and FIRST marks the leftmost visible step."
  (let ((x (+ (plist-get step :x) shift))
        (beg (plist-get step :beg))
        (end (plist-get step :end)))
    (pcase (plist-get step :kind)
      ('dashes
       ;; The dash string is generated to length, so it positions itself --
       ;; except at the viewport's left edge, where there is a clipped prefix
       ;; in front of it to step over.
       (when first (md-table-align--pad beg beg x))
       (md-table-align--replace
        beg end (md-table-align--delimiter-string
                 (plist-get step :width) unit (plist-get step :colons))))
      (_ (md-table-align--pad from beg x)))))

(defun md-table-align--layout-row (row ctx)
  "Place overlays laying ROW out according to layout context CTX.
When CTX carries a `:view', the row is clipped to it and everything
outside is hidden; otherwise the row is laid out in full and may wrap."
  (let* ((view (plist-get ctx :view))
         (offset (if view (plist-get view :offset) 0))
         (steps (md-table-align--row-plan row ctx))
         (visible (if view
                      (md-table-align--clip-steps
                       steps offset (+ offset (plist-get view :budget)))
                    steps))
         (first-pipe (car (plist-get row :pipes)))
         (bol (save-excursion (goto-char first-pipe) (line-beginning-position)))
         (eol (save-excursion (goto-char first-pipe) (line-end-position))))
    (if (null visible)
        ;; Scrolled clear of every column on this row.
        (when view (md-table-align--hide bol eol (> offset 0)))
      (let ((cut (plist-get (car visible) :beg))
            (cutr (plist-get (car (last visible)) :end))
            (shift (md-table-align--shift view))
            (prev nil))
        (when view
          ;; Everything outside the viewport is one contiguous buffer prefix
          ;; and one contiguous suffix -- different ones on every row, since
          ;; the grid position of a buffer position depends on the row's own
          ;; cell contents.
          (md-table-align--hide bol cut (> (plist-get view :lead) 0))
          ;; The right-hand indicator stands at the viewport's edge on every
          ;; row, not after whatever the row last showed.  A row whose next
          ;; step starts past the edge -- a short header cell in a wide
          ;; column -- would otherwise end mid-table with `Change…', reading
          ;; as a truncated word, and under spilling it would stop in the
          ;; text area with nothing past it to put in the margin.
          (md-table-align--hide cutr eol (> (plist-get view :trail) 0)
                                (+ offset (plist-get view :budget) shift)))
        ;; With the clipped text rendering at zero width, what is left lays
        ;; out compactly, so every step sits left of its target and each
        ;; stretch glyph still only ever pushes forward -- which is the
        ;; invariant alignment has relied on since v1.
        (dolist (step visible)
          (md-table-align--place step (or prev cut) shift
                                 (plist-get ctx :unit) (null prev))
          (setq prev (plist-get step :end)))))))

;;;; Margin spill
;;
;; A row wider than the text area is split: the head stays real buffer text,
;; the tail is hidden and re-emitted as a string in the right margin, which is
;; the one place a `display' spec can render outside the text area.  What the
;; tail says is taken from what the laid-out row *renders* -- stretch glyphs,
;; display strings, hidden spans and all -- rather than rebuilt from the row
;; plan, because by then its cells may carry display properties belonging to
;; other packages.  See "Margin spill" in DESIGN.md.

(defun md-table-align--spill-face (face)
  "Return FACE as a margin string should carry it.
A margin string takes every attribute it does not specify from the
`margin' face, so `default' is appended to stand behind it.

Nothing in a copy may go unfaced, padding least of all.  In the text area
a `display' string with no face of its own renders in the face of the
text it replaces; in a margin there is no such text, so it would fall
back to `margin' -- the buffer's default face, which under
`mixed-pitch-mode' is the *proportional* one.  A run of padding would
then be narrower than the same run of columns in the text area, and the
copy would drift left of the grid it belongs to."
  (cond ((null face) 'default)
        ((keywordp (car-safe face)) (list face 'default))
        ((listp face) (append face '(default)))
        (t (list face 'default))))

(defun md-table-align--spill-space (spec x unit)
  "Return the pixel a `space' display SPEC starting at pixel X reaches.
UNIT is the pixel width of one character.  `md-table-align--pad' emits
the `(PIXELS)' form of `:align-to'; the others are handled for the sake
of specs this package did not write."
  (let ((align (plist-get (cdr spec) :align-to))
        (width (plist-get (cdr spec) :width)))
    (cond ((and (consp align) (null (cdr align))) (max x (car align)))
          ((numberp align) (max x (* align (frame-char-width))))
          ((and (consp width) (null (cdr width))) (+ x (car width)))
          ((numberp width) (+ x (* width unit)))
          (t (+ x unit)))))

(defun md-table-align--text-piece (string face x)
  "Return a piece for STRING shown in FACE, rendering from pixel X.
The piece's width is *measured*, in the face it will carry in a copy.
Counting its characters instead assumes every one is as wide as the
table's own, and a cell need not be in the table's font: a code span
is in a font of its own, fixed pitch too but not necessarily the same
pitch.  Counted, a row of those is cut characters early and its copy
padded to the wrong length."
  (let ((text (propertize (substring-no-properties string)
                          'face (md-table-align--spill-face face))))
    (list :kind 'text :text text :x x
          :end (+ x (funcall md-table-align-pixel-width-function text)))))

(defun md-table-align--flatten-string (string x unit face)
  "Return (PIECES . END) for display STRING laid out from pixel X.
FACE stands in where STRING specifies none -- a `display' string carries
the face of the text it replaces.  One piece per run of one face, which
`md-table-align--split-piece' can cut anywhere."
  (let ((pieces nil) (i 0) (n (length string)))
    (while (< i n)
      (let ((spec (get-text-property i 'display string))
            (own (get-text-property i 'face string))
            (next (min (next-single-property-change i 'display string n)
                       (next-single-property-change i 'face string n))))
        (if (and (consp spec) (eq (car spec) 'space))
            (let ((end (md-table-align--spill-space spec x unit)))
              (push (list :kind 'pad :x x :end end :face (or own face)) pieces)
              (setq x end))
          (let ((piece (md-table-align--text-piece
                        (substring string i next) (or own face) x)))
            (push piece pieces)
            (setq x (plist-get piece :end))))
        (setq i next)))
    (cons (nreverse pieces) x)))

(defun md-table-align--flatten (bol eol unit face)
  "Return what the line between BOL and EOL renders as, piece by piece.

Each piece is a plist of `:beg' and `:end-pos' -- the buffer span it came
from -- `:x' and `:end' in pixels from the start of the text area, and a
`:kind'.  A `pad' is a stretch glyph, with the `:face' its padding shows
in.  A `text' piece carries the `:text' a copy of it should show; with
`:source' `buffer' that text is the buffer's own, one character for one
position from `:beg', and otherwise it came from a string shown in place
of, or in front of, the buffer span.

FACE is the table's own face, which stands behind every piece that
specifies none: the copy has to render in the face the pixel targets were
measured in, or its columns are not the table's columns.

That is the text's own `face' property and never an overlay's.  The grid
was measured from `buffer-substring', which carries no overlays, and an
overlay face over a table is a highlight -- `hl-line', the region,
`markdown-ts-in-table-mode' covering the table point is in -- with no
font of its own.  Taken in place of the text's face, as
`get-char-property' would take it, it hands the copy the buffer's default
font: under `mixed-pitch-mode' a proportional one, narrower than the
table, so the head keeps more than fits and wraps, and the margin copy
comes out in the wrong font.  A highlight not reaching the copy is the
static copy DESIGN.md already records."
  (let ((pos bol) (x 0) (pieces nil))
    (while (< pos eol)
      ;; Strings shown in front of the text here, which is where every
      ;; zero-width `md-table-align--pad' stretch lives.
      (dolist (ov (overlays-in pos (min eol (1+ pos))))
        (when-let* (((eql (overlay-start ov) pos))
                    (string (overlay-get ov 'before-string)))
          (let ((flat (md-table-align--flatten-string
                       string x unit (or (get-text-property pos 'face) face))))
            (dolist (piece (car flat))
              (push (append (list :beg pos :end-pos pos :source 'before) piece)
                    pieces))
            (setq x (cdr flat)))))
      (let ((spec (get-char-property pos 'display)))
        (cond
         ((invisible-p pos)
          (setq pos (min eol (next-single-char-property-change
                              pos 'invisible nil eol))))
         (spec
          (let ((end (min eol (next-single-char-property-change
                               pos 'display nil eol))))
            (cond
             ((stringp spec)
              (let ((flat (md-table-align--flatten-string
                           spec x unit (or (get-text-property pos 'face) face))))
                (dolist (piece (car flat))
                  (push (append (list :beg pos :end-pos end :source 'display) piece)
                        pieces))
                (setq x (cdr flat))))
             ((and (consp spec) (eq (car spec) 'space))
              (let ((to (md-table-align--spill-space spec x unit)))
                (push (list :kind 'pad :beg pos :end-pos end :x x :end to
                            :face (or (get-text-property pos 'face) face))
                      pieces)
                (setq x to))))
            (setq pos end)))
         (t
          ;; A run of plain text, measured whole: one measurement per face
          ;; per cell rather than one per character.  It ends wherever
          ;; anything that changes how the text renders could begin --
          ;; another face, a `display' or `invisible' span, or an overlay
          ;; that may carry a string of its own.
          (let* ((end (min eol
                           (next-single-char-property-change pos 'display nil eol)
                           (next-single-char-property-change pos 'invisible nil eol)
                           (next-single-property-change pos 'face nil eol)
                           (next-overlay-change pos)))
                 (piece (md-table-align--text-piece
                         (buffer-substring-no-properties pos end)
                         (or (get-text-property pos 'face) face) x)))
            (push (append (list :beg pos :end-pos end :source 'buffer) piece)
                  pieces)
            (setq x (plist-get piece :end) pos end))))))
    (nreverse pieces)))

(defun md-table-align--fit (text limit)
  "Return how many leading characters of TEXT render within LIMIT pixels.
Bisected, as in `md-table-align--split-at', since a wider prefix is
never narrower."
  (let ((lo 0) (hi (length text)))
    (while (< lo hi)
      (let ((mid (/ (+ lo hi 1) 2)))
        (if (<= (funcall md-table-align-pixel-width-function (substring text 0 mid))
                limit)
            (setq lo mid)
          (setq hi (1- mid)))))
    lo))

(defun md-table-align--split-piece (piece at)
  "Return (BEFORE . AFTER), PIECE cut where it renders past pixel AT.
Either may be nil.  A stretch is cut at the pixel; text only between
characters, so the character straddling AT goes to AFTER whole -- it
cannot be shown in the text area without reaching past it.  Buffer text
cut this way moves AFTER's `:beg' to the first position it holds."
  (let ((x (plist-get piece :x))
        (end (plist-get piece :end)))
    (cond
     ((<= end at) (cons piece nil))
     ((>= x at) (cons nil piece))
     ((eq (plist-get piece :kind) 'pad)
      (cons (plist-put (copy-sequence piece) :end at)
            (plist-put (copy-sequence piece) :x at)))
     (t
      (let* ((text (plist-get piece :text))
             (k (md-table-align--fit text (- at x))))
        (if (zerop k)
            (cons nil piece)
          (let* ((mid (+ x (funcall md-table-align-pixel-width-function
                                    (substring text 0 k))))
                 (before (copy-sequence piece))
                 (after (copy-sequence piece)))
            (plist-put before :text (substring text 0 k))
            (plist-put before :end mid)
            (plist-put after :text (substring text k))
            (plist-put after :x mid)
            (when (eq (plist-get piece :source) 'buffer)
              (plist-put before :end-pos (+ (plist-get piece :beg) k))
              (plist-put after :beg (+ (plist-get piece :beg) k)))
            (cons before after))))))))

(defun md-table-align--spill-text (pieces x unit &optional limit)
  "Return PIECES as one string, as it renders starting at pixel X.
UNIT is the pixel width of one space in the table's face.

Text goes in as it is and moves X on by its measured width.  A stretch
cannot go in at all -- inside a margin string, and inside any `display'
string, a space spec collapses to one column -- so each is written as
spaces, as many as bring X nearest the pixel it was aiming for.
Counting from where the string has actually got to, rather than from
each stretch's own width, is what stops the rounding accumulating: a
cell whose text is not a whole number of spaces wide costs the pipe
after it less than half a space, and the pipe after that nothing.

With LIMIT, no stretch runs X past that pixel."
  (let ((out nil))
    (dolist (piece pieces)
      (if (eq (plist-get piece :kind) 'pad)
          (let* ((to (if limit
                         (min limit (plist-get piece :end))
                       (plist-get piece :end)))
                 (n (max 0 (round (- to x) unit))))
            (when (and limit (> (+ x (* n unit)) limit))
              (setq n (max 0 (floor (- limit x) unit))))
            (push (propertize (make-string n ?\s)
                              'face (md-table-align--spill-face
                                     (plist-get piece :face)))
                  out)
            (setq x (+ x (* n unit))))
        (push (plist-get piece :text) out)
        (setq x (+ x (- (plist-get piece :end) (plist-get piece :x))))))
    (apply #'concat (nreverse out))))

(defun md-table-align--spill-overlay (beg end)
  "Return a spill overlay over BEG to END, tagged for clearing."
  (let ((ov (make-overlay beg end)))
    (overlay-put ov 'md-table-align t)
    (overlay-put ov 'md-table-align-spill t)
    ov))

(defun md-table-align--spill-row (bol eol head unit face)
  "Render what the line between BOL and EOL puts past HEAD in the margin.
UNIT is the pixel width of one character and FACE the table's own face.
Returns the margin string, or nil when the line ends inside the text area
and nothing has to spill."
  (let* ((pieces (md-table-align--flatten bol eol unit face))
         (before (seq-take-while (lambda (p) (<= (plist-get p :end) head)) pieces))
         (rest (nthcdr (length before) pieces)))
    (when rest
      (let* ((cut (md-table-align--split-piece (car rest) head))
             (before (if (car cut) (append before (list (car cut))) before))
             (tail (cons (cdr cut) (cdr rest)))
             (beg (plist-get (car tail) :beg))
             ;; A `display' string straddling the split is one buffer span:
             ;; hiding from its start would take the head's part of it too.
             (kept (and (eq (plist-get (car tail) :source) 'display)
                        (seq-filter (lambda (p)
                                      (and (eq (plist-get p :source) 'display)
                                           (eql (plist-get p :beg) beg)))
                                    before)))
             (split (if kept (plist-get (car tail) :end-pos) beg))
             (string (md-table-align--spill-text tail head unit)))
        (when (> (length string) 0)
          (when (> split beg)
            (let ((ov (md-table-align--spill-overlay beg split)))
              (overlay-put ov 'evaporate t)
              (overlay-put ov 'priority 10)
              ;; A stretch straddling the split keeps only its head: left
              ;; whole it would reach past the text area and wrap the line,
              ;; the very thing spilling exists to prevent.
              (overlay-put ov 'display
                           (md-table-align--spill-text
                            kept (plist-get (car kept) :x) unit head))))
          (let ((ov (md-table-align--spill-overlay split eol)))
            (overlay-put ov 'evaporate t)
            ;; Not `invisible': a `display' overlay starting at the same
            ;; position is handled first and would render anyway.  Outranking
            ;; the alignment overlays is what takes them out of the text area.
            (overlay-put ov 'priority 10)
            (overlay-put ov 'display ""))
          ;; Hiding the text does not hide the strings in front of it: those
          ;; belong to other overlays, and priority only settles which
          ;; `display' wins.  Past the split they are in the copy already, and
          ;; left in place a stretch among them would reach past the text area.
          (dolist (ov (overlays-in split eol))
            (when (and (overlay-get ov 'md-table-align)
                       (not (overlay-get ov 'md-table-align-spill))
                       (>= (overlay-start ov) split))
              (overlay-put ov 'before-string nil)))
          ;; An empty overlay, so it cannot `evaporate' and cannot be hidden
          ;; by the `display' spec that starts further along the line.
          (overlay-put (md-table-align--spill-overlay bol bol) 'before-string
                       (propertize " " 'display
                                   `((margin right-margin) ,string)))
          string)))))

(defun md-table-align--spill-rows (ctx)
  "Spill every row of the table under CTX that overflows the text area."
  (when-let* ((view (plist-get ctx :view))
              (head (plist-get view :head))
              ((> (plist-get view :budget) head))
              ;; `:head' is a width on the grid; the rows are flattened as
              ;; they render, from the text area's left edge, so the split
              ;; has to be converted to that.  Leaving it on the grid cuts
              ;; every row a lead indicator's width early -- and the copy,
              ;; which begins where the text area ends whatever the head did,
              ;; then stands a character clear of the row it continues.
              (split (+ (plist-get view :offset) head
                        (md-table-align--shift view))))
    (dolist (row (plist-get ctx :rows))
      (when-let* ((pipe (car (plist-get row :pipes))))
        (save-excursion
          (goto-char pipe)
          (md-table-align--spill-row (line-beginning-position)
                                     (line-end-position)
                                     split (plist-get ctx :unit)
                                     (plist-get ctx :face)))))))

(defun md-table-align--measure-table (node)
  "Return the layout context for the table at NODE, or nil if it has no rows.
Widths are measured before any overlay exists -- the region is swept
clear first, and `buffer-substring' carries text properties but not
overlays -- so a clipped table is never measured against its own
clipping."
  (let ((rows (md-table-align--parse-table node)))
    (when (cdr rows)
      (let* ((unit (md-table-align--glyph-width node " "))
             (fixed (md-table-align--fixed-pitch-p node))
             ;; Every pixel of a fixed-pitch table's grid is a whole character,
             ;; so that a margin copy -- literal spaces, and nothing else is
             ;; available -- can reproduce it exactly.  See
             ;; `md-table-align--quantise-widths'.
             (whole (lambda (px) (if fixed (md-table-align--quantise px unit) px)))
             (rows (if fixed (md-table-align--quantise-widths rows unit) rows))
             (widths (md-table-align--column-widths rows unit))
             (ctx (list :rows rows
                        :widths widths
                        :aligns (md-table-align--alignments rows (length widths))
                        :indent (funcall whole (md-table-align--indent-pixels rows))
                        :unit unit
                        :fixed-pitch fixed
                        ;; The face every width here was measured in; see
                        ;; `md-table-align--glyph-width'.  A margin copy has to
                        ;; render in it or it is not on the table's grid.
                        :face (get-text-property (treesit-node-start node) 'face)
                        :pipe (funcall whole (md-table-align--glyph-width node "|"))
                        ;; On the grid too: an indicator shifts every step of
                        ;; the row it appears on by its own width.
                        :ellipsis (funcall whole
                                           (md-table-align--glyph-width
                                            node md-table-align-ellipsis)))))
        (plist-put ctx :table-width (md-table-align--table-width ctx))))))

(defconst md-table-align--measured-properties
  '(face display invisible composition)
  "Text properties that participate in what a cell measures.
The complement of `md-table-align--unmeasurable-properties': these are
the properties `string-pixel-width' renders, so they are what the
metrics cache key has to be sensitive to.")

(defun md-table-align--content-key (beg end)
  "Return a key describing what measurement sees between BEG and END.
The text, plus its intervals of `md-table-align--measured-properties'.
Two regions with `equal' keys measure identically -- which is what makes
this a valid cache key where `buffer-modified-tick' was only a proxy:
the tick advances whenever any property is written, including font-lock
re-applying identical faces on a re-fontification pass, and a cache
keyed on it could never survive the re-fit after a window resize.  What
no property records -- face remapping, `buffer-invisibility-spec' -- is
the layout key's job; see `md-table-align--refit'."
  (let ((s (buffer-substring beg end)))
    (cons (substring-no-properties s)
          (mapcar (lambda (interval)
                    (cons (car interval)
                          (mapcar (lambda (prop)
                                    (plist-get (nth 2 interval) prop))
                                  md-table-align--measured-properties)))
                  (object-intervals s)))))

(defun md-table-align--metrics (node)
  "Return the layout context for the table at NODE, measuring it if needed.

Memoised per table, keyed on what measurement actually consumes (see
`md-table-align--content-key') plus the padding setting.  Point motion
inside a table consults the grid on every command, and re-measuring
every cell that often would make simply moving the cursor crawl;
building and comparing the key is a few C-level passes over the table's
text, noise next to a single `string-pixel-width' call.

The table's start position is the hash key, so an edit above a table
moves it to a fresh entry and the old one goes stale in place; the
caches are dropped wholesale when they could be wrong (see
`md-table-align--refit') and capped against unbounded growth in
`md-table-align--align-region'."
  (let* ((beg (treesit-node-start node))
         (end (treesit-node-end node))
         (key (cons md-table-align-padding
                    (md-table-align--content-key beg end)))
         (caches (or md-table-align--metrics-caches
                     (setq md-table-align--metrics-caches
                           (make-hash-table :test #'eql))))
         (cached (gethash beg caches)))
    (if (and cached (equal (car cached) key))
        (cdr cached)
      (let ((ctx (md-table-align--measure-table node)))
        (puthash beg (cons key ctx) caches)
        ctx))))

(defun md-table-align--layout-table (node)
  "Align the table at NODE by placing overlays.
A table toggled vertical is rendered as records instead; one with no
data rows to make records of falls back to the horizontal layout."
  (when-let* ((ctx (md-table-align--metrics node)))
    (unless (and (md-table-align--vertical-p node)
                 (md-table-align--layout-vertical ctx))
      (let ((ctx (plist-put (copy-sequence ctx)
                            :view (md-table-align--viewport
                                   ctx (md-table-align--offset-of node)))))
        (dolist (row (plist-get ctx :rows))
          (md-table-align--layout-row row ctx))
        ;; After layout, not during it: what spills is what the finished row
        ;; renders as, including the display properties other packages put
        ;; inside its cells.
        (md-table-align--spill-rows ctx)))))

;;;; Vertical records view
;;
;; A table toggled vertical renders as psql's `\x' expanded display: each data
;; row becomes a block of `label | value' lines under a record separator.  The
;; values are already in buffer order, so they stay real, visible buffer text;
;; only the labels -- which repeat once per record, something buffer text
;; cannot do -- are synthesized, in the overlay strings that hide the pipes.

(defun md-table-align--vertical-p (node)
  "Return non-nil when the table at NODE is toggled vertical."
  (let ((beg (treesit-node-start node)))
    (seq-some (lambda (m) (eql (marker-position m) beg))
              md-table-align--vertical-tables)))

(defun md-table-align--vertical-labels (ctx)
  "Return a vector of label strings for the columns of the table under CTX.
Labels are the header cells' text under `md-table-align-vertical-label'.
A column the header does not name -- ragged tables -- falls back to its
1-based number."
  (let* ((header (seq-find (lambda (r) (not (plist-get r :delimiter)))
                           (plist-get ctx :rows)))
         (cells (plist-get header :cells))
         (n (length (plist-get ctx :widths)))
         (labels (make-vector n nil)))
    (dotimes (j n)
      (let* ((cell (nth j cells))
             (text (if (and cell (< (plist-get cell :beg) (plist-get cell :end)))
                       (buffer-substring-no-properties
                        (plist-get cell :beg) (plist-get cell :end))
                     (number-to-string (1+ j)))))
        (aset labels j (propertize text
                                   'face 'md-table-align-vertical-label))))
    labels))

(defun md-table-align--inject (from to string)
  "Render STRING in place of the buffer text between FROM and TO.

Not `md-table-align--replace': a `display' *string* does not process the
`display' properties of its own text, so a stretch glyph inside one is
inert.  An overlay's `before-string' does process them -- it is what
every `md-table-align--pad' stretch already rides on -- so the region is
hidden with `display' \"\" and STRING rides in front of it."
  (let ((ov (make-overlay from to)))
    (overlay-put ov 'md-table-align t)
    (overlay-put ov 'evaporate t)
    (overlay-put ov 'display "")
    (overlay-put ov 'before-string string)
    ov))

(defun md-table-align--layout-vertical-row (row index ctx labels separator wrap)
  "Place overlays rendering ROW as vertical record number INDEX.
CTX is the table's layout context, LABELS the vector from
`md-table-align--vertical-labels', SEPARATOR the shared
stretch-pipe-stretch string ending at the column values start at, and
WRAP the `wrap-prefix' string continuing the rail on wrapped lines.

Each span from one cell's content end to the next cell's content start
-- never empty, since it holds at least the pipe -- is replaced by a
newline, a stretch to the table's indent, the label, and SEPARATOR.
The values between those spans are left visible, under an overlay
carrying WRAP: a long value's continuation lines can only begin inside
visible value text -- the hidden spans never wrap -- so this is exactly
the text whose wrapping needs the prefix, and the label lines, which
begin inside a span's `before-string', never inherit it."
  (let* ((pipes (plist-get row :pipes))
         (indent (plist-get ctx :indent))
         (eol (save-excursion (goto-char (car pipes)) (line-end-position)))
         (prev (car pipes))
         (j 0))
    (dolist (cell (plist-get row :cells))
      (when-let* ((open (nth j pipes)))
        (let ((beg (if cell (plist-get cell :beg) (1+ open)))
              (end (if cell (plist-get cell :end) (1+ open))))
          (md-table-align--inject
           prev beg
           (concat (if (= j 0)
                       (concat
                        (propertize
                         (format md-table-align-vertical-record-format index)
                         'face 'md-table-align-vertical-record)
                        "\n")
                     "\n")
                   (if (> indent 0) (md-table-align--stretch indent) "")
                   (aref labels j)
                   separator))
          (when (< beg end)
            (let ((ov (make-overlay beg end)))
              (overlay-put ov 'md-table-align t)
              (overlay-put ov 'evaporate t)
              (overlay-put ov 'wrap-prefix wrap)))
          (setq prev end)))
      (setq j (1+ j)))
    ;; The closing pipe and any trailing whitespace end no label line.
    (md-table-align--replace prev eol "")))

(defun md-table-align--layout-vertical (ctx)
  "Place overlays rendering the table under CTX as vertical records.
Returns non-nil when the layout was applied; nil -- no data rows to make
records of -- asks the caller to lay the table out horizontally instead."
  (let* ((rows (seq-remove (lambda (r) (plist-get r :delimiter))
                           (plist-get ctx :rows)))
         (data (cdr rows)))
    (when data
      (let ((labels (md-table-align--vertical-labels ctx))
            (unit (plist-get ctx :unit))
            (indent (plist-get ctx :indent)))
        ;; The header lives on as the labels and the delimiter row's alignment
        ;; markers mean nothing vertically, so both lines -- newlines included,
        ;; or they would remain as blanks -- render as nothing.
        (md-table-align--replace
         (save-excursion (goto-char (car (plist-get (car rows) :pipes)))
                         (line-beginning-position))
         (save-excursion (goto-char (car (plist-get (car data) :pipes)))
                         (line-beginning-position))
         "")
        ;; The label lines share one stretch-pipe-stretch tail: a stretch to
        ;; the pipe column -- indent plus widest label plus the gap -- the
        ;; pipe, and a stretch past its measured width plus the gap again, to
        ;; the common column the values start at.  The wrap prefix repeats
        ;; that geometry on a wrapped value's continuation lines, but with
        ;; `:width' stretches: `:align-to' -- either form -- is silently
        ;; inert inside a `wrap-prefix' string (see DESIGN.md v8), and a
        ;; prefix always starts at the wrap margin, so absolute widths land
        ;; on the same columns.
        (let* ((gap (* md-table-align-vertical-pipe-gap unit))
               (pipe (propertize "|" 'face 'md-table-align-vertical-pipe))
               (pipe-x (+ indent gap
                          (seq-reduce
                           (lambda (acc label)
                             (max acc (funcall md-table-align-pixel-width-function
                                               label)))
                           (append labels nil) 0)))
               (separator
                (concat (md-table-align--stretch pipe-x)
                        pipe
                        (md-table-align--stretch
                         (+ pipe-x gap
                            (funcall md-table-align-pixel-width-function pipe)))))
               (wrap
                (concat (propertize " " 'display `(space :width (,pipe-x)))
                        pipe
                        (propertize " " 'display `(space :width (,gap)))))
               (i 0))
          (dolist (row data)
            (setq i (1+ i))
            (md-table-align--layout-vertical-row row i ctx labels separator
                                                 wrap))))
      t)))

;;;; Discovery

(defun md-table-align--parser ()
  "Return this buffer's `markdown' tree-sitter parser, if any."
  (car (treesit-parser-list nil 'markdown)))

(defvar md-table-align--table-query nil
  "Compiled query matching `pipe_table' nodes.
Built on first use rather than at load time: a sexp query handed to
`treesit-query-capture' is recompiled on every call, which shows up in
scroll profiles, but compiling needs the markdown grammar, which may
not be loadable when this file is.")

(defun md-table-align--tables (beg end)
  "Return `pipe_table' nodes overlapping the region BEG to END."
  (when-let* ((parser (md-table-align--parser))
              (root (treesit-parser-root-node parser)))
    (unless md-table-align--table-query
      (setq md-table-align--table-query
            (treesit-query-compile 'markdown '((pipe_table) @table))))
    (mapcar #'cdr (treesit-query-capture root md-table-align--table-query beg end))))

(defun md-table-align--align-region (beg end)
  "Align every table overlapping the region BEG to END."
  (setq md-table-align--layout-key (md-table-align--layout-key))
  ;; Entries stranded by tables that moved or vanished accumulate; a blunt
  ;; cap here (not in `md-table-align--metrics', which runs per command)
  ;; bounds the memory, and a dropped cache simply refills.
  (when (and md-table-align--metrics-caches
             (> (hash-table-count md-table-align--metrics-caches) 256))
    (clrhash md-table-align--metrics-caches))
  (dolist (node (md-table-align--tables beg end))
    (md-table-align--clear-table node)
    (md-table-align--layout-table node)))

(defun md-table-align--jit (beg end)
  "Alignment entry point for `jit-lock', covering BEG to END."
  (md-table-align--align-region beg end))

(defun md-table-align--table-at (pos)
  "Return the `pipe_table' node containing POS, if any."
  (when (md-table-align--parser)
    (when-let* ((node (treesit-node-at pos 'markdown)))
      (treesit-parent-until
       node (lambda (n) (equal (treesit-node-type n) "pipe_table")) t))))

;;;; Horizontal scrolling

(defun md-table-align--offset-of (node)
  "Return the offset the table at NODE should be laid out with.
Only the table point is in carries one; every other table in the buffer
renders from its own left edge."
  (if (and md-table-align--hscroll-table
           (eql (marker-position md-table-align--hscroll-table)
                (treesit-node-start node)))
      md-table-align--hscroll
    0))

(defun md-table-align--row-at (ctx pos)
  "Return the row of CTX whose line contains POS, if any."
  (seq-find
   (lambda (row)
     (when-let* ((pipe (car (plist-get row :pipes))))
       (save-excursion
         (goto-char pipe)
         (and (<= (line-beginning-position) pos)
              (<= pos (line-end-position))))))
   (plist-get ctx :rows)))

(defun md-table-align--aligned-x (ctx pos)
  "Return the pixel column on CTX's grid at which POS renders, or nil.
Positions in the whitespace between two cells report the next thing that
renders, which is where the cursor appears once alignment has closed the
gap up."
  (when-let* ((row (md-table-align--row-at ctx pos)))
    (let ((steps (md-table-align--row-plan row ctx))
          (last nil))
      (or (catch 'found
            (dolist (step steps)
              (let ((beg (plist-get step :beg))
                    (end (plist-get step :end)))
                (when (< pos beg)
                  (throw 'found (plist-get step :x)))
                (when (< pos end)
                  (throw 'found
                         (if (eq (plist-get step :kind) 'content)
                             (+ (plist-get step :x)
                                (md-table-align--measure beg pos))
                           (plist-get step :x))))
                (setq last step)))
            nil)
          ;; Past the last thing on the row -- trailing whitespace, or the
          ;; end of a ragged row.
          (and last (+ (plist-get last :x) (plist-get last :width)))))))

(defun md-table-align--margin (view unit)
  "Return `hscroll-margin' in pixels, capped to fit inside VIEW.
A margin wider than the viewport would leave nowhere to stand.

Shared by the two halves of point-following, which have to agree on it:
`md-table-align--desired-offset' scrolls when point is within the margin
of an edge, and `md-table-align--point-into-view' has to place point
outside that band or the scroll it was called for is undone at once."
  (min (* (max 0 hscroll-margin) unit) (/ (plist-get view :head) 3)))

(defun md-table-align--desired-offset (x view unit)
  "Return the offset of VIEW adjusted to keep grid column X in sight.

This is `auto-hscroll-mode''s rule, in pixels: point may come within
`hscroll-margin' columns of an edge before the viewport moves, and it
then moves by `hscroll-step' -- centring X when that is zero, as Emacs
does.  A fixed step is not always enough to reach X, so it falls back to
centring rather than creeping one step per command."
  (let* ((offset (plist-get view :offset))
         ;; The head, not the whole budget: point has to end up somewhere the
         ;; cursor can be drawn, which is the text area.
         (budget (plist-get view :head))
         (maxoff (plist-get view :maxoff))
         (margin (md-table-align--margin view unit))
         ;; Whole characters while spilling; see `md-table-align--viewport'.
         (quantum (or (plist-get view :quantum) 1))
         (clamp (lambda (o) (max 0 (min maxoff (* quantum (round o quantum))))))
         (centre (lambda () (funcall clamp (- x (/ budget 2)))))
         (step (cond ((not (numberp hscroll-step)) nil)
                     ((floatp hscroll-step)
                      (and (> hscroll-step 0) (* hscroll-step budget)))
                     ((> hscroll-step 0) (* hscroll-step unit)))))
    (if (and (>= x (+ offset margin))
             (<= x (- (+ offset budget) margin)))
        offset
      (if (null step)
          (funcall centre)
        (let ((moved (funcall clamp (if (< x (+ offset margin))
                                        (- offset step)
                                      (+ offset step)))))
          (if (and (>= x (+ moved margin))
                   (<= x (- (+ moved budget) margin)))
              moved
            (funcall centre)))))))

(defun md-table-align--relayout (node)
  "Lay the table at NODE out again from scratch."
  (md-table-align--clear-table node)
  (md-table-align--layout-table node))

(defun md-table-align--set-offset (node offset)
  "Lay the table at NODE out again, scrolled to OFFSET."
  (setq md-table-align--hscroll offset)
  (if md-table-align--hscroll-table
      (set-marker md-table-align--hscroll-table (treesit-node-start node))
    (setq md-table-align--hscroll-table
          (copy-marker (treesit-node-start node))))
  (md-table-align--relayout node))

(defun md-table-align--reset-offset ()
  "Return the scrolled table, if there is one, to its left edge."
  (when md-table-align--hscroll-table
    (let ((pos (marker-position md-table-align--hscroll-table))
          (scrolled (/= md-table-align--hscroll 0)))
      (setq md-table-align--hscroll 0)
      (set-marker md-table-align--hscroll-table nil)
      (setq md-table-align--hscroll-table nil)
      (when-let* ((scrolled)
                  (pos)
                  (node (md-table-align--table-at pos)))
        (md-table-align--relayout node)))))

(defun md-table-align--shown-in-full-p (view)
  "Return non-nil when VIEW hides nothing: the whole table renders, at rest.

Under `md-table-align-spill' some of it may be rendering in the margin,
where Emacs cannot draw the cursor -- but a table that is already all
there should not move to fetch that part into the text area, which reads
as the table flinching away from the cursor.  The cost is that point in a
spilled cell renders at the split rather than under itself.

Only at rest: a non-zero offset means text really is hidden, off the left
edge if not the right, and point has to be kept out of it."
  (and (zerop (plist-get view :offset))
       (not (plist-get view :clipped))))

(defun md-table-align--scroll-into-view (node)
  "Scroll the table at NODE, if need be, so that point is inside it."
  (when-let* ((ctx (md-table-align--metrics node))
              (view (md-table-align--viewport
                     ctx (md-table-align--offset-of node)))
              ((not (md-table-align--shown-in-full-p view)))
              (x (md-table-align--aligned-x ctx (point))))
    (let ((want (md-table-align--desired-offset x view (plist-get ctx :unit))))
      (unless (eql want (plist-get view :offset))
        (md-table-align--set-offset node want)))))

(defun md-table-align--post-command ()
  "Per-command upkeep: re-fit a stale layout, then keep point in view.

Re-fitting runs first, because point-following consults the very metrics
a re-fit throws away.  It is also what notices a face remapping arriving
after the table was laid out -- `mixed-pitch-mode' switched on after this
mode, say.  `post-command-hook' is the natural place for that check: it
is already buffer-local to buffers with the mode on, and it coalesces by
construction, however many times `face-remapping-alist' was mutated
inside the command.

Errors are caught rather than allowed out.  Emacs responds to a signal in
`post-command-hook' by removing the offending function from the hook --
so a single failure anywhere in layout would silently uninstall all of
this for the rest of the session, in every buffer, with nothing but one
stale message to say so.  Degrading to \"the table stopped following
point\" is a far better failure than that, and reporting once per buffer
keeps a persistent problem from spamming the echo area on every
keystroke."
  (condition-case err
      (progn
        (md-table-align--refit)
        (md-table-align--follow-point))
    (error
     (unless md-table-align--follow-failed
       (setq md-table-align--follow-failed t)
       (message "md-table-align: table upkeep disabled in %s (%S)"
                (buffer-name) err)))))

(defun md-table-align--follow-point ()
  "Keep point inside the viewport of the table it is in.

This is `auto-hscroll-mode' for tables, and it is not a refinement: text
hidden by a `display' overlay collapses point onto that overlay's start,
so a viewport that ignored point would make cursor motion through
scrolled-off text meaningless.  Defining the viewport to contain point
means point is never inside hidden text at all.

Signals out on failure; `md-table-align--post-command' is the guarded
entry point that `post-command-hook' actually holds."
  (when (and md-table-align-mode md-table-align-hscroll)
    (let ((node (md-table-align--table-at (point))))
      ;; Moving away from a scrolled table -- to another table, or out of
      ;; tables entirely -- puts it back the way it was found.
      (unless (and node
                   md-table-align--hscroll-table
                   (eql (marker-position md-table-align--hscroll-table)
                        (treesit-node-start node)))
        (md-table-align--reset-offset))
      ;; A vertical table has no viewport for point to leave.
      (when (and node (not (md-table-align--vertical-p node)))
        (md-table-align--scroll-into-view node)))))

(defun md-table-align--point-into-view (ctx view)
  "Move point into VIEW when clipping under CTX has left it outside.
Deliberately mirrors the vertical case: `scroll-up' drags point along
rather than leaving it off screen, and an explicit horizontal scroll that
left point behind would simply be undone by `md-table-align--follow-point'.

Point is placed `hscroll-margin' *inside* the viewport's edge, not on it.
On the edge, `md-table-align--follow-point' sees point within the margin
on the very next command and scrolls straight back -- with the default
`hscroll-step' of 0 that means re-centring, which clamps to zero.  The
explicit scroll would undo itself and \\[scroll-left] would appear dead.

The margin is applied only at an edge the viewport can actually scroll
past: at offset zero there is nothing to the left to reveal, so pushing
point off the first column would be gratuitous."
  (when-let* ((row (md-table-align--row-at ctx (point)))
              (offset (plist-get view :offset))
              (margin (md-table-align--margin view (plist-get ctx :unit)))
              (lo (+ offset (if (> offset 0) margin 0)))
              (hi (- (+ offset (plist-get view :head))
                     (if (< offset (plist-get view :maxoff)) margin 0)))
              (visible (md-table-align--clip-steps
                        (md-table-align--row-plan row ctx) lo hi)))
    (let ((cut (plist-get (car visible) :beg))
          (cutr (plist-get (car (last visible)) :end)))
      (cond ((< (point) cut) (goto-char cut))
            ((> (point) cutr) (goto-char cutr))))))

(defun md-table-align--scroll (columns sign)
  "Scroll the table at point by COLUMNS in direction SIGN.
COLUMNS nil means a viewport-ful less the two columns of context
`scroll-left' keeps.  Returns non-nil when a table was scrolled.
A vertical table has nothing to scroll, so the key falls through to the
command it displaced, as it does outside a table."
  (when-let* ((node (md-table-align--table-at (point)))
              ((not (md-table-align--vertical-p node)))
              (ctx (md-table-align--metrics node))
              (view (md-table-align--viewport
                     ctx (md-table-align--offset-of node))))
    (let* ((unit (plist-get ctx :unit))
           (budget (plist-get view :budget))
           (delta (* sign (if columns
                              (* columns unit)
                            (max unit (- budget (* 2 unit))))))
           ;; Leftwards only while something is hidden past the right edge.
           ;; Under `md-table-align-spill' a table can render in full and
           ;; still be short of `:maxoff', which reaches far enough for point
           ;; to stand in the last column -- but point is not what is moving
           ;; here, and scrolling a table already shown in full could only
           ;; take a column away.  Rightwards needs no such guard: the clamp
           ;; to zero is already it.
           (want (if (and (> sign 0) (not (plist-get view :clipped)))
                     (plist-get view :offset)
                   (max 0 (min (plist-get view :maxoff)
                               (+ (plist-get view :offset) delta))))))
      (unless (eql want (plist-get view :offset))
        (md-table-align--set-offset node want)
        (md-table-align--point-into-view
         ctx (md-table-align--viewport ctx want)))
      t)))

;;;; Commands

;;;###autoload
(defun md-table-align-buffer ()
  "Align every Markdown table in the buffer.
Buffer text is not modified, so this works in read-only buffers."
  (interactive)
  (unless (md-table-align--parser)
    (user-error "No `markdown' tree-sitter parser in this buffer"))
  (md-table-align--align-region (point-min) (point-max)))

;;;###autoload
(defun md-table-align-clear ()
  "Remove all table alignment from the buffer."
  (interactive)
  (setq md-table-align--metrics-caches nil)
  (md-table-align--clear-region (point-min) (point-max)))

;;;###autoload
(defun md-table-align-hscroll-left (&optional arg)
  "Scroll the table at point ARG columns to the left.
With point outside a table, or with `md-table-align-hscroll' off, does
what \\[scroll-left] would have done, which is the binding this command
takes over."
  (interactive "P")
  (unless (and md-table-align-hscroll
               (md-table-align--scroll
                (and arg (prefix-numeric-value arg)) 1))
    (call-interactively #'scroll-left)))

;;;###autoload
(defun md-table-align-hscroll-right (&optional arg)
  "Scroll the table at point ARG columns to the right.
With point outside a table, or with `md-table-align-hscroll' off, does
what \\[scroll-right] would have done, which is the binding this command
takes over."
  (interactive "P")
  (unless (and md-table-align-hscroll
               (md-table-align--scroll
                (and arg (prefix-numeric-value arg)) -1))
    (call-interactively #'scroll-right)))

;;;###autoload
(defun md-table-align-toggle-vertical ()
  "Toggle the table at point between horizontal and vertical display.

Vertical is psql's `\\x' expanded display: each data row renders as a
block of `label | value' lines under a record separator, with the labels
taken from the header row.  Like everything else here it is a rendering,
not an edit -- buffer text is untouched, so it works in read-only
buffers, and toggling back is just a re-render.

Enables `md-table-align-mode' when it is not already on: toggling a
table implies wanting the machinery that maintains it."
  (interactive)
  (unless (md-table-align--parser)
    (user-error "No `markdown' tree-sitter parser in this buffer"))
  (let ((node (md-table-align--table-at (point))))
    (unless node
      (user-error "No table at point"))
    (unless md-table-align-mode
      (md-table-align-mode 1))
    (let* ((beg (treesit-node-start node))
           (existing (seq-find (lambda (m) (eql (marker-position m) beg))
                               md-table-align--vertical-tables)))
      (if existing
          (progn
            (set-marker existing nil)
            (setq md-table-align--vertical-tables
                  (delq existing md-table-align--vertical-tables)))
        ;; A viewport offset is meaningless on a vertical table, and holding
        ;; it silently would bring the table back scrolled -- the missing
        ;; first columns the offset-reset rule exists to prevent.
        (when (and md-table-align--hscroll-table
                   (eql (marker-position md-table-align--hscroll-table) beg))
          (setq md-table-align--hscroll 0)
          (set-marker md-table-align--hscroll-table nil)
          (setq md-table-align--hscroll-table nil))
        (push (copy-marker beg) md-table-align--vertical-tables))
      (md-table-align--relayout node))))

;;;###autoload
(defun md-table-align-hscroll-reset ()
  "Return the scrolled table to its left edge."
  (interactive)
  (md-table-align--reset-offset))

;;;; Modes

(defvar-keymap md-table-align-mode-map
  :doc "Keymap for `md-table-align-mode'.

Only the horizontal scrolling commands are bound, and only over the
bindings of the commands they stand in for.  `scroll-left' and
`scroll-right' do nothing useful in a buffer whose lines wrap, so there
is no behaviour being displaced."
  "<remap> <scroll-left>" #'md-table-align-hscroll-left
  "<remap> <scroll-right>" #'md-table-align-hscroll-right)

;;;###autoload
(define-minor-mode md-table-align-mode
  "Render Markdown tables aligned, without modifying buffer text.

Alignment is done with display overlays, so it works in read-only
buffers and never marks the buffer as modified.

Requires a `markdown' tree-sitter parser in the buffer; see
`markdown-ts-mode'."
  :lighter " Tbl"
  (if md-table-align-mode
      (if (not (md-table-align--parser))
          (progn
            (setq md-table-align-mode nil)
            (message "md-table-align: no `markdown' tree-sitter parser available"))
        (setq md-table-align--follow-failed nil)
        (jit-lock-register #'md-table-align--jit t)
        ;; `jit-lock-register' prepends, which would run alignment *before*
        ;; `font-lock-fontify-region' whenever the two share a pass -- and a
        ;; cell would be measured with the faces and invisibility properties
        ;; that same pass is about to replace.  Re-adding at a late depth
        ;; keeps registration's other effects and only moves the hook entry.
        (remove-hook 'jit-lock-functions #'md-table-align--jit t)
        (add-hook 'jit-lock-functions #'md-table-align--jit 90 t)
        ;; Window geometry is not something `jit-lock' watches, so clipping
        ;; needs its own triggers.  `window-state-change-functions' also fires
        ;; on a change of selected window, which is what re-lays a table when
        ;; you move to a differently sized window.
        (add-hook 'window-configuration-change-hook #'md-table-align--refit nil t)
        (add-hook 'window-state-change-functions #'md-table-align--refit nil t)
        ;; The viewport has to follow point, or cursor motion into
        ;; scrolled-off text would land where nothing is rendered.
        (add-hook 'post-command-hook #'md-table-align--post-command nil t)
        ;; Text already fontified before we registered would otherwise never
        ;; reach our jit-lock handler; re-marking it keeps the work lazy --
        ;; only what is (or becomes) visible is laid out, and after
        ;; font-lock, so cells are never measured with the faces a pending
        ;; fontification is about to replace.  `md-table-align-buffer'
        ;; stays eager for interactive use.
        (jit-lock-refontify))
    (jit-lock-unregister #'md-table-align--jit)
    (remove-hook 'window-configuration-change-hook #'md-table-align--refit t)
    (remove-hook 'window-state-change-functions #'md-table-align--refit t)
    (remove-hook 'post-command-hook #'md-table-align--post-command t)
    (setq md-table-align--layout-key nil
          md-table-align--follow-failed nil
          md-table-align--hscroll 0)
    (when md-table-align--hscroll-table
      (set-marker md-table-align--hscroll-table nil)
      (setq md-table-align--hscroll-table nil))
    (dolist (marker md-table-align--vertical-tables)
      (set-marker marker nil))
    (setq md-table-align--vertical-tables nil)
    (md-table-align-clear)))

(defun md-table-align--layout-key ()
  "Return what a layout depends on besides the buffer text.
Nil when no window shows the buffer, since there is nothing to lay out
against.

Window width participates only when `md-table-align-hscroll' is on: with
clipping off, width does not enter the grid and a resize should not cost
a re-render.  `face-remapping-alist' always participates -- `mixed-pitch-mode'
and friends change what every glyph measures, and the pixel targets already
written into `:align-to' are frozen at layout time.
`buffer-invisibility-spec' participates for the same reason:
`markdown-ts-toggle-hide-markup' works by toggling a member of it, and
with `md-table-inline-mode' giving cells real markup, that toggle
changes what every marked-up cell measures.

The right margin joins the width, and for the same reason: under
`md-table-align-spill' it is part of what a table is laid out against,
and `visual-fill-column-mode' grows the margin rather than the text area
when a window is widened -- a geometry change the text width alone does
not report.  Both sit in the first element, so a re-fit for geometry
alone still keeps the metrics caches."
  (when-let* ((width (md-table-align--available-width)))
    (list (and md-table-align-hscroll
               (list width (and md-table-align-spill
                                (md-table-align--margin-pixels))))
          face-remapping-alist
          buffer-invisibility-spec)))

(defun md-table-align--refit (&rest _)
  "Re-align when something a table was laid out against has changed.
`jit-lock' covers edits but neither geometry nor faces: resizing a window
and remapping a face both leave fontification valid.  Clearing and asking
`jit-lock' to refontify keeps the work lazy -- only tables that come back
on screen are laid out again.  Any scroll offset survives, clamped to the
new width by `md-table-align--viewport'."
  (when md-table-align-mode
    (let ((key (md-table-align--layout-key)))
      ;; The callers fire on every window operation and every command; the
      ;; key guard is what stops that turning into a re-layout of every
      ;; visible table.
      (unless (or (null key) (equal key md-table-align--layout-key))
        ;; A pure width change moves the viewport but changes nothing any
        ;; cell measures, so the metrics survive it -- this is what makes
        ;; resizing cheap.  The key's other components (face remapping,
        ;; invisibility spec) change rendered widths that no text property
        ;; records, which the content-keyed cache cannot see, so those drop
        ;; the caches wholesale.
        (unless (equal (cdr key) (cdr md-table-align--layout-key))
          (setq md-table-align--metrics-caches nil))
        (setq md-table-align--layout-key key)
        (md-table-align--clear-region (point-min) (point-max))
        (jit-lock-refontify)))))

(defun md-table-align--maybe-enable ()
  "Enable `md-table-align-mode' if this buffer's mode calls for it."
  (when (and (apply #'derived-mode-p md-table-align-modes)
             (md-table-align--parser))
    (md-table-align-mode 1)))

;;;###autoload
(define-globalized-minor-mode global-md-table-align-mode
  md-table-align-mode md-table-align--maybe-enable)

(defun md-table-align-unload-function ()
  "Switch the mode off everywhere before `unload-feature' removes it.
Without this, unloading would strip the definitions while overlays and
`jit-lock' registrations from this package were still installed.
Returning nil leaves the standard unloading to `unload-feature'."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (bound-and-true-p md-table-align-mode)
        (md-table-align-mode -1))))
  nil)

(provide 'md-table-align)

;;; md-table-align.el ends here
