;;; md-table-wrap.el --- Wrap wide Markdown table cells to fit the window -*- lexical-binding: t; -*-

;; Author: Steinthor Palsson
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: markdown, faces, convenience

;;; Commentary:

;; Draw every Markdown pipe table with its cells word-wrapped inside their
;; columns, so a table wider than the window fits its text area and reads
;; like a table hand-aligned into multi-line cells.  Rows of a wrapped table
;; are separated by rules, and borders are drawn with box-drawing
;; characters.  Buffer text is never modified, so this works in read-only
;; buffers too.
;;
;; Mechanism ("per-line anchors"): each screen line of a row is the
;; before-string of its own hidden span of the row's text.  The line holding
;; point is anchored at point, and a `cursor' property puts the real cursor
;; on the copy of the character at point.  C-n/C-p/C-a/C-e and mouse-1 are
;; mapped through the layout model.  Region, isearch, hl-line and other
;; overlay faces are mirrored onto the copies.  See DESIGN.md.
;;
;; Usage:
;;
;;   (add-hook 'markdown-ts-mode-hook #'md-table-wrap-mode)
;;
;; or globally:
;;
;;   (global-md-table-wrap-mode 1)
;;
;; The mode switches `md-table-align-mode' off in its buffer while it is on.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'jit-lock)
(require 'treesit nil t)

(defgroup md-table-wrap nil
  "Wrap wide Markdown table cells to fit the window."
  :group 'markdown
  :prefix "md-table-wrap-")

(defcustom md-table-wrap-modes '(markdown-ts-mode)
  "Major modes in which `global-md-table-wrap-mode' enables the mode."
  :type '(repeat symbol))

(defcustom md-table-wrap-style 'box
  "How table borders are drawn.
`box' uses box-drawing characters; `ascii' the Markdown `|' and `-'.
Takes effect at the next \\[md-table-wrap-refresh]."
  :type '(choice (const :tag "Box-drawing characters" box)
                 (const :tag "Markdown pipes and dashes" ascii)))

(defcustom md-table-wrap-row-rules t
  "Non-nil draws a rule below each row of a table that wraps.
Without one, a column of long sentences reads as a single run-on
paragraph.  A table whose rows each fit on one line gets none."
  :type 'boolean)

(defcustom md-table-wrap-word-cap 20
  "Longest word, in characters, that may set a column's minimum width."
  :type 'natnum)

(defcustom md-table-wrap-short-column 16
  "A column whose widest cell is at most this many characters is a label.
Label columns are kept unwrapped where that is cheap."
  :type 'natnum)

(defcustom md-table-wrap-protect-tolerance 0.05
  "Keeping a label column unwrapped may cost this fraction of table height."
  :type 'number)

(defcustom md-table-wrap-sticky-slack 0.1
  "While editing, keep column widths whose height is within this fraction."
  :type 'number)

(defcustom md-table-wrap-idle-delay 0.5
  "Seconds of idle time before widths are reallocated after an edit."
  :type 'number)

(defcustom md-table-wrap-mirror-faces t
  "Non-nil mirrors overlay faces (region, isearch...) onto copied text."
  :type 'boolean)

(defface md-table-wrap-border '((t :inherit shadow))
  "Face of table borders, merged over the table's own face."
  :group 'md-table-wrap)

(defconst md-table-wrap--soft-break-chars '(?/ ?. ?- ?_ ?? ?& ?= ?# ?, ?\; ?:)
  "A word longer than its column may break after any of these.")

;;; Cells and line breaking

(cl-defstruct (md-table-wrap--cell (:constructor md-table-wrap--cell-make))
  text words natural minw (memo (make-hash-table)))

(defun md-table-wrap--cjk-p (c)
  (memq (aref char-script-table c) '(han kana hangul cjk-misc)))

(defun md-table-wrap--break-before-p (text k)
  "Non-nil if a word in TEXT may break between chars K-1 and K."
  (let ((c (aref text (1- k))) (nx (aref text k)))
    (and (not (aref (char-category-set nx) ?>))
         (or (eq c ?\s) (md-table-wrap--cjk-p c) (md-table-wrap--cjk-p nx)
             (and (memq c md-table-wrap--soft-break-chars)
                  (not (memq nx md-table-wrap--soft-break-chars)))))))

(defun md-table-wrap--word (text s e)
  "[S E WIDTH PIECES CJK] for the word TEXT[S,E).
PIECES, the word's break points, are computed on first use by
`md-table-wrap--pieces': most words never need them."
  (vector s e (string-width text s e) nil
          (cl-loop for k from s below e
                   thereis (let ((c (aref text k)))
                             (and (> c 127) (md-table-wrap--cjk-p c))))))

(defun md-table-wrap--pieces (text word)
  "The (S E WIDTH) runs of WORD in TEXT between which it may break."
  (or (aref word 3)
      (aset word 3
            (let* ((s (aref word 0)) (e (aref word 1)) (pieces nil) (ps s))
              (cl-loop for k from (1+ s) below e
                       when (md-table-wrap--break-before-p text k)
                       do (push (list ps k (string-width text ps k)) pieces)
                       (setq ps k))
              (push (list ps e (string-width text ps e)) pieces)
              (nreverse pieces)))))

(defun md-table-wrap--words (text)
  "Words of TEXT; spaces inside a code span do not split one."
  (let ((i 0) (n (length text)) words)
    (while (< i n)
      (if (eq (aref text i) ?\s)
          (cl-incf i)
        (let ((s i) (code nil))
          (while (and (< i n) (or code (not (eq (aref text i) ?\s))))
            (when (eq (aref text i) ?`) (setq code (not code)))
            (cl-incf i))
          (push (md-table-wrap--word text s i) words))))
    (nreverse words)))

(defun md-table-wrap--make-cell (text)
  (let ((words (md-table-wrap--words text)) (natural 0) (minw 1))
    (dolist (w words)
      (setq natural (+ natural (aref w 2) (if (> natural 0) 1 0)))
      (setq minw (max minw (if (aref w 4)
                               (cl-loop for p in (md-table-wrap--pieces text w)
                                        maximize (nth 2 p))
                             (min md-table-wrap-word-cap (aref w 2))))))
    (md-table-wrap--cell-make :text text :words words
                              :natural (max 1 natural) :minw minw)))

(defun md-table-wrap--wrap-1 (cell w)
  (let ((text (md-table-wrap--cell-text cell)) lines ls le (used 0))
    (cl-flet* ((flush ()
                 (when ls (push (cons ls le) lines))
                 (setq ls nil le nil used 0))
               (put (s e wd gap)
                 (if ls
                     (setq le e used (+ used gap wd))
                   (setq ls s le e used wd))))
      (dolist (word (md-table-wrap--cell-words cell))
        (let ((ww (aref word 2)))
          (cond
           ((and ls (<= (+ used 1 ww) w)) (put (aref word 0) (aref word 1) ww 1))
           ((and (<= ww w) (not (aref word 4)))
            (flush) (put (aref word 0) (aref word 1) ww 0))
           (t
            ;; Too wide for a line, or CJK: flow its pieces.
            (let ((first t))
              (dolist (p (md-table-wrap--pieces text word))
                (let ((gap (if (and first ls) 1 0)))
                  (cond
                   ((and ls (<= (+ used gap (nth 2 p)) w))
                    (put (nth 0 p) (nth 1 p) (nth 2 p) gap))
                   ((<= (nth 2 p) w)
                    (flush) (put (nth 0 p) (nth 1 p) (nth 2 p) 0))
                   (t
                    (flush)
                    (cl-loop for k from (nth 0 p) below (nth 1 p)
                             for cw = (char-width (aref text k))
                             do (when (and ls (> (+ used cw) w)) (flush))
                             (put k (1+ k) cw 0)))))
                (setq first nil)))))))
      (flush))
    (or (nreverse lines) (list (cons 0 0)))))

(defun md-table-wrap--wrap (cell w)
  "Line spans (B . E), offsets into CELL's text, of CELL wrapped at W."
  (let ((memo (md-table-wrap--cell-memo cell)))
    (or (gethash w memo)
        (puthash w (md-table-wrap--wrap-1 cell (max 1 w)) memo))))

;;; Column widths: greedy widening from minimum widths

(defun md-table-wrap--sum (v) (cl-loop for x across v sum x))

(defun md-table-wrap--lines (cell w) (length (md-table-wrap--wrap cell w)))

(defun md-table-wrap--height (body n widths)
  (cl-loop for r in body
           sum (cl-loop for c below n
                        maximize (md-table-wrap--lines (aref r c) (aref widths c)))))

(defun md-table-wrap--fill-deficit (maxs w left)
  "Hand LEFT spare units to the columns furthest below their max."
  (while (> left 0)
    (let ((best nil) (bd 0))
      (dotimes (c (length w))
        (let ((d (- (aref maxs c) (aref w c))))
          (when (> d bd) (setq best c bd d))))
      (if (not best)
          (setq left 0)
        (cl-incf (aref w best))
        (cl-decf left))))
  w)

(defun md-table-wrap--greedy (body n mins maxs b)
  "Widen from MINS: each step widens the column whose next height drop
saves the most lines per unit of width.  Leftover goes to deficits."
  (let* ((rows (apply #'vector body)) (nr (length rows))
         (w (copy-sequence mins)) (left (- b (md-table-wrap--sum w)))
         (lines (make-vector nr nil)) (excl (make-vector nr 0)))
    (dotimes (r nr)
      (aset lines r (apply #'vector
                           (cl-loop for c below n
                                    collect (md-table-wrap--lines (aref (aref rows r) c)
                                                                  (aref w c))))))
    (catch 'done
      (while (> left 0)
        (let ((best nil) (best-ratio 0) (best-d 0))
          (dotimes (c n)
            (when (< (aref w c) (aref maxs c))
              (dotimes (r nr)
                (let ((m 0))
                  (dotimes (k n)
                    (unless (= k c) (setq m (max m (aref (aref lines r) k)))))
                  (aset excl r m)))
              (let ((d 1) (lim (min left (- (aref maxs c) (aref w c)))) (stop nil))
                (while (and (<= d lim) (not stop))
                  (let ((gain 0) (wc (+ (aref w c) d)))
                    (dotimes (r nr)
                      (setq gain (+ gain
                                    (- (max (aref excl r) (aref (aref lines r) c))
                                       (max (aref excl r)
                                            (md-table-wrap--lines (aref (aref rows r) c)
                                                                  wc))))))
                    (when (> gain 0)
                      (let ((ratio (/ (float gain) d)))
                        (when (> ratio best-ratio)
                          (setq best c best-ratio ratio best-d d)))
                      (setq stop t)))
                  (cl-incf d)))))
          (if (not best)
              (throw 'done nil)
            (cl-incf (aref w best) best-d)
            (cl-decf left best-d)
            (dotimes (r nr)
              (aset (aref lines r) best
                    (md-table-wrap--lines (aref (aref rows r) best) (aref w best))))))))
    (md-table-wrap--fill-deficit maxs w left)))

(defun md-table-wrap--squeeze (mins b)
  "MINS with the widest capped at one value, so the sum is at most B."
  (let ((lo 1) (hi (cl-loop for x across mins maximize x)))
    (while (< lo hi)
      (let ((mid (/ (+ lo hi 1) 2)))
        (if (<= (cl-loop for x across mins sum (min x mid)) b)
            (setq lo mid)
          (setq hi (1- mid)))))
    (let* ((w (cl-map 'vector (lambda (x) (min x lo)) mins))
           (left (- b (md-table-wrap--sum w))))
      (dotimes (c (length w))
        (when (and (> left 0) (< (aref w c) (aref mins c)))
          (cl-incf (aref w c))
          (cl-decf left)))
      w)))

(defun md-table-wrap--alloc (body n mins maxs b)
  "Greedy, protecting label columns from wrapping where that is cheap."
  (let* ((base (md-table-wrap--greedy body n mins maxs b))
         (h0 (md-table-wrap--height body n base))
         (allow (+ h0 (max 1 (floor (* md-table-wrap-protect-tolerance h0)))))
         (best base) (pm (copy-sequence mins))
         (short (sort (cl-loop for c below n
                               when (and (<= (aref maxs c) md-table-wrap-short-column)
                                         (< (aref mins c) (aref maxs c)))
                               collect c)
                      (lambda (a c) (< (aref maxs a) (aref maxs c))))))
    (dolist (c short)
      (let ((old (aref pm c)))
        (aset pm c (aref maxs c))
        (if (> (md-table-wrap--sum pm) b)
            (aset pm c old)
          (let ((w (md-table-wrap--greedy body n pm maxs b)))
            (if (<= (md-table-wrap--height body n w) allow)
                (setq best w)
              (aset pm c old))))))
    best))

;;; Tables and rows

(cl-defstruct (md-table-wrap--table (:constructor md-table-wrap--table-make))
  rows ncols mins maxs widths xs px unit indent face budget wraps)
;; wraps: non-nil when some cell is wider than its column, so rows get rules.

(cl-defstruct (md-table-wrap--row (:constructor md-table-wrap--row-make))
  tbl m len delim bounds cells cm wraps height lines offs ovs lc pt fp pc ti idx)
;; ti: index in its table's rows.  idx: index in the buffer's run of table
;; rows, across tables.  pc: (FP . LINES), lines painted with the foreign
;; faces FP.  m: marker at the row's first character.  bounds: offsets of the pipes
;; from m (-1 or len for a missing leading or closing pipe).  cells: (S . E)
;; offsets of the trimmed cell texts.  cm: `md-table-wrap--cell' per column.
;; wraps: per column, line spans relative to the cell start.  lines: one
;; display string per screen line; offs: per line, the source offset of each
;; char.  ovs: (LEAD . LINE-OVERLAYS).  lc, pt: line and position anchored at
;; point.  fp: the foreign overlay faces last mirrored.

(defvar md-table-wrap-mode)
(defvar hl-line-range-function)

(defvar-local md-table-wrap--tables nil)
(defvar-local md-table-wrap--prow nil "Row holding point after the last command.")
(defvar-local md-table-wrap--dirty nil "Positions changed since the last update.")
(defvar-local md-table-wrap--full nil "Positions where a newline was added or removed.")
(defvar-local md-table-wrap--remap nil "`face-remapping-alist' the layout was made with.")
(defvar-local md-table-wrap--win-px nil "Window body width the layout was made for.")
(defvar-local md-table-wrap--realloc nil "Tables waiting for an idle reallocation.")
(defvar-local md-table-wrap--timer nil)
(defvar-local md-table-wrap--rescan-timer nil)
(defvar-local md-table-wrap--saved nil "State to restore when the mode is turned off.")
(defvar-local md-table-wrap--built-rows nil
  "Rows that may have overlays.  A superset: a layout clears rows without
taking them off, so users check `md-table-wrap--built-p'.")

(defsubst md-table-wrap--beg (row) (marker-position (md-table-wrap--row-m row)))
(defsubst md-table-wrap--end (row)
  (+ (md-table-wrap--beg row) (md-table-wrap--row-len row)))

(defun md-table-wrap--live-p (row)
  (and row (marker-buffer (md-table-wrap--row-m row))))

(defun md-table-wrap--md-parser ()
  (and (fboundp 'treesit-parser-list)
       (cl-find-if (lambda (p) (eq (treesit-parser-language p) 'markdown))
                   (treesit-parser-list))))

(defun md-table-wrap--discover ()
  "Row start positions of every pipe table, as a list of lists."
  (let ((p (md-table-wrap--md-parser)))
    (if p
        (cl-loop for (_ . node) in (treesit-query-capture
                                    (treesit-parser-root-node p) '((pipe_table) @t))
                 for begs = (cl-loop for ch in (treesit-node-children node t)
                                     when (member (treesit-node-type ch)
                                                  '("pipe_table_header"
                                                    "pipe_table_delimiter_row"
                                                    "pipe_table_row"))
                                     collect (treesit-node-start ch))
                 when (cdr begs) collect begs)
      (md-table-wrap--discover-regexp))))

(defun md-table-wrap--discover-regexp ()
  "Fallback without a markdown parser: runs of lines starting with a pipe."
  (save-excursion
    (goto-char (point-min))
    (let (tables cur fence)
      (cl-flet ((close ()
                  (when (and (cdr cur)
                             (save-excursion
                               (goto-char (car (last cur 2)))
                               (looking-at "|?[ \t]*:?-+:?[ \t]*\\(|[ \t]*:?-+:?[ \t]*\\)*|?[ \t]*$")))
                    (push (reverse cur) tables))
                  (setq cur nil)))
        (while (not (eobp))
          (cond ((looking-at "[ \t]*\\(```\\|~~~\\)")
                 (close) (setq fence (not fence)))
                ((and (not fence) (looking-at "[ \t]*|"))
                 (push (1- (match-end 0)) cur))
                (t (close)))
          (forward-line 1))
        (close))
      (nreverse tables))))

(defun md-table-wrap--parse-row (row)
  "Read ROW's pipes and cells from the buffer."
  (let* ((beg (md-table-wrap--beg row))
         (end (save-excursion (goto-char beg) (line-end-position)))
         (len (- end beg)) bounds)
    (save-excursion
      (goto-char beg)
      (while (search-forward "|" end t)
        (unless (eq (char-before (1- (point))) ?\\)
          (push (- (point) 1 beg) bounds))))
    (setq bounds (nreverse bounds))
    (unless (eql (car bounds) 0) (push -1 bounds))
    (when (string-match-p "[^ \t]" (buffer-substring-no-properties
                                    (+ beg (car (last bounds)) 1) end))
      (setq bounds (append bounds (list len))))
    (let ((cells (cl-loop for (a b) on bounds while b
                          collect (let ((s (+ beg a 1)) (e (+ beg b)))
                                    (while (and (< s e) (memq (char-after s) '(?\s ?\t)))
                                      (cl-incf s))
                                    (while (and (> e s) (memq (char-before e) '(?\s ?\t)))
                                      (cl-decf e))
                                    (cons (- s beg) (- e beg))))))
      (setf (md-table-wrap--row-len row) len
            (md-table-wrap--row-bounds row) bounds
            (md-table-wrap--row-cells row) cells
            (md-table-wrap--row-delim row)
            (and cells
                 (cl-every (lambda (c)
                             (string-match-p "\\`:?-+:?\\'"
                                             (buffer-substring-no-properties
                                              (+ beg (car c)) (+ beg (cdr c)))))
                           cells))))))

(defun md-table-wrap--cell-text-at (row c)
  (let ((cell (nth c (md-table-wrap--row-cells row))) (beg (md-table-wrap--beg row)))
    (if cell
        (buffer-substring-no-properties (+ beg (car cell)) (+ beg (cdr cell)))
      "")))

(defun md-table-wrap--model-row (row n)
  (setf (md-table-wrap--row-cm row)
        (apply #'vector
               (cl-loop for c below n
                        collect (md-table-wrap--make-cell
                                 (md-table-wrap--cell-text-at row c))))))

(defvar md-table-wrap--alloc-rows 100
  "Most body rows column widths are allocated from; a taller table is sampled.")

(defun md-table-wrap--body (tbl &optional sample)
  "Cell models of TBL's body rows; with SAMPLE, at most an even spread of
`md-table-wrap--alloc-rows' of them."
  (let* ((all (cl-loop for r across (md-table-wrap--table-rows tbl)
                       unless (md-table-wrap--row-delim r)
                       collect (md-table-wrap--row-cm r)))
         (n (length all)))
    (if (or (not sample) (<= n md-table-wrap--alloc-rows))
        all
      (let ((v (vconcat all)))
        (cl-loop for k below md-table-wrap--alloc-rows
                 collect (aref v (/ (* k n) md-table-wrap--alloc-rows)))))))

(defun md-table-wrap--refresh (tbl)
  "Recompute TBL's per-column minimum and natural widths."
  (let* ((n (md-table-wrap--table-ncols tbl))
         (mins (make-vector n 1)) (maxs (make-vector n 1)))
    (dolist (r (md-table-wrap--body tbl))
      (dotimes (c n)
        (let ((cell (aref r c)))
          (aset mins c (max (aref mins c) (md-table-wrap--cell-minw cell)))
          (aset maxs c (max (aref maxs c) (md-table-wrap--cell-natural cell))))))
    (setf (md-table-wrap--table-mins tbl) mins (md-table-wrap--table-maxs tbl) maxs)))

(defun md-table-wrap--allocate (tbl &optional sticky)
  "Column widths for TBL at its budget, sticky to the current ones."
  (let* ((n (md-table-wrap--table-ncols tbl)) (body (md-table-wrap--body tbl t))
         (mins (md-table-wrap--table-mins tbl)) (maxs (md-table-wrap--table-maxs tbl))
         (b (- (md-table-wrap--table-budget tbl) (1+ (* 3 n))))
         (wrap (> (md-table-wrap--sum maxs) b))
         (new (cond ((not wrap) (copy-sequence maxs))
                    ((<= (md-table-wrap--sum mins) b)
                     (md-table-wrap--alloc body n mins maxs b))
                    ;; Too narrow for the longest words: cap the widest
                    ;; columns, and words break mid-word, as they would in a
                    ;; table hand-wrapped to this width.
                    ((>= b (* 3 n)) (md-table-wrap--squeeze mins b))
                    ;; Too narrow for anything: overflow.
                    (t (copy-sequence mins))))
         (old (md-table-wrap--table-widths tbl)))
    (if (and sticky wrap old (= (length old) n)
             (<= (md-table-wrap--sum old) b)
             (cl-loop for c below n always (>= (aref old c) (aref mins c)))
             (<= (md-table-wrap--height body n old)
                 (* (1+ md-table-wrap-sticky-slack) (md-table-wrap--height body n new))))
        old
      new)))

(defun md-table-wrap--geometry (tbl)
  (let* ((ws (md-table-wrap--table-widths tbl)) (n (length ws)) (x 0)
         (xs (make-vector n 0)) (px (make-vector (1+ n) 0)))
    (dotimes (i n)
      (aset px i x)
      (aset xs i (+ x 2))
      (setq x (+ x (aref ws i) 3)))
    (aset px n x)
    (setf (md-table-wrap--table-xs tbl) xs (md-table-wrap--table-px tbl) px
          ;; A cell wraps exactly when its natural width exceeds its column.
          (md-table-wrap--table-wraps tbl)
          (let ((maxs (md-table-wrap--table-maxs tbl)))
            (and maxs (cl-loop for c below (min n (length maxs))
                               thereis (> (aref maxs c) (aref ws c))))))))

(defun md-table-wrap--pixel (tbl x)
  (+ (md-table-wrap--table-indent tbl) (* x (md-table-wrap--table-unit tbl))))

(defun md-table-wrap--window ()
  (if (eq (window-buffer) (current-buffer))
      (selected-window)
    (get-buffer-window nil t)))

(defun md-table-wrap--body-px (win)
  (- (window-body-width win t)
     (if (and (bound-and-true-p display-line-numbers) (eq win (selected-window)))
         (line-number-display-width t)
       0)))

(defun md-table-wrap--budget (tbl)
  "Characters TBL may use, leaving the last column for the wrap glyph."
  (let ((win (md-table-wrap--window)))
    (if (not win)
        80
      (max 10 (1- (floor (- (md-table-wrap--body-px win) (md-table-wrap--table-indent tbl))
                         (md-table-wrap--table-unit tbl)))))))

;;; Strings and overlays

(defun md-table-wrap--wrap-row (row)
  (unless (md-table-wrap--row-delim row)
    (let* ((tbl (md-table-wrap--row-tbl row)) (ws (md-table-wrap--table-widths tbl))
           (wraps (cl-loop for c below (length ws)
                           collect (and (nth c (md-table-wrap--row-cells row))
                                        (md-table-wrap--wrap
                                         (aref (md-table-wrap--row-cm row) c)
                                         (aref ws c))))))
      (setf (md-table-wrap--row-wraps row) wraps
            (md-table-wrap--row-height row)
            (max 1 (apply #'max 1 (mapcar #'length wraps)))))))

(defun md-table-wrap--wrapped (row)
  "ROW, with its lines computed for its table's widths if they aren't yet."
  (unless (or (md-table-wrap--row-delim row) (md-table-wrap--row-wraps row))
    (md-table-wrap--wrap-row row))
  row)

(defun md-table-wrap--bounds (row i line)
  "(B . E) offsets from the row start of cell I's LINE, or nil."
  (let ((l (nth line (nth i (md-table-wrap--row-wraps row))))
        (cell (nth i (md-table-wrap--row-cells row))))
    (and l cell (cons (+ (car cell) (car l)) (+ (car cell) (cdr l))))))

(defun md-table-wrap--copy-end (row i line)
  (let ((b (md-table-wrap--bounds row i line)))
    (if b (cdr b) (cdr (nth i (md-table-wrap--row-cells row))))))

(defun md-table-wrap--fontify (beg end)
  ;; Font-lock alone.  Neither `jit-lock-fontify-now' nor `font-lock-ensure',
  ;; which jit-lock routes to it: both run `jit-lock-functions', re-entering
  ;; `md-table-wrap--jit', and mark the text fontified, so rows they cover
  ;; but this call doesn't build would never be built.
  (when (bound-and-true-p font-lock-mode)
    (save-excursion (font-lock-fontify-region beg end))))

(defun md-table-wrap--fontify-row (row)
  (md-table-wrap--fontify (md-table-wrap--beg row)
                          (min (point-max) (1+ (md-table-wrap--end row)))))

(defvar md-table-wrap-copy-map
  (let ((m (make-sparse-keymap)))
    (define-key m [down-mouse-1] #'md-table-wrap-mouse-set-point)
    (define-key m [mouse-1] #'ignore)
    (define-key m [drag-mouse-1] #'ignore)
    m)
  "Keymap on copied text: a click goes to the character it copies.")

(defun md-table-wrap--box-p () (not (eq md-table-wrap-style 'ascii)))

(defun md-table-wrap--border-face (tbl)
  "The face borders take: the border face over TBL's own, for its font."
  (list 'md-table-wrap-border (md-table-wrap--table-face tbl)))

(defun md-table-wrap--vbar (tbl)
  "A vertical border of TBL."
  (if (md-table-wrap--box-p)
      (propertize "│" 'face (md-table-wrap--border-face tbl))
    (propertize "|" 'face (md-table-wrap--table-face tbl))))

(defun md-table-wrap--hline (tbl left mid right &optional align fill)
  "A horizontal border across TBL with junctions LEFT, MID and RIGHT.
ALIGN non-nil starts it at the table's indent, for a line with nothing
real before it; a stretch is inert in a `display' string, so not there.
FILL is the line's character, by default the style's."
  (let ((face (md-table-wrap--border-face tbl))
        (fill (or fill (if (md-table-wrap--box-p) ?─ ?-))))
    (concat
     (and align (propertize " " 'display `(space :align-to (,(md-table-wrap--pixel tbl 0)))
                            'face face))
     (propertize (concat left
                         (mapconcat (lambda (w) (make-string (+ w 2) fill))
                                    (md-table-wrap--table-widths tbl) mid)
                         right)
                 'face face))))

(defun md-table-wrap--line (row l)
  "Display string of ROW's screen line L, and the source offset of each char."
  (let* ((tbl (md-table-wrap--row-tbl row)) (beg (md-table-wrap--beg row))
         (n (md-table-wrap--table-ncols tbl))
         (xs (md-table-wrap--table-xs tbl)) (px (md-table-wrap--table-px tbl))
         (bounds (md-table-wrap--row-bounds row)) (face (md-table-wrap--table-face tbl))
         (len (md-table-wrap--row-len row)) parts offs)
    (cl-flet* ((pipe-off (i) (let ((b (nth i bounds))) (and b (max 0 b))))
               (one (s off) (push s parts) (push off offs))
               (align (x off)
                 (one (propertize " " 'display
                                  `(space :align-to (,(md-table-wrap--pixel tbl x)))
                                  'face face)
                      off)))
      (dotimes (i n)
        (align (aref px i) (and (> i 0) (md-table-wrap--copy-end row (1- i) l)))
        (one (md-table-wrap--vbar tbl) (pipe-off i))
        (align (aref xs i) (let ((b (pipe-off i))) (and b (min len (1+ b)))))
        (let ((b (md-table-wrap--bounds row i l)))
          (when (and b (< (car b) (cdr b)))
            (push (propertize (buffer-substring (+ beg (car b)) (+ beg (cdr b)))
                              'md-table-wrap-text t)
                  parts)
            (cl-loop for k from (car b) below (cdr b) do (push k offs)))))
      (align (aref px n) (md-table-wrap--copy-end row (1- n) l))
      (one (md-table-wrap--vbar tbl) (pipe-off n)))
    (let ((s (apply #'concat (nreverse parts)))
          (v (vconcat (nreverse offs))))
      (add-text-properties 0 (length s)
                           (list 'md-table-wrap-row row 'md-table-wrap-line l
                                 'keymap md-table-wrap-copy-map)
                           s)
      (cons s v))))

(defun md-table-wrap--defaulted (s)
  "S with `default' under its faces, so nothing comes from its anchor.
An overlay or display string's unfaced attributes come from the buffer
text it is anchored at.  Anchors follow point, so a border anchored in a
code span or bold text would take that text's height or weight, and
change width as point moved."
  (add-face-text-property 0 (length s) 'default t s)
  s)

(defconst md-table-wrap--newline (md-table-wrap--defaulted (string ?\n))
  "A line span's display: its newline, whose face sets the line's height.")

(defun md-table-wrap--header-p (row)
  (let* ((rows (md-table-wrap--table-rows (md-table-wrap--row-tbl row)))
         (i (md-table-wrap--row-ti row)))
    (and (< (1+ i) (length rows))
         (md-table-wrap--row-delim (aref rows (1+ i))))))

(defun md-table-wrap--decorate (row l s)
  "S, ROW's screen line L, with the table's top edge above the header's first."
  (if (and (md-table-wrap--box-p) (= l 0) (md-table-wrap--header-p row))
      (concat (md-table-wrap--hline (md-table-wrap--row-tbl row) "┌" "┬" "┐" t) "\n" s)
    s))

(defun md-table-wrap--delim-string (row)
  (let* ((tbl (md-table-wrap--row-tbl row)) (ws (md-table-wrap--table-widths tbl)))
    (if (md-table-wrap--box-p)
        (md-table-wrap--hline tbl "╞" "╪" "╡" nil ?═)
      (propertize
       (concat
        (cl-loop for i below (length ws)
                 concat (let* ((txt (md-table-wrap--cell-text-at row i))
                               (l (string-prefix-p ":" txt)) (r (string-suffix-p ":" txt))
                               (w (+ (aref ws i) 2)))
                          (concat "|" (if l ":" "")
                                  (make-string (max 1 (- w (if l 1 0) (if r 1 0))) ?-)
                                  (if r ":" ""))))
        "|")
       'face (md-table-wrap--table-face tbl)))))

(defun md-table-wrap--rule (row)
  "A rule to draw below ROW, starting with its newline, or nil.
Rows of a wrapped table get one, so a cell's lines don't run on into the
next row's; tables that fit on one line each do not.  The last row gets
the table's bottom edge in the `box' style."
  (let* ((tbl (md-table-wrap--row-tbl row)) (rows (md-table-wrap--table-rows tbl))
         (i (md-table-wrap--row-ti row)))
    (when (and (not (md-table-wrap--row-delim row))
               ;; The header already has the delimiter row below it.
               (not (md-table-wrap--header-p row)))
      (cond ((= (1+ i) (length rows))
             (and (md-table-wrap--box-p)
                  (concat "\n" (md-table-wrap--hline tbl "└" "┴" "┘" t))))
            ((and md-table-wrap-row-rules (md-table-wrap--table-wraps tbl))
             (concat "\n" (if (md-table-wrap--box-p)
                              (md-table-wrap--hline tbl "├" "┼" "┤" t)
                            (md-table-wrap--hline tbl "|" "|" "|" t))))))))

(defun md-table-wrap--ov (beg end &rest props)
  (let ((o (make-overlay beg end nil t nil)))
    (overlay-put o 'md-table-wrap t)
    (overlay-put o 'priority 100)
    (while props (overlay-put o (pop props) (pop props)))
    o))

(defun md-table-wrap--build (row)
  "(Re)make ROW's strings and overlays, anchored at rest."
  (md-table-wrap--wrapped row)
  (cl-pushnew row md-table-wrap--built-rows :test #'eq)
  (let ((beg (md-table-wrap--beg row)) (end (md-table-wrap--end row))
        (ovs (md-table-wrap--row-ovs row)))
    (setf (md-table-wrap--row-lc row) nil (md-table-wrap--row-fp row) nil
          (md-table-wrap--row-pc row) nil)
    (if (md-table-wrap--row-delim row)
        (progn (mapc #'delete-overlay ovs)
               (setf (md-table-wrap--row-ovs row)
                     (list (md-table-wrap--ov beg end 'display
                                              (md-table-wrap--defaulted
                                               (md-table-wrap--delim-string row))))))
      (let* ((h (md-table-wrap--row-height row))
             (built (cl-loop for l below h collect (md-table-wrap--line row l))))
        (setf (md-table-wrap--row-lines row) (vconcat (mapcar #'car built))
              (md-table-wrap--row-offs row) (vconcat (mapcar #'cdr built)))
        (unless (and (consp ovs) (= (length ovs) (1+ h)) (overlay-buffer (car ovs)))
          (mapc #'delete-overlay ovs)
          (setf (md-table-wrap--row-ovs row)
                (cons (md-table-wrap--ov beg beg 'display "")
                      (cl-loop repeat h collect (md-table-wrap--ov beg beg)))))
        (md-table-wrap--anchor row nil)))))

(defun md-table-wrap--built-p (row) (md-table-wrap--row-ovs row))

(defun md-table-wrap--ensure-built (row)
  "Build ROW now if it isn't, fontifying it for its copies first."
  (unless (md-table-wrap--built-p row)
    (md-table-wrap--fontify-row row)
    (md-table-wrap--build row)))

(defun md-table-wrap--unfontify (beg end)
  "Mark BEG..END for jit-lock, so its rows are built when next shown."
  (with-silent-modifications
    (put-text-property beg (min (point-max) end) 'fontified nil)))

(defun md-table-wrap--unbuild (row)
  "Tear ROW's overlays down, leaving it to be built when next shown."
  (mapc #'delete-overlay (md-table-wrap--row-ovs row))
  (setq md-table-wrap--built-rows (delq row md-table-wrap--built-rows))
  (setf (md-table-wrap--row-ovs row) nil (md-table-wrap--row-lines row) nil
        (md-table-wrap--row-offs row) nil (md-table-wrap--row-lc row) nil
        (md-table-wrap--row-fp row) nil (md-table-wrap--row-pc row) nil)
  (md-table-wrap--unfontify (md-table-wrap--beg row) (1+ (md-table-wrap--end row))))

;;; Cursor, faces and anchors

(defun md-table-wrap--hl-line-p ()
  (or (bound-and-true-p hl-line-mode) (bound-and-true-p global-hl-line-mode)))

(defun md-table-wrap--foreign (row)
  "(START END FACE) of other overlays' faces over ROW, to mirror."
  (when md-table-wrap-mirror-faces
    (let ((skip (list (bound-and-true-p hl-line-overlay)
                      (bound-and-true-p global-hl-line-overlay)))
          acc)
      (dolist (o (overlays-in (md-table-wrap--beg row) (1+ (md-table-wrap--end row))))
        (let ((f (overlay-get o 'face)))
          (when (and f (not (overlay-get o 'md-table-wrap)) (not (memq o skip))
                     (< (overlay-start o) (overlay-end o))
                     (let ((w (overlay-get o 'window)))
                       (or (null w) (eq w (md-table-wrap--window)))))
            (push (list (overlay-start o) (overlay-end o) f) acc))))
      (sort acc (lambda (a b) (or (< (car a) (car b))
                                  (and (= (car a) (car b)) (< (cadr a) (cadr b)))))))))

(defun md-table-wrap--paint (row l pt fp hl)
  "Copy of ROW's line L with the cursor at PT and faces FP (and HL) on it."
  (let* ((s (copy-sequence (aref (md-table-wrap--row-lines row) l)))
         (offs (aref (md-table-wrap--row-offs row) l)) (beg (md-table-wrap--beg row)))
    (when pt
      (let ((off (- pt beg)) (best 0) bestd)
        (dotimes (j (length offs))
          (let ((o (aref offs j)))
            (when o
              (let ((d (- off o)))
                (when (and (>= d 0) (or (null bestd) (< d bestd)))
                  (setq best j bestd d))))))
        (put-text-property best (1+ best) 'cursor 100000 s)))
    (when hl
      (add-face-text-property 0 (length s) (if (facep 'hl-line) 'hl-line 'highlight) nil s))
    ;; Faces go on cell text only: a pipe or padding stands for its source
    ;; character on every line, but only one line shows that character.
    ;; Each face goes on in runs, not character by character.
    (dolist (f fp)
      (cl-flet ((covered (j)
                  (let ((o (aref offs j)))
                    (and o (get-text-property j 'md-table-wrap-text s)
                         (<= (nth 0 f) (+ beg o)) (< (+ beg o) (nth 1 f))))))
        (let ((j 0) (n (length offs)))
          (while (< j n)
            (if (not (covered j))
                (cl-incf j)
              (let ((k (1+ j)))
                (while (and (< k n) (covered k)) (cl-incf k))
                (add-face-text-property j k (nth 2 f) nil s)
                (setq j k)))))))
    s))

(defun md-table-wrap--show-row (row)
  "Put ROW's line strings on its line overlays."
  (let* ((lov (cdr (md-table-wrap--row-ovs row))) (h (length lov))
         (lc (md-table-wrap--row-lc row)) (fp (md-table-wrap--foreign row))
         (hl (and lc (md-table-wrap--hl-line-p)))
         (rule (md-table-wrap--rule row))
         ;; Lines painted with FP alone, kept while FP holds: moving point
         ;; through the row repaints only the line holding the cursor.
         (cache (and fp
                     (let ((pc (md-table-wrap--row-pc row)))
                       (if (and pc (equal (car pc) fp))
                           (cdr pc)
                         (cdr (setf (md-table-wrap--row-pc row)
                                    (cons fp (make-vector h nil))))))))
         (strs (cl-loop
                for o in lov for l from 0
                collect (let ((s (md-table-wrap--decorate
                                  row l
                                  (cond ((eql l lc)
                                         (md-table-wrap--paint
                                          row l (md-table-wrap--row-pt row) fp hl))
                                        (fp (or (aref cache l)
                                                (aset cache l (md-table-wrap--paint
                                                               row l nil fp nil))))
                                        (t (aref (md-table-wrap--row-lines row) l))))))
                          ;; An empty span can't display its line's newline.
                          (cond ((and (< l (1- h)) (= (overlay-start o) (overlay-end o)))
                                 (concat s "\n"))
                                ((and rule (= l (1- h))) (concat s rule))
                                (t s))))))
    ;; Several line overlays can share a start (fewer characters after point
    ;; than lines left); Emacs then shows their strings in no fixed order, so
    ;; the run's strings go, in order, on its first overlay.
    (while lov
      (let ((o (car lov)) (acc (list (car strs))))
        (setq lov (cdr lov) strs (cdr strs))
        (while (and lov (= (overlay-start (car lov)) (overlay-start o)))
          (push (car strs) acc)
          (overlay-put (car lov) 'before-string nil)
          (setq lov (cdr lov) strs (cdr strs)))
        (overlay-put o 'before-string
                     (md-table-wrap--defaulted (apply #'concat (nreverse acc))))))
    (setf (md-table-wrap--row-fp row) fp)))

(defun md-table-wrap--owner (row off)
  "Column whose cell, or the gap before it, holds offset OFF."
  (let ((cells (md-table-wrap--row-cells row))
        (n (md-table-wrap--table-ncols (md-table-wrap--row-tbl row))))
    (max 0 (min (1- n) (or (cl-position-if (lambda (c) (<= off (cdr c))) cells)
                           (1- (length cells)))))))

(defun md-table-wrap--cell-line-x (row i off)
  "(LINE . X) of offset OFF within, or just after, cell I's text."
  (let* ((tbl (md-table-wrap--row-tbl row)) (s (car (nth i (md-table-wrap--row-cells row))))
         (fw (nth i (md-table-wrap--row-wraps row)))
         (x0 (aref (md-table-wrap--table-xs tbl) i))
         (xmax (+ x0 (aref (md-table-wrap--table-widths tbl) i))))
    (cl-loop for l in fw for line from 0
             when (<= off (+ s (cdr l)))
             return (cons line (+ x0 (max 0 (- off s (car l)))))
             finally return
             (let ((l (car (last fw))))
               (cons (1- (length fw)) (min xmax (+ x0 (- off s (car l)))))))))

(defun md-table-wrap--pos-line-x (row off)
  "(LINE . X) of offset OFF in ROW, X in table characters.
Padding after a cell's text belongs to the cell's last line, as in a
hand-aligned table; a pipe and the padding after it, to the first line."
  (let* ((tbl (md-table-wrap--row-tbl row)) (i (md-table-wrap--owner row off))
         (cell (nth i (md-table-wrap--row-cells row)))
         (pipe (nth i (md-table-wrap--row-bounds row)))
         (xs (md-table-wrap--table-xs tbl)) (px (md-table-wrap--table-px tbl)))
    (cond ((or (null cell) (null (nth i (md-table-wrap--row-wraps row)))) (cons 0 0))
          ((and (< off (car cell)) (> i 0) pipe (<= off pipe)
                (nth (1- i) (md-table-wrap--row-wraps row)))
           (let ((lx (md-table-wrap--cell-line-x row (1- i) off)))
             (if (= off pipe) (cons (car lx) (aref px i)) lx)))
          ((< off (car cell))
           (cons 0 (min (aref xs i) (+ (aref px i) (max 0 (- off (or pipe 0)))))))
          ((eql off (nth (1+ i) (md-table-wrap--row-bounds row)))
           (cons (car (md-table-wrap--cell-line-x row i off)) (aref px (1+ i))))
          (t (md-table-wrap--cell-line-x row i off)))))

(defun md-table-wrap--pos-at (row line x)
  "Offset of the text nearest column X on ROW's screen LINE."
  (let* ((tbl (md-table-wrap--row-tbl row))
         (px (md-table-wrap--table-px tbl)) (xs (md-table-wrap--table-xs tbl))
         (n (min (md-table-wrap--table-ncols tbl) (length (md-table-wrap--row-cells row))))
         (i (or (cl-loop for j below n when (< x (aref px (1+ j))) return j) (1- n)))
         (b (md-table-wrap--bounds row i line)))
    (if b
        (+ (car b) (min (- (cdr b) (car b)) (max 0 (- x (aref xs i)))))
      (or (cl-loop for j from (1+ i) below n
                   for bj = (md-table-wrap--bounds row j line) when bj return (car bj))
          (cl-loop for j downfrom (1- i) to 0
                   for bj = (md-table-wrap--bounds row j line) when bj return (cdr bj))
          (cdr (nth i (md-table-wrap--row-cells row)))
          0))))

(defun md-table-wrap--anchor (row pt)
  "Anchor ROW's lines at rest, or around PT if non-nil."
  (unless (or (md-table-wrap--row-delim row) (not (md-table-wrap--built-p row)))
    (let* ((beg (md-table-wrap--beg row)) (end (md-table-wrap--end row))
           (h (md-table-wrap--row-height row))
           (lead (car (md-table-wrap--row-ovs row))) (lov (cdr (md-table-wrap--row-ovs row)))
           (lc (and pt (car (md-table-wrap--pos-line-x row (- pt beg)))))
           (as (cl-loop for l below h
                        collect (cond ((null lc) (min end (+ beg l)))
                                      ((< l lc) (min (+ beg l) (- pt (- lc l))))
                                      (t (min end (+ pt (- l lc)))))))
           ;; A window starting at one of this row's lines keeps starting there.
           (keep (cl-loop for w in (get-buffer-window-list nil nil t)
                          for l = (cl-position (window-start w) lov :key #'overlay-start)
                          when (and l (> l 0)) collect (cons w l))))
      (move-overlay lead beg (if (eql lc 0) pt beg))
      (cl-loop for o in lov for (a b) on as for l from 0
               do (move-overlay o a (or b end))
               ;; Each line's newline is its span's display, so the next
               ;; screen line starts at a buffer position of its own and
               ;; one-line scrolling can step through a tall row.
               (overlay-put o 'display (cond ((= l (1- h)) "")
                                             ((< a (or b end)) md-table-wrap--newline))))
      (setf (md-table-wrap--row-lc row) lc (md-table-wrap--row-pt row) pt)
      (md-table-wrap--show-row row)
      (dolist (k keep)
        (set-window-start (car k) (overlay-start (nth (cdr k) lov)) t)))))

;;; Layout

(defun md-table-wrap--row-at (pos)
  (cl-loop for tbl in md-table-wrap--tables
           for rows = (md-table-wrap--table-rows tbl)
           when (and (> (length rows) 0)
                     (<= (md-table-wrap--beg (aref rows 0)) pos)
                     (<= pos (md-table-wrap--end (aref rows (1- (length rows))))))
           return (let ((lo 0) (hi (1- (length rows))))
                    (while (< lo hi)
                      (let ((mid (/ (+ lo hi 1) 2)))
                        (if (<= (md-table-wrap--beg (aref rows mid)) pos)
                            (setq lo mid)
                          (setq hi (1- mid)))))
                    (let ((r (aref rows lo)))
                      (and (<= (md-table-wrap--beg r) pos (md-table-wrap--end r)) r)))))

(defun md-table-wrap--measure (tbl)
  "Character width, indentation and face of TBL, measured as it renders."
  (let* ((rows (md-table-wrap--table-rows tbl))
         (hb (md-table-wrap--beg (aref rows 0)))
         ;; The delimiter row's face is the table's own, with none of the
         ;; bold or shadow a header cell or a pipe may add.
         (dr (cl-find-if #'md-table-wrap--row-delim rows))
         (face (get-text-property (if (and dr (md-table-wrap--row-cells dr))
                                      (+ (md-table-wrap--beg dr)
                                         (car (car (md-table-wrap--row-cells dr))))
                                    hb)
                                  'face))
         (unit (string-pixel-width (propertize "x" 'face face) (current-buffer)))
         (lbp (save-excursion (goto-char hb) (line-beginning-position))))
    (setf (md-table-wrap--table-face tbl) face
          (md-table-wrap--table-unit tbl) (if (> unit 0) unit (frame-char-width))
          (md-table-wrap--table-indent tbl)
          (if (> hb lbp)
              (let ((s (buffer-substring lbp hb)))
                ;; `string-pixel-width' inserts into a work buffer, where
                ;; read-only text signals (md-table-align DESIGN.md v4.1).
                (remove-list-of-text-properties
                 0 (length s) '(read-only modification-hooks insert-in-front-hooks
                                insert-behind-hooks)
                 s)
                (string-pixel-width s (current-buffer)))
            0))))

(defun md-table-wrap--layout-table (tbl)
  "Lay TBL out from scratch: parse, measure, allocate and wrap every row.
No row is built: the table is marked for jit-lock, which builds the rows
redisplay shows."
  (let* ((rows (md-table-wrap--table-rows tbl)))
    ;; Until the geometry below is set, `md-table-wrap--jit' leaves TBL be.
    (setf (md-table-wrap--table-px tbl) nil)
    (cl-loop for r across rows
             do (mapc #'delete-overlay (md-table-wrap--row-ovs r))
             (setf (md-table-wrap--row-ovs r) nil (md-table-wrap--row-wraps r) nil)
             (md-table-wrap--parse-row r))
    ;; Measuring reads the delimiter row's face.
    (md-table-wrap--fontify-row (or (cl-find-if #'md-table-wrap--row-delim rows)
                                    (aref rows 0)))
    (md-table-wrap--measure tbl)
    (let ((n (cl-loop for r across rows
                      maximize (max 1 (length (md-table-wrap--row-cells r))))))
      (setf (md-table-wrap--table-ncols tbl) n)
      (cl-loop for r across rows unless (md-table-wrap--row-delim r)
               do (md-table-wrap--model-row r n)))
    (md-table-wrap--refresh tbl)
    (setf (md-table-wrap--table-budget tbl) (md-table-wrap--budget tbl)
          (md-table-wrap--table-widths tbl) nil
          (md-table-wrap--table-widths tbl) (md-table-wrap--allocate tbl))
    (md-table-wrap--geometry tbl)
    (md-table-wrap--unfontify (md-table-wrap--beg (aref rows 0))
                              (1+ (md-table-wrap--end (aref rows (1- (length rows))))))))

(defun md-table-wrap--relayout-widths (tbl widths)
  "Re-lay TBL at WIDTHS, without reparsing.
Every row's lines are dropped, and only the rows that are built are
rebuilt; the rest are wrapped when next needed."
  (setf (md-table-wrap--table-widths tbl) widths)
  (md-table-wrap--geometry tbl)
  (cl-loop for r across (md-table-wrap--table-rows tbl)
           do (setf (md-table-wrap--row-wraps r) nil)
           (when (md-table-wrap--built-p r) (md-table-wrap--build r)))
  (setq md-table-wrap--prow nil))

(defvar md-table-wrap--keep-rows 60
  "Built rows further than this from point and every window start are evicted.")

(defun md-table-wrap--jit (beg end)
  "Build the rows of laid-out tables intersecting BEG..END, for redisplay."
  (with-demoted-errors "md-table-wrap: %S"
    (dolist (tbl md-table-wrap--tables)
      (let ((rows (md-table-wrap--table-rows tbl)))
        (when (and (md-table-wrap--table-px tbl)
                   (<= (md-table-wrap--beg (aref rows 0)) end)
                   (>= (md-table-wrap--end (aref rows (1- (length rows)))) beg))
          (cl-loop for r across rows
                   when (and (not (md-table-wrap--built-p r))
                             (<= (md-table-wrap--beg r) end)
                             (>= (md-table-wrap--end r) beg))
                   ;; Font-lock covered BEG..END in this pass already.
                   do (when (or (< (md-table-wrap--beg r) beg)
                                (> (md-table-wrap--end r) end))
                        (md-table-wrap--fontify-row r))
                   (md-table-wrap--build r))))))
  nil)

(defun md-table-wrap--index-near (pos)
  "Buffer-wide index of the first table row ending at or after POS."
  (or (cl-loop for tbl in md-table-wrap--tables
               for rows = (md-table-wrap--table-rows tbl)
               when (>= (md-table-wrap--end (aref rows (1- (length rows)))) pos)
               return (let ((lo 0) (hi (1- (length rows))))
                        (while (< lo hi)
                          (let ((mid (/ (+ lo hi) 2)))
                            (if (>= (md-table-wrap--end (aref rows mid)) pos)
                                (setq hi mid)
                              (setq lo (1+ mid)))))
                        (md-table-wrap--row-idx (aref rows lo))))
      ;; Past every table: one beyond the last row.
      (let ((last (car (last md-table-wrap--tables))))
        (if last
            (let ((rows (md-table-wrap--table-rows last)))
              (1+ (md-table-wrap--row-idx (aref rows (1- (length rows))))))
          0))))

(defun md-table-wrap--evict ()
  "Tear down built rows far from point and from every window onto the buffer."
  (setq md-table-wrap--built-rows
        (cl-delete-if-not #'md-table-wrap--built-p md-table-wrap--built-rows))
  (when (> (length md-table-wrap--built-rows) md-table-wrap--keep-rows)
    (let ((near (mapcar #'md-table-wrap--index-near
                        (cons (point) (mapcar #'window-start
                                              (get-buffer-window-list nil nil t))))))
      (dolist (r (copy-sequence md-table-wrap--built-rows))
        (when (and (not (eq r md-table-wrap--prow))
                   (cl-loop for j in near
                            always (> (abs (- (md-table-wrap--row-idx r) j))
                                      md-table-wrap--keep-rows)))
          (md-table-wrap--unbuild r))))))

(defun md-table-wrap--forget ()
  "Drop every overlay and marker the layout holds."
  (remove-overlays (point-min) (point-max) 'md-table-wrap t)
  (dolist (tbl md-table-wrap--tables)
    (cl-loop for r across (md-table-wrap--table-rows tbl)
             do (set-marker (md-table-wrap--row-m r) nil)))
  (setq md-table-wrap--tables nil md-table-wrap--prow nil md-table-wrap--built-rows nil))

(defun md-table-wrap--layout-all ()
  "Find every table in the buffer and lay it out."
  (md-table-wrap--forget)
  (setq md-table-wrap--dirty nil md-table-wrap--full nil md-table-wrap--realloc nil
        md-table-wrap--remap face-remapping-alist
        md-table-wrap--win-px (let ((w (md-table-wrap--window)))
                                (and w (md-table-wrap--body-px w)))
        md-table-wrap--tables
        (cl-loop for begs in (md-table-wrap--discover)
                 collect (let ((tbl (md-table-wrap--table-make)))
                           (setf (md-table-wrap--table-rows tbl)
                                 (vconcat (mapcar (lambda (b)
                                                    (md-table-wrap--row-make
                                                     :tbl tbl :m (copy-marker b)))
                                                  begs)))
                           tbl)))
  (let ((idx 0))
    (dolist (tbl md-table-wrap--tables)
      (cl-loop for r across (md-table-wrap--table-rows tbl) for ti from 0
               do (setf (md-table-wrap--row-ti r) ti (md-table-wrap--row-idx r) idx)
               (cl-incf idx))))
  (mapc #'md-table-wrap--layout-table md-table-wrap--tables))

;;; Following point and edits

(defvar md-table-wrap--scroll-commands
  '(scroll-up-command scroll-down-command scroll-up scroll-down
    scroll-up-line scroll-down-line mwheel-scroll pixel-scroll-precision)
  "Commands that leave point at the window start.")

(defun md-table-wrap--follow-point ()
  ;; A scroll leaves point at `window-start', which may be line L's anchor:
  ;; on screen that is line L, though the model reads it as line 0.
  (let ((row (md-table-wrap--row-at (point))))
    (when (and row (memq this-command md-table-wrap--scroll-commands)
               (not (md-table-wrap--row-delim row)) (= (point) (window-start)))
      (let ((l (cl-position (point) (cdr (md-table-wrap--row-ovs row))
                            :key #'overlay-start :from-end t)))
        (when (and l (> l 0))
          (goto-char (+ (md-table-wrap--beg row) (md-table-wrap--pos-at row l 0)))))))
  (let ((row (md-table-wrap--row-at (point))))
    (when (and md-table-wrap--prow (not (eq row md-table-wrap--prow))
               (md-table-wrap--live-p md-table-wrap--prow))
      (md-table-wrap--anchor md-table-wrap--prow nil))
    (when row
      ;; Anchoring at point can't wait for redisplay to build the row.
      (when (md-table-wrap--table-px (md-table-wrap--row-tbl row))
        (md-table-wrap--ensure-built row))
      (md-table-wrap--anchor row (point))
      (unless (md-table-wrap--row-delim row) (setq disable-point-adjustment t)))
    (setq md-table-wrap--prow row)))

(defun md-table-wrap--near-table-p (pos)
  (or (cl-loop for tbl in md-table-wrap--tables
               for rows = (md-table-wrap--table-rows tbl)
               thereis (<= (save-excursion
                             (goto-char (md-table-wrap--beg (aref rows 0)))
                             (1- (line-beginning-position)))
                           pos
                           (1+ (md-table-wrap--end (aref rows (1- (length rows)))))))
      (save-excursion (goto-char pos) (forward-line 0) (looking-at "[ \t]*|"))))

(defun md-table-wrap--update-row (row)
  "Rebuild ROW after an edit.  Non-nil means its table needs a full layout."
  (let ((tbl (md-table-wrap--row-tbl row)) (was (md-table-wrap--row-delim row)))
    (md-table-wrap--parse-row row)
    (if (or (not (eq was (md-table-wrap--row-delim row)))
            (> (length (md-table-wrap--row-cells row)) (md-table-wrap--table-ncols tbl)))
        t
      (unless (md-table-wrap--row-delim row)
        (md-table-wrap--model-row row (md-table-wrap--table-ncols tbl))
        (md-table-wrap--wrap-row row)
        ;; The table wraps now: its other built rows need their rules.
        (when (and (> (md-table-wrap--row-height row) 1)
                   (not (md-table-wrap--table-wraps tbl)))
          (setf (md-table-wrap--table-wraps tbl) t)
          (dolist (r md-table-wrap--built-rows)
            (when (and (eq (md-table-wrap--row-tbl r) tbl) (not (eq r row))
                       (md-table-wrap--built-p r))
              (md-table-wrap--build r)))))
      ;; A row that isn't built is built from the new model when shown.
      (when (md-table-wrap--built-p row)
        (md-table-wrap--fontify-row row)
        (md-table-wrap--build row))
      (cl-pushnew tbl md-table-wrap--realloc)
      (md-table-wrap--schedule #'md-table-wrap--idle-realloc)
      nil)))

(defun md-table-wrap--process ()
  "Bring the layout up to date with the edits since the last call."
  (let ((full md-table-wrap--full) (dirty md-table-wrap--dirty))
    (setq md-table-wrap--full nil md-table-wrap--dirty nil)
    (cond
     ((and full (cl-some #'md-table-wrap--near-table-p full))
      (md-table-wrap--layout-all))
     (t
      (when full (md-table-wrap--schedule #'md-table-wrap--layout-all 'rescan))
      (let (relayout)
        (dolist (row (delete-dups (delq nil (mapcar #'md-table-wrap--row-at dirty))))
          (when (md-table-wrap--update-row row)
            (cl-pushnew (md-table-wrap--row-tbl row) relayout)))
        (when relayout
          (mapc #'md-table-wrap--layout-table relayout)
          (setq md-table-wrap--prow nil)))))))

(defun md-table-wrap--check-geometry ()
  "Re-lay out after a width or font change."
  (cond
   ((not (equal face-remapping-alist md-table-wrap--remap)) (md-table-wrap--layout-all))
   ((let ((w (md-table-wrap--window)))
      (and w (not (eql (md-table-wrap--body-px w) md-table-wrap--win-px))))
    (setq md-table-wrap--win-px (md-table-wrap--body-px (md-table-wrap--window)))
    (dolist (tbl md-table-wrap--tables)
      (let ((b (md-table-wrap--budget tbl)))
        (unless (eql b (md-table-wrap--table-budget tbl))
          (setf (md-table-wrap--table-budget tbl) b)
          (md-table-wrap--relayout-widths tbl (md-table-wrap--allocate tbl))))))))

(defun md-table-wrap--post-command ()
  (with-demoted-errors "md-table-wrap: %S"
    (md-table-wrap--process)
    (md-table-wrap--check-geometry)
    (md-table-wrap--follow-point)
    (md-table-wrap--evict)))

(defun md-table-wrap--schedule (fn &optional rescan)
  "Run FN in this buffer after `md-table-wrap-idle-delay' of idle time.
RESCAN non-nil uses the rescan timer, so it doesn't displace a pending
reallocation."
  (let ((buf (current-buffer))
        (var (if rescan 'md-table-wrap--rescan-timer 'md-table-wrap--timer)))
    (when (symbol-value var) (cancel-timer (symbol-value var)))
    (set var (run-with-idle-timer
              md-table-wrap-idle-delay nil
              (lambda ()
                (when (buffer-live-p buf)
                  (with-current-buffer buf
                    (set var nil)
                    (when md-table-wrap-mode
                      (with-demoted-errors "md-table-wrap: %S"
                        (funcall fn)
                        (md-table-wrap--follow-point))))))))))

(defun md-table-wrap--idle-realloc ()
  "Reallocate widths after edits; re-lay a table only if they change."
  ;; Edits made outside the command loop (process output) are picked up here.
  (md-table-wrap--process)
  (dolist (tbl (prog1 md-table-wrap--realloc (setq md-table-wrap--realloc nil)))
    (when (memq tbl md-table-wrap--tables)
      (md-table-wrap--refresh tbl)
      (let ((w (md-table-wrap--allocate tbl t)))
        (unless (equal w (md-table-wrap--table-widths tbl))
          (md-table-wrap--relayout-widths tbl w))))))

(defun md-table-wrap--before-change (beg end)
  (when (save-excursion (goto-char beg) (search-forward "\n" end t))
    (push beg md-table-wrap--full)))

(defun md-table-wrap--after-change (beg end _len)
  (when (save-excursion (goto-char beg) (search-forward "\n" end t))
    (push beg md-table-wrap--full))
  (push beg md-table-wrap--dirty)
  (unless (= beg end) (push (1- end) md-table-wrap--dirty))
  (md-table-wrap--schedule #'md-table-wrap--idle-realloc))

(defun md-table-wrap--pre-redisplay (&optional win)
  "Mirror overlay faces onto the copies of the rows on screen."
  (when (and md-table-wrap-mode md-table-wrap-mirror-faces md-table-wrap--tables)
    (with-demoted-errors "md-table-wrap: %S"
      (let* ((w (if (windowp win) win (selected-window)))
             (ws (window-start w)) (we (window-end w)))
        ;; Only a built row has copies to mirror onto.
        (dolist (r md-table-wrap--built-rows)
          (when (and (md-table-wrap--built-p r) (not (md-table-wrap--row-delim r))
                     (<= (md-table-wrap--beg r) we) (>= (md-table-wrap--end r) ws)
                     (not (equal (md-table-wrap--foreign r) (md-table-wrap--row-fp r))))
            (md-table-wrap--show-row r)))))))

(defun md-table-wrap--hl-line-range ()
  (if (md-table-wrap--row-at (point))
      (cons (point) (point))
    (cons (line-beginning-position) (line-beginning-position 2))))

;;; Commands

(defvar md-table-wrap--goal nil "Goal column, in table characters, of vertical motion.")

(defun md-table-wrap--indent-chars (row)
  (- (md-table-wrap--beg row)
     (save-excursion (goto-char (md-table-wrap--beg row)) (line-beginning-position))))

(defun md-table-wrap--vmove (dir)
  (let* ((row (md-table-wrap--row-at (point)))
         (body (and row (not (md-table-wrap--row-delim row))))
         (lx (and body (md-table-wrap--pos-line-x (md-table-wrap--wrapped row)
                                                  (- (point) (md-table-wrap--beg row)))))
         (col (current-column))
         (goal (or (and (memq last-command '(md-table-wrap-next-line
                                             md-table-wrap-previous-line))
                        md-table-wrap--goal)
                   (and body (cdr lx))))
         (line (and body (+ (car lx) dir))))
    (if (and body (>= line 0) (< line (md-table-wrap--row-height row)))
        (goto-char (+ (md-table-wrap--beg row) (md-table-wrap--pos-at row line goal)))
      (if body
          (progn (goto-char (if (> dir 0)
                                (min (point-max) (1+ (md-table-wrap--end row)))
                              (max (point-min)
                                   (1- (- (md-table-wrap--beg row)
                                          (md-table-wrap--indent-chars row))))))
                 (move-to-column (+ goal (md-table-wrap--indent-chars row))))
        (line-move dir))
      ;; Landing on a row: place by the model, on its first or last line.
      (let ((r2 (md-table-wrap--row-at (point))))
        (cond ((null r2))
              ((md-table-wrap--row-delim r2) (goto-char (md-table-wrap--beg r2)))
              (t (md-table-wrap--wrapped r2)
                 (setq goal (or goal (max 0 (- col (md-table-wrap--indent-chars r2)))))
                 (goto-char (+ (md-table-wrap--beg r2)
                               (md-table-wrap--pos-at
                                r2 (if (> dir 0) 0 (1- (md-table-wrap--row-height r2)))
                                goal)))))))
    (setq md-table-wrap--goal goal)))

(defun md-table-wrap-next-line (&optional arg)
  "Move down ARG screen lines, through wrapped table rows."
  (interactive "^p")
  (dotimes (_ (abs (or arg 1))) (md-table-wrap--vmove (if (< (or arg 1) 0) -1 1))))

(defun md-table-wrap-previous-line (&optional arg)
  "Move up ARG screen lines, through wrapped table rows."
  (interactive "^p")
  (dotimes (_ (abs (or arg 1))) (md-table-wrap--vmove (if (< (or arg 1) 0) 1 -1))))

(defun md-table-wrap--hmove (x)
  (let ((row (md-table-wrap--row-at (point))))
    (if (or (null row) (md-table-wrap--row-delim row))
        (if (= x 0)
            (if visual-line-mode (beginning-of-visual-line) (move-beginning-of-line 1))
          (if visual-line-mode (end-of-visual-line) (move-end-of-line 1)))
      (let ((beg (md-table-wrap--beg (md-table-wrap--wrapped row))))
        (goto-char (+ beg (md-table-wrap--pos-at
                           row (car (md-table-wrap--pos-line-x row (- (point) beg)))
                           x)))))))

(defun md-table-wrap-beginning-of-line ()
  "Move to the start of the screen line, through wrapped table rows."
  (interactive "^")
  (md-table-wrap--hmove 0))

(defun md-table-wrap-end-of-line ()
  "Move to the end of the screen line, through wrapped table rows."
  (interactive "^")
  (md-table-wrap--hmove most-positive-fixnum))

(defun md-table-wrap-mouse-set-point (event)
  "Move point to the character a click on copied table text stands for."
  (interactive "e")
  (let* ((posn (event-start event)) (str (posn-string posn)))
    (select-window (posn-window posn))
    (let ((row (and str (get-text-property (cdr str) 'md-table-wrap-row (car str)))))
      (if (not (md-table-wrap--live-p row))
          (mouse-set-point event)
        ;; The click's string is a line, or a run of lines joined on one
        ;; overlay; find which line and character it was.
        (let* ((s (car str)) (j (cdr str))
               (line (get-text-property j 'md-table-wrap-line s))
               (start (let ((k j))
                        (while (and (> k 0)
                                    (eql (get-text-property (1- k) 'md-table-wrap-line s)
                                         line))
                          (cl-decf k))
                        k))
               (offs (and line (aref (md-table-wrap--row-offs row) line)))
               (k (- j start))
               (off (and offs (< k (length offs))
                         (or (aref offs k)
                             (cl-loop for i downfrom k to 0 thereis (aref offs i))))))
          (goto-char (+ (md-table-wrap--beg row) (or off 0))))))))

(defun md-table-wrap-refresh ()
  "Find and lay out every table in the buffer again."
  (interactive)
  (when md-table-wrap-mode
    (md-table-wrap--layout-all)
    (md-table-wrap--follow-point)))

(defvar md-table-wrap-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m [remap next-line] #'md-table-wrap-next-line)
    (define-key m [remap previous-line] #'md-table-wrap-previous-line)
    (define-key m [remap move-beginning-of-line] #'md-table-wrap-beginning-of-line)
    (define-key m [remap move-end-of-line] #'md-table-wrap-end-of-line)
    (define-key m [remap beginning-of-visual-line] #'md-table-wrap-beginning-of-line)
    (define-key m [remap end-of-visual-line] #'md-table-wrap-end-of-line)
    m)
  "Keymap of `md-table-wrap-mode': line motion through wrapped rows.")

(defvar md-table-align-mode)
(declare-function md-table-align-mode "md-table-align")

;;;###autoload
(define-minor-mode md-table-wrap-mode
  "Draw Markdown tables with their cells wrapped to fit the window.

A table wider than the window has its cells word-wrapped inside their
columns, with a rule between rows.  Buffer text is not modified, so this
works in read-only buffers too.  C-n/C-p and C-a/C-e move by screen line
through wrapped rows; C-f/C-b and the region follow the buffer's order,
cell by cell.

Switches `md-table-align-mode' off in the buffer while on."
  :lighter " TblWrap"
  :keymap md-table-wrap-mode-map
  (if md-table-wrap-mode
      (progn
        (setq md-table-wrap--saved
              (list :md-table-align (bound-and-true-p md-table-align-mode)
                    :hl-local (local-variable-p 'hl-line-range-function)
                    :hl (bound-and-true-p hl-line-range-function)))
        (when (bound-and-true-p md-table-align-mode) (md-table-align-mode -1))
        (setq-local hl-line-range-function #'md-table-wrap--hl-line-range)
        (add-hook 'post-command-hook #'md-table-wrap--post-command nil t)
        (add-hook 'before-change-functions #'md-table-wrap--before-change nil t)
        (add-hook 'after-change-functions #'md-table-wrap--after-change nil t)
        ;; After the global `redisplay--update-region-highlight'.
        (add-hook 'pre-redisplay-functions #'md-table-wrap--pre-redisplay 90 t)
        ;; `jit-lock-register' prepends; rows are built from fontified text,
        ;; so the builder runs after font-lock in the same pass.
        (jit-lock-register #'md-table-wrap--jit)
        (remove-hook 'jit-lock-functions #'md-table-wrap--jit t)
        (add-hook 'jit-lock-functions #'md-table-wrap--jit 90 t)
        (md-table-wrap--layout-all)
        (md-table-wrap--follow-point))
    (jit-lock-unregister #'md-table-wrap--jit)
    (remove-hook 'post-command-hook #'md-table-wrap--post-command t)
    (remove-hook 'before-change-functions #'md-table-wrap--before-change t)
    (remove-hook 'after-change-functions #'md-table-wrap--after-change t)
    (remove-hook 'pre-redisplay-functions #'md-table-wrap--pre-redisplay t)
    (dolist (v '(md-table-wrap--timer md-table-wrap--rescan-timer))
      (when (symbol-value v) (cancel-timer (symbol-value v)) (set v nil)))
    (md-table-wrap--forget)
    (if (plist-get md-table-wrap--saved :hl-local)
        (setq-local hl-line-range-function (plist-get md-table-wrap--saved :hl))
      (kill-local-variable 'hl-line-range-function))
    (when (and (plist-get md-table-wrap--saved :md-table-align)
               (fboundp 'md-table-align-mode))
      (md-table-align-mode 1))
    (setq md-table-wrap--saved nil)))

(defun md-table-wrap--maybe-enable ()
  "Enable `md-table-wrap-mode' if this buffer's mode calls for it."
  (when (apply #'derived-mode-p md-table-wrap-modes)
    (md-table-wrap-mode 1)))

;;;###autoload
(define-globalized-minor-mode global-md-table-wrap-mode
  md-table-wrap-mode md-table-wrap--maybe-enable)

(defun md-table-wrap-unload-function ()
  "Switch the mode off everywhere before `unload-feature' removes it.
Without this, unloading would leave overlays, hooks and timers installed
with the functions that manage them gone.  Returning nil leaves the
standard unloading to `unload-feature'."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (bound-and-true-p md-table-wrap-mode)
        (md-table-wrap-mode -1))))
  nil)

(provide 'md-table-wrap)

;;; md-table-wrap.el ends here
