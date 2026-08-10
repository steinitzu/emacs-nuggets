;;; md-table-align.el --- Display-only alignment of Markdown tables -*- lexical-binding: t; -*-

;; Author: Steinthor Palsson
;; Version: 0.4.0
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
;; `\x'-style expanded display -- one `label: value' line per cell, one record
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

(defcustom md-table-align-vertical-gap 2
  "Spaces between the widest label and the values of a vertical table.

Every value in a record block starts at the same column, so this gap is
what separates the *longest* label from its value; the shorter labels
get correspondingly more.  One space is the psql tradition, but next to
a bold label ending in a colon it reads as no separation at all, which
is why the default is two."
  :type 'natnum)

(defface md-table-align-vertical-label
  '((t :inherit bold))
  "Face for the column labels of a table rendered vertically.")

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

(defvar-local md-table-align--metrics-cache nil
  "Cons of (KEY . CONTEXT) memoising the most recent table measurement.")

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
LIMIT is in pixels.  Measured a character at a time rather than counted:
in a proportional font there is no fixed relationship between characters
and pixels, so the boundary has to be found by measuring up to it."
  (let ((keep beg))
    (while (and (< keep end)
                (<= (md-table-align--measure beg (1+ keep)) limit))
      (setq keep (1+ keep)))
    keep))

(defun md-table-align--hide (beg end indicate)
  "Render the buffer text between BEG and END as nothing.
With INDICATE, it renders as `md-table-align-ellipsis' instead, so the
edge reads as clipped rather than as the end of the row.

This is what keeps a clipped row on one screen line: text left outside
the viewport would still be laid out, and would still wrap."
  (when (> end beg)
    (let ((ov (make-overlay beg end)))
      (overlay-put ov 'md-table-align t)
      ;; Tagged apart from the alignment overlays: this is the one kind that
      ;; takes text away rather than moving it.
      (overlay-put ov 'md-table-align-clip t)
      (overlay-put ov 'evaporate t)
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
`:lead' and `:trail' for the clipped-edge indicators, and `:maxoff'.

Nil when nothing should be clipped: no window to measure against, or
scrolling turned off.  The indicators are folded into the budget rather
than drawn over the table, so that a column is never half-hidden behind
one."
  (when-let* (((and md-table-align-hscroll (> (length (plist-get ctx :widths)) 0)))
              (avail (md-table-align--available-width)))
    (let* ((unit (plist-get ctx :unit))
           (ell (if md-table-align-hscroll-indicator (plist-get ctx :ellipsis) 0))
           (width (plist-get ctx :table-width))
           ;; Reserve one character cell: a wrapped line spends one on the
           ;; continuation glyph, and it absorbs rounding at the window edge.
           (available (- avail unit))
           ;; At the rightmost offset a lead indicator is showing, so that is
           ;; the budget the limit has to be computed against.  Choosing it
           ;; this way makes the clamp a fixed point: laying out at `maxoff'
           ;; reproduces exactly this budget, and the table's right edge lands
           ;; exactly on the viewport's.
           (maxoff (if (<= width available) 0 (max 0 (- width (- available ell)))))
           (o (max 0 (min offset maxoff)))
           (lead (if (> o 0) ell 0))
           (trail (if (> (- width o) (- available lead)) ell 0))
           (budget (- available lead trail)))
      ;; A window with no room for even a couple of characters of table would
      ;; clip it to nothing.  Leaving it to wrap is the better failure: it is
      ;; what happened before any of this existed, and it hides nothing.
      (when (>= budget (* 2 unit))
        (list :offset o
              :lead lead
              :trail trail
              :budget budget
              :maxoff maxoff)))))

(defun md-table-align--content-offset (align width cell-width)
  "Return leading padding for CELL-WIDTH text in a WIDTH column under ALIGN."
  (pcase align
    ('right (max 0 (- width cell-width)))
    ('center (/ (max 0 (- width cell-width)) 2))
    (_ 0)))

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
                 ;; Measured rather than assumed, for the same reason cell
                 ;; widths are.
                 (pw (md-table-align--measure open (1+ open))))
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
                                       (aref aligns i) width cell-width))
                          :width cell-width)
                    steps)))
            (setq x (+ x inner))))
        (setq i (1+ i))))
    ;; The pipe closing the last column belongs to no cell of its own.
    (when-let* ((last (nth (length cells) pipes)))
      (push (list :kind 'pipe :beg last :end (1+ last) :x x
                  :width (md-table-align--measure last (1+ last)))
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
         (lead (if view (plist-get view :lead) 0))
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
            (shift (- lead offset))
            (prev nil))
        (when view
          ;; Everything outside the viewport is one contiguous buffer prefix
          ;; and one contiguous suffix -- different ones on every row, since
          ;; the grid position of a buffer position depends on the row's own
          ;; cell contents.
          (md-table-align--hide bol cut (> lead 0))
          (md-table-align--hide cutr eol (> (plist-get view :trail) 0)))
        ;; With the clipped text rendering at zero width, what is left lays
        ;; out compactly, so every step sits left of its target and each
        ;; stretch glyph still only ever pushes forward -- which is the
        ;; invariant alignment has relied on since v1.
        (dolist (step visible)
          (md-table-align--place step (or prev cut) shift
                                 (plist-get ctx :unit) (null prev))
          (setq prev (plist-get step :end)))))))

(defun md-table-align--measure-table (node)
  "Return the layout context for the table at NODE, or nil if it has no rows.
Widths are measured before any overlay exists -- the region is swept
clear first, and `buffer-substring' carries text properties but not
overlays -- so a clipped table is never measured against its own
clipping."
  (let ((rows (md-table-align--parse-table node)))
    (when (cdr rows)
      (let* ((unit (md-table-align--glyph-width node " "))
             (widths (md-table-align--column-widths rows unit))
             (ctx (list :rows rows
                        :widths widths
                        :aligns (md-table-align--alignments rows (length widths))
                        :indent (md-table-align--indent-pixels rows)
                        :unit unit
                        :pipe (md-table-align--glyph-width node "|")
                        :ellipsis (md-table-align--glyph-width
                                   node md-table-align-ellipsis))))
        (plist-put ctx :table-width (md-table-align--table-width ctx))))))

(defun md-table-align--metrics (node)
  "Return the layout context for the table at NODE, measuring it if needed.

Memoised against the buffer's modification tick.  Point motion inside a
table consults the grid on every command, and re-measuring every cell
that often would make simply moving the cursor crawl.

`buffer-modified-tick', not `buffer-chars-modified-tick': text
properties change what a cell measures -- a face swaps its font, an
`invisible' from markup hiding takes the delimiters out of the width --
and property-only changes advance only the former.  Font-lock's writes
land under `with-silent-modifications', but that spares the modified
*flag*, not the tick, so a fontification pass still invalidates this
cache the way it should."
  (let ((key (list (buffer-modified-tick)
                   (treesit-node-start node)
                   (treesit-node-end node)
                   md-table-align-padding)))
    (if (equal (car md-table-align--metrics-cache) key)
        (cdr md-table-align--metrics-cache)
      (let ((ctx (md-table-align--measure-table node)))
        (setq md-table-align--metrics-cache (cons key ctx))
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
          (md-table-align--layout-row row ctx))))))

;;;; Vertical records view
;;
;; A table toggled vertical renders as psql's `\x' expanded display: each data
;; row becomes a block of `label: value' lines under a record separator.  The
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
Labels are the header cells' text under `md-table-align-vertical-label',
suffixed with a colon.  A column the header does not name -- ragged
tables -- falls back to its 1-based number."
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
        (aset labels j (propertize (concat text ":")
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

(defun md-table-align--layout-vertical-row (row index ctx labels value-x)
  "Place overlays rendering ROW as vertical record number INDEX.
CTX is the table's layout context, LABELS the vector from
`md-table-align--vertical-labels' and VALUE-X the pixel column values
start at.

Each span from one cell's content end to the next cell's content start
-- never empty, since it holds at least the pipe -- is replaced by a
newline, a stretch to the table's indent, the label, and a stretch to
VALUE-X.  The values between those spans are left alone."
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
                   (md-table-align--stretch value-x)))
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
        (let ((value-x (+ indent (* md-table-align-vertical-gap unit)
                          (seq-reduce
                           (lambda (acc label)
                             (max acc (funcall md-table-align-pixel-width-function
                                               label)))
                           (append labels nil) 0)))
              (i 0))
          (dolist (row data)
            (setq i (1+ i))
            (md-table-align--layout-vertical-row row i ctx labels value-x))))
      t)))

;;;; Discovery

(defun md-table-align--parser ()
  "Return this buffer's `markdown' tree-sitter parser, if any."
  (car (treesit-parser-list nil 'markdown)))

(defun md-table-align--tables (beg end)
  "Return `pipe_table' nodes overlapping the region BEG to END."
  (when-let* ((parser (md-table-align--parser))
              (root (treesit-parser-root-node parser)))
    (mapcar #'cdr (treesit-query-capture root '((pipe_table) @table) beg end))))

(defun md-table-align--align-region (beg end)
  "Align every table overlapping the region BEG to END."
  (setq md-table-align--layout-key (md-table-align--layout-key))
  (dolist (node (md-table-align--tables beg end))
    (let ((tbeg (treesit-node-start node))
          (tend (treesit-node-end node)))
      (md-table-align--clear-region tbeg tend)
      (md-table-align--layout-table node))))

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
  (min (* (max 0 hscroll-margin) unit) (/ (plist-get view :budget) 3)))

(defun md-table-align--desired-offset (x view unit)
  "Return the offset of VIEW adjusted to keep grid column X in sight.

This is `auto-hscroll-mode''s rule, in pixels: point may come within
`hscroll-margin' columns of an edge before the viewport moves, and it
then moves by `hscroll-step' -- centring X when that is zero, as Emacs
does.  A fixed step is not always enough to reach X, so it falls back to
centring rather than creeping one step per command."
  (let* ((offset (plist-get view :offset))
         (budget (plist-get view :budget))
         (maxoff (plist-get view :maxoff))
         (margin (md-table-align--margin view unit))
         (clamp (lambda (o) (max 0 (min maxoff (round o)))))
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
  (let ((beg (treesit-node-start node))
        (end (treesit-node-end node)))
    (md-table-align--clear-region beg end)
    (md-table-align--layout-table node)))

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

(defun md-table-align--scroll-into-view (node)
  "Scroll the table at NODE, if need be, so that point is inside it."
  (when-let* ((ctx (md-table-align--metrics node))
              (view (md-table-align--viewport
                     ctx (md-table-align--offset-of node)))
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
              (hi (- (+ offset (plist-get view :budget))
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
           (want (max 0 (min (plist-get view :maxoff)
                             (+ (plist-get view :offset) delta)))))
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
  (setq md-table-align--metrics-cache nil)
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
block of `label: value' lines under a record separator, with the labels
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
        ;; reach our jit-lock handler.
        (md-table-align-buffer))
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
changes what every marked-up cell measures."
  (when-let* ((width (md-table-align--available-width)))
    (list (and md-table-align-hscroll width)
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
        (setq md-table-align--layout-key key)
        (md-table-align-clear)
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
