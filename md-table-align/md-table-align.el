;;; md-table-align.el --- Display-only alignment of Markdown tables -*- lexical-binding: t; -*-

;; Author: Steinthor Palsson
;; Version: 0.1.0
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

(defun md-table-align--measure (beg end)
  "Return the rendered pixel width of the buffer text between BEG and END."
  (if (>= beg end)
      0
    ;; Deliberately keeps text properties: faces are what make this differ
    ;; from a character count.
    (funcall md-table-align-pixel-width-function (buffer-substring beg end))))

(defun md-table-align--space-width (node)
  "Return the pixel width of one space as rendered inside table NODE.
Padding is specified in spaces, so it has to be converted using the font
the table actually renders in, not the frame's canonical character."
  (let* ((start (treesit-node-start node))
         (face (get-text-property start 'face))
         (space (if face (propertize " " 'face face) " ")))
    (max 1 (funcall md-table-align-pixel-width-function space))))

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

(defun md-table-align--content-offset (align width cell-width)
  "Return leading padding for CELL-WIDTH text in a WIDTH column under ALIGN."
  (pcase align
    ('right (max 0 (- width cell-width)))
    ('center (/ (max 0 (- width cell-width)) 2))
    (_ 0)))

(defun md-table-align--layout-row (row widths aligns indent unit)
  "Place overlays aligning ROW to WIDTHS and ALIGNS, starting at pixel INDENT.
UNIT is the pixel width of one space, which converts
`md-table-align-padding' from spaces into pixels."
  (let ((pipes (plist-get row :pipes))
        (cells (plist-get row :cells))
        (delimiter (plist-get row :delimiter))
        (pad (* md-table-align-padding unit))
        (x indent)
        (i 0))
    (dolist (cell cells)
      (let ((width (aref widths i))
            (open (nth i pipes))
            (close (nth (1+ i) pipes)))
        ;; Without an opening pipe there is no border to align against.
        (when open
          ;; A column may have no cell node at all, and an empty cell's
          ;; trimmed bounds collapse onto the closing border.
          (let* ((beg (if cell (plist-get cell :beg) (1+ open)))
                 (end (if cell (plist-get cell :end) (1+ open)))
                 (cell-width (if cell (plist-get cell :width) 0))
                 (empty (<= end beg))
                 (inner (+ pad width pad)))
            ;; Step past the opening pipe.  Its width is measured rather than
            ;; assumed, for the same reason cell widths are.
            (setq x (+ x (md-table-align--measure open (1+ open))))
            (cond
             (delimiter
              ;; Re-render the dashes across the full inner width, matching
              ;; the `|:------|----:|' style `markdown-table-align' produces.
              (md-table-align--replace
               (1+ open) (or close (1+ end))
               (md-table-align--delimiter-string
                inner unit (and cell (plist-get cell :colons)))))
             ;; Nothing to position when the cell is empty; the closing
             ;; border below takes care of the whole gap.
             ((not empty)
              (md-table-align--pad
               (1+ open) beg
               (+ x pad (md-table-align--content-offset
                         (aref aligns i) width cell-width)))))
            (setq x (+ x inner))
            ;; Push the closing pipe onto the grid.
            (when close
              (md-table-align--pad
               (cond
                ;; The delimiter's dashes already occupy the whole span and
                ;; are character-quantised, so pin the border from where it
                ;; sits and let the stretch absorb the rounding shortfall.
                (delimiter close)
                ;; For an empty cell the entire span between the borders is
                ;; padding; stretching it avoids a degenerate zero-length
                ;; overlay.
                (empty (1+ open))
                (t end))
               close x))))
        (setq i (1+ i))))))

(defun md-table-align--layout-table (node)
  "Align the table at NODE by placing overlays."
  (let ((rows (md-table-align--parse-table node)))
    (when (cdr rows)
      (let* ((unit (md-table-align--space-width node))
             (widths (md-table-align--column-widths rows unit))
             (aligns (md-table-align--alignments rows (length widths)))
             (indent (md-table-align--indent-pixels rows)))
        (dolist (row rows)
          (md-table-align--layout-row row widths aligns indent unit))))))

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
  (dolist (node (md-table-align--tables beg end))
    (let ((tbeg (treesit-node-start node))
          (tend (treesit-node-end node)))
      (md-table-align--clear-region tbeg tend)
      (md-table-align--layout-table node))))

(defun md-table-align--jit (beg end)
  "Alignment entry point for `jit-lock', covering BEG to END."
  (md-table-align--align-region beg end))

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
  (md-table-align--clear-region (point-min) (point-max)))

;;;; Modes

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
        (jit-lock-register #'md-table-align--jit t)
        ;; Text already fontified before we registered would otherwise never
        ;; reach our jit-lock handler.
        (md-table-align-buffer))
    (jit-lock-unregister #'md-table-align--jit)
    (md-table-align-clear)))

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
