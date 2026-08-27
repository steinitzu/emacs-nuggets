;;; md-table-align-tests.el --- Tests for md-table-align -*- lexical-binding: t; -*-

;;; Commentary:

;; These run inside a real TTY frame (see run-tests.sh), in real buffers under
;; a real `markdown-ts-mode', and assert on geometry reported by
;; `posn-at-point' -- i.e. where Emacs' redisplay engine actually put the text.
;; Nothing is stubbed.  On a TTY the canonical character width is 1, so
;; `posn-col-row' columns and `:align-to' units coincide, which makes the
;; expected layouts exact rather than approximate.

;;; Code:

(require 'ert)
(require 'treesit)
(require 'markdown-ts-mode)
(require 'md-table-align)

;;;; Fixtures

(defconst md-table-align-tests--simple
  "| Name | Qty |
|:-----|----:|
| apple | 3 |
| fig | 12 |
")

;; Aligned, the fixture above renders as
;;
;;     | Name  | Qty |
;;     |:------|----:|
;;     | apple |   3 |
;;     | fig   |  12 |
;;
;; i.e. pipes at columns 0, 8 and 14 on every row.  Column widths are 5
;; ("apple") and 3 ("Qty"), each surrounded by one space of padding.
(defconst md-table-align-tests--simple-columns '(0 8 14))

;;;; Helpers

(defmacro md-table-align-tests--with-buffer (text &rest body)
  "Display TEXT in a `markdown-ts-mode' buffer in a live window, then run BODY."
  (declare (indent 1) (debug t))
  `(let ((buf (generate-new-buffer "*md-table-align-test*")))
     (unwind-protect
         (progn
           (switch-to-buffer buf)
           (insert ,text)
           (goto-char (point-min))
           (markdown-ts-mode)
           (set-buffer-modified-p nil)
           (redisplay t)
           ,@body)
       (kill-buffer buf))))

(defun md-table-align-tests--column (pos)
  "Return the screen column at which buffer position POS is rendered."
  (let ((posn (posn-at-point pos)))
    (should posn)
    (car (posn-col-row posn))))

(defun md-table-align-tests--pipe-columns ()
  "Return the rendered columns of each line's pipes, one list per pipe line."
  (save-excursion
    (goto-char (point-min))
    (let (lines)
      (while (not (eobp))
        (let ((eol (line-end-position))
              (cols nil))
          (while (search-forward "|" eol t)
            (push (md-table-align-tests--column (1- (point))) cols))
          (when cols (push (nreverse cols) lines)))
        (forward-line 1))
      (nreverse lines))))

(defun md-table-align-tests--column-of (string)
  "Return the rendered column of the first occurrence of STRING."
  (save-excursion
    (goto-char (point-min))
    (should (search-forward string nil t))
    (md-table-align-tests--column (match-beginning 0))))

(defun md-table-align-tests--displays-on-line (n)
  "Return the `display' strings of alignment overlays on line N (1-based)."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- n))
    (let (out)
      (dolist (ov (overlays-in (line-beginning-position) (line-end-position)))
        (let ((d (overlay-get ov 'display)))
          (when (and (overlay-get ov 'md-table-align) (stringp d))
            (push (cons (overlay-start ov) d) out))))
      (mapcar #'cdr (sort out :key #'car)))))

(defun md-table-align-tests--own-overlays ()
  "Return this package's overlays only.
`markdown-ts-mode' puts overlays of its own on the buffer from
`post-command-hook', so a bare `overlays-in' is not a stable count."
  (seq-filter (lambda (ov) (overlay-get ov 'md-table-align))
              (overlays-in (point-min) (point-max))))

(defun md-table-align-tests--enable ()
  "Turn on `md-table-align-mode' and let redisplay settle."
  (md-table-align-mode 1)
  (should md-table-align-mode)
  (redisplay t))

;;;; The core question: does it align?

(ert-deftest md-table-align-test-aligns-every-row-to-a-grid ()
  "Pipes in the same column render at the same screen column on every row."
  (md-table-align-tests--with-buffer md-table-align-tests--simple
    (md-table-align-tests--enable)
    (let ((cols (md-table-align-tests--pipe-columns)))
      (should (= (length cols) 4))
      (dolist (row cols)
        (should (equal row md-table-align-tests--simple-columns))))))

(ert-deftest md-table-align-test-unaligned-before-enabling ()
  "The fixture is genuinely ragged, so the test above is not vacuous."
  (md-table-align-tests--with-buffer md-table-align-tests--simple
    (let ((cols (md-table-align-tests--pipe-columns)))
      (should-not (equal (nth 0 cols) (nth 2 cols))))))

;;;; The point of the exercise: no buffer modification

(ert-deftest md-table-align-test-does-not-modify-buffer-text ()
  "Alignment leaves buffer text byte-identical and the buffer unmodified."
  (md-table-align-tests--with-buffer md-table-align-tests--simple
    (let ((before (buffer-substring-no-properties (point-min) (point-max))))
      (md-table-align-tests--enable)
      (should (equal (buffer-substring-no-properties (point-min) (point-max)) before))
      (should-not (buffer-modified-p)))))

(ert-deftest md-table-align-test-works-in-read-only-buffer ()
  "Alignment applies with `buffer-read-only' set, and text stays put."
  (md-table-align-tests--with-buffer md-table-align-tests--simple
    (let ((before (buffer-substring-no-properties (point-min) (point-max))))
      (setq buffer-read-only t)
      (md-table-align-tests--enable)
      (dolist (row (md-table-align-tests--pipe-columns))
        (should (equal row md-table-align-tests--simple-columns)))
      (should buffer-read-only)
      (should-not (buffer-modified-p))
      (should (equal (buffer-substring-no-properties (point-min) (point-max)) before)))))

(ert-deftest md-table-align-test-disabling-restores-layout ()
  "Turning the mode off puts every pipe back where it started."
  (md-table-align-tests--with-buffer md-table-align-tests--simple
    (let ((before (md-table-align-tests--pipe-columns)))
      (md-table-align-tests--enable)
      (should-not (equal (md-table-align-tests--pipe-columns) before))
      (md-table-align-mode -1)
      (redisplay t)
      (should (equal (md-table-align-tests--pipe-columns) before)))))

;;;; Per-column alignment

(ert-deftest md-table-align-test-right-alignment-pads-before-content ()
  "A `---:' column pushes short cells right."
  (md-table-align-tests--with-buffer md-table-align-tests--simple
    (md-table-align-tests--enable)
    ;; Column 1 spans content columns 10-12 (opening pipe 8, one pad, width 3).
    (should (= (md-table-align-tests--column-of "Qty") 10))
    (should (= (md-table-align-tests--column-of "12") 11))
    (should (= (md-table-align-tests--column-of "3") 12))))

(ert-deftest md-table-align-test-left-alignment-pads-after-content ()
  "A `:---' column keeps cells flush left."
  (md-table-align-tests--with-buffer md-table-align-tests--simple
    (md-table-align-tests--enable)
    (should (= (md-table-align-tests--column-of "Name") 2))
    (should (= (md-table-align-tests--column-of "apple") 2))
    (should (= (md-table-align-tests--column-of "fig") 2))))

(ert-deftest md-table-align-test-center-alignment-splits-padding ()
  "A `:--:' column centres short cells."
  (md-table-align-tests--with-buffer "| a | b |
|:-:|:-:|
| xxxxx | y |
"
    (md-table-align-tests--enable)
    ;; Width 5, so \"a\" gets (5-1)/2 = 2 leading pad on top of the 1 base pad.
    (should (= (md-table-align-tests--column-of "a") 4))
    (should (= (md-table-align-tests--column-of "xxxxx") 2))))

(ert-deftest md-table-align-test-delimiter-row-fills-inner-width ()
  "Delimiter dashes are re-rendered to span the whole cell, keeping colons."
  (md-table-align-tests--with-buffer md-table-align-tests--simple
    (md-table-align-tests--enable)
    (should (equal (md-table-align-tests--displays-on-line 2)
                   '(":------" "----:")))))

;;;; Cases text properties could not handle

(ert-deftest md-table-align-test-aligns-cells-with-no-padding ()
  "Cells like `|a|' have no whitespace to stretch, yet still align."
  (md-table-align-tests--with-buffer "|a|bb|
|-|-|
|cccc|d|
"
    (md-table-align-tests--enable)
    ;; Widths 4 and 2, so pipes land at 0, 7 and 12.
    (dolist (row (md-table-align-tests--pipe-columns))
      (should (equal row '(0 7 12))))))

(ert-deftest md-table-align-test-handles-empty-cells ()
  "Empty cells are padded out rather than collapsing the grid."
  (md-table-align-tests--with-buffer "| a | b |
|---|---|
| | long |
"
    (md-table-align-tests--enable)
    ;; Widths 1 and 4, so pipes land at 0, 4 and 11 -- including on the row
    ;; whose first cell is empty and therefore has no tree-sitter node.
    (dolist (row (md-table-align-tests--pipe-columns))
      (should (equal row '(0 4 11))))))

;;;; Width measurement

(ert-deftest md-table-align-test-layout-is-driven-by-measured-width ()
  "Scaling the measurement scales the whole layout by the same factor.

Nothing in the layout may assume one character occupies one unit.  That
assumption is exactly what broke under `mixed-pitch-mode', where the
table face inherits a scaled `:height' and renders ~1.15x wider per
character than the frame's canonical character width, so alignment
computed from character counts drifted by that ratio.

Doubling the width function must double every position; any position
still derived from a character count would stay put and break the grid.

Content rows only.  The delimiter row renders as a run of dash
characters, so its width is quantised to whole characters of the real
font and cannot follow a width function that disagrees with what the
frame actually draws."
  (md-table-align-tests--with-buffer md-table-align-tests--simple
    (let ((md-table-align-pixel-width-function
           (lambda (s) (* 2 (string-width s)))))
      (md-table-align-tests--enable)
      (let ((rows (md-table-align-tests--pipe-columns))
            (expected (mapcar (lambda (c) (* 2 c))
                              md-table-align-tests--simple-columns)))
        ;; Entry 1 is the delimiter row; 0, 2 and 3 carry data.
        (dolist (i '(0 2 3))
          (should (equal (nth i rows) expected)))))))

(ert-deftest md-table-align-test-default-width-function-measures-pixels ()
  "The default width function reports rendered width, not character count."
  (md-table-align-tests--with-buffer md-table-align-tests--simple
    (should (eq md-table-align-pixel-width-function #'md-table-align-pixel-width))
    ;; On a TTY the canonical character width is 1, so pixels and columns
    ;; coincide and this reduces to a character count.
    (should (= (md-table-align-pixel-width "abcd") (* 4 (frame-char-width))))
    (should (= (md-table-align-pixel-width "") 0))))

(ert-deftest md-table-align-test-measures-double-width-characters ()
  "CJK cells are measured by display width, not character count."
  (md-table-align-tests--with-buffer "| ab | x |
|---|---|
| 日本語 | y |
"
    (md-table-align-tests--enable)
    (let ((cols (md-table-align-tests--pipe-columns)))
      ;; \"日本語\" is 3 characters but 6 columns wide; if `length' were used
      ;; the rows would disagree here.
      (should (equal (nth 0 cols) (nth 2 cols)))
      (should (= (nth 1 (nth 0 cols)) 9)))))

;;;; Discovery

(ert-deftest md-table-align-test-ignores-tables-inside-code-fences ()
  "Pipe rows inside a fenced code block are left exactly as written."
  (md-table-align-tests--with-buffer "| Aaaa | B |
|---|---|
| 1 | 2 |

```
| x | yyyy |
|---|-----|
```
"
    (let ((before (md-table-align-tests--pipe-columns)))
      (md-table-align-tests--enable)
      (let ((after (md-table-align-tests--pipe-columns)))
        ;; Entries 3 and 4 of the pipe-line list are the fenced rows.
        (should (equal (nthcdr 3 after) (nthcdr 3 before)))
        ;; ...while the real table above them was put on a grid.
        (should (equal (nth 0 after) (nth 2 after)))
        (should-not (equal (nth 2 after) (nth 2 before)))))))

(ert-deftest md-table-align-test-aligns-multiple-tables-independently ()
  "Each table gets its own column widths."
  (md-table-align-tests--with-buffer "| a | b |
|---|---|
| cc | d |

| wide-header | z |
|---|---|
| q | r |
"
    (md-table-align-tests--enable)
    (let* ((cols (md-table-align-tests--pipe-columns))
           (first (nth 0 cols))
           (second (nth 3 cols)))
      (should (equal first (nth 2 cols)))
      (should (equal second (nth 5 cols)))
      (should-not (equal first second)))))

(ert-deftest md-table-align-test-respects-table-indentation ()
  "An indented table aligns to absolute columns, preserving its indent."
  (md-table-align-tests--with-buffer "- item

  | a | bb |
  |---|---|
  | cccc | d |
"
    (md-table-align-tests--enable)
    (dolist (row (md-table-align-tests--pipe-columns))
      (should (= (car row) 2))
      (should (equal row '(2 9 14))))))

;;;; Reacting to edits

(ert-deftest md-table-align-test-realigns-after-edit ()
  "Widening a cell re-aligns the whole table, without stale overlays."
  (md-table-align-tests--with-buffer md-table-align-tests--simple
    (md-table-align-tests--enable)
    (goto-char (point-min))
    (should (search-forward "fig" nil t))
    (insert "-tree")
    (redisplay t)
    (let ((cols (md-table-align-tests--pipe-columns)))
      ;; "fig-tree" is now the widest cell in column 0.
      (dolist (row cols)
        (should (equal row '(0 11 17)))))))

;;;; Mode plumbing

(ert-deftest md-table-align-test-clear-removes-all-overlays ()
  "`md-table-align-clear' leaves no alignment overlays behind."
  (md-table-align-tests--with-buffer md-table-align-tests--simple
    (md-table-align-tests--enable)
    (md-table-align-clear)
    (should-not (seq-filter (lambda (ov) (overlay-get ov 'md-table-align))
                            (overlays-in (point-min) (point-max))))))

(ert-deftest md-table-align-test-global-mode-enables-in-markdown-buffers ()
  "`global-md-table-align-mode' turns the mode on in Markdown buffers only."
  (let ((md (generate-new-buffer "*md-table-align-global-md*"))
        (other (generate-new-buffer "*md-table-align-global-other*")))
    (unwind-protect
        (progn
          (global-md-table-align-mode 1)
          (with-current-buffer md
            (insert md-table-align-tests--simple)
            (markdown-ts-mode)
            (should md-table-align-mode))
          (with-current-buffer other
            (text-mode)
            (should-not md-table-align-mode)))
      (global-md-table-align-mode -1)
      (kill-buffer md)
      (kill-buffer other))))

(ert-deftest md-table-align-test-loader-puts-extensions-on-load-path ()
  "The collection loader makes each extension directory requirable."
  (require 'emacs-tools)
  (let ((dirs (mapcar #'file-name-nondirectory
                      (mapcar #'directory-file-name
                              (emacs-tools-extension-directories)))))
    (should (member "md-table-align" dirs))
    ;; Directories that hold Lisp but ship nothing must not be mistaken for
    ;; extensions: the suite itself, untracked scratch, and build output.
    (should-not (member ".test-env" dirs))
    (should-not (member "tests" dirs))
    (should-not (member "hacks" dirs))
    (dolist (dir (emacs-tools-extension-directories))
      (should (member dir load-path)))))

(ert-deftest md-table-align-test-refuses-without-parser ()
  "The mode declines to enable where no `markdown' parser exists."
  (let ((buf (generate-new-buffer "*md-table-align-no-parser*")))
    (unwind-protect
        (progn
          (switch-to-buffer buf)
          (insert md-table-align-tests--simple)
          (fundamental-mode)
          (md-table-align-mode 1)
          (should-not md-table-align-mode))
      (kill-buffer buf))))

;;;; Clipping a wide table to the window, and scrolling it
;;
;; A table wider than the window wraps, and a wrapped row is not merely ugly:
;; its continuation lines restart at the window's left edge, so the column grid
;; is gone.  Instead each table is clipped to a horizontal viewport that
;; scrolls.  Narrowing the frame is what makes these assertions bite -- at the
;; default frame width the fixture below fits and nothing is clipped.

(defconst md-table-align-tests--wide
  "prose before the table
| Name | Description | Status |
|------|-------------|--------|
| alpha | first item description here | open |
| beta | second item description | done |
prose after the table
")

;; Aligned, the fixture needs 48 columns: 4 borders, 6 spaces of padding, and
;; content of 5 (\"alpha\"), 27 (\"first item description here\") and 6
;; (\"Status\").  Its grid therefore puts pipes at columns 0, 8, 38 and 47.
;; Every test below runs it in a 40-column frame.
(defconst md-table-align-tests--wide-frame 40)

(defmacro md-table-align-tests--with-frame-width (width &rest body)
  "Run BODY with the frame WIDTH columns wide, then restore it."
  (declare (indent 1) (debug t))
  `(let ((original (frame-width)))
     (unwind-protect
         (progn (set-frame-width nil ,width) (redisplay t) ,@body)
       (set-frame-width nil original)
       (redisplay t))))

(defun md-table-align-tests--screen-lines ()
  "Return the screen lines occupied by each line holding a pipe."
  (save-excursion
    (goto-char (point-min))
    (let (out)
      (while (not (eobp))
        (when (save-excursion (search-forward "|" (line-end-position) t))
          (push (count-screen-lines (line-beginning-position)
                                    (line-end-position))
                out))
        (forward-line 1))
      (nreverse out))))

(defun md-table-align-tests--clipped-p (pos)
  "Return non-nil when POS is inside text the viewport has clipped away."
  (seq-some (lambda (ov) (overlay-get ov 'md-table-align-clip))
            (overlays-at pos)))

(defun md-table-align-tests--clips ()
  "Return the text of every clipped span, in buffer order."
  (let (out)
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (overlay-get ov 'md-table-align-clip)
        (push (cons (overlay-start ov) (overlay-get ov 'help-echo)) out)))
    (mapcar #'cdr (sort out :key #'car))))

(defun md-table-align-tests--visible-pipe-columns ()
  "Return the rendered columns of the pipes still on screen, one list per row.
Pipes inside a clipped span are left out: they all collapse onto the
start of the overlay hiding them and carry no positional information."
  (save-excursion
    (goto-char (point-min))
    (let (rows)
      (while (not (eobp))
        (let* ((eol (line-end-position))
               ;; Asked before the loop below consumes every pipe on the line:
               ;; a row whose pipes are all clipped still counts as a row.
               (pipe-row (save-excursion (search-forward "|" eol t)))
               (cols nil))
          (while (search-forward "|" eol t)
            (unless (md-table-align-tests--clipped-p (1- (point)))
              (push (md-table-align-tests--column (1- (point))) cols)))
          (when pipe-row (push (nreverse cols) rows)))
        (forward-line 1))
      (nreverse rows))))

(defun md-table-align-tests--goto-table ()
  "Put point on the first pipe of the table."
  (goto-char (point-min))
  (should (search-forward "|" nil t))
  (goto-char (match-beginning 0)))

(defun md-table-align-tests--scroll (columns)
  "Scroll the table at point COLUMNS to the left, then let redisplay settle."
  (md-table-align-tests--goto-table)
  (md-table-align-hscroll-left columns)
  (redisplay t))

(ert-deftest md-table-align-test-wide-table-wraps-without-scrolling ()
  "The fixture really does overflow, so the clipping tests are not vacuous."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (let ((md-table-align-hscroll nil))
        (md-table-align-tests--enable)
        (should (seq-some (lambda (n) (> n 1))
                          (md-table-align-tests--screen-lines)))))))

(ert-deftest md-table-align-test-clipping-keeps-rows-on-one-screen-line ()
  "Every row of an overflowing table occupies exactly one screen line."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (should (equal (md-table-align-tests--screen-lines) '(1 1 1 1))))))

(ert-deftest md-table-align-test-rows-stay-on-one-line-at-every-offset ()
  "Scrolling must not reintroduce the wrapping clipping exists to prevent."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (dolist (offset '(1 5 10 20 40))
        (md-table-align-tests--goto-table)
        (md-table-align-hscroll-reset)
        (md-table-align-tests--scroll offset)
        (should (equal (md-table-align-tests--screen-lines) '(1 1 1 1)))))))

(ert-deftest md-table-align-test-clipped-table-is-still-aligned ()
  "Clipping must not cost the alignment it exists to protect."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (let ((rows (md-table-align-tests--visible-pipe-columns)))
        (should (= (length rows) 4))
        (dolist (row rows)
          (should (equal row (car rows))))))))

(ert-deftest md-table-align-test-rows-agree-at-every-offset ()
  "At any offset, every row agrees on where each visible pipe renders.

This is the assertion that catches deriving the scroll position from
buffer columns rather than from the aligned grid: cells differ in length,
so the same buffer column is a different grid column on every row, and
the columns drift apart as soon as the offset is not zero."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (dolist (offset '(1 3 5 8 10))
        (md-table-align-tests--goto-table)
        (md-table-align-hscroll-reset)
        (md-table-align-tests--scroll offset)
        (let ((rows (md-table-align-tests--visible-pipe-columns)))
          (should (= (length rows) 4))
          (dolist (row rows)
            (should (equal row (car rows)))))))))

(ert-deftest md-table-align-test-scrolling-shifts-the-grid ()
  "The visible pipes are the table's own grid, shifted by the offset.

The fixture's grid puts pipes at 0, 8, 38 and 47.  In a 40-column frame
the viewport is 38 wide once a column is held back for the wrap glyph and
one for the trailing indicator, so the pipe at 38 falls exactly on its
edge and is excluded.

Scrolling two columns shifts everything left by two and spends one column
on the leading indicator, a net shift of one: 8 and 38 render at 7 and
37.  The pipe at 38 becomes visible in the process -- the viewport is one
wider than at offset zero, because there is no longer a trailing
indicator competing for the room."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (should (equal (car (md-table-align-tests--visible-pipe-columns))
                     '(0 8)))
      (md-table-align-tests--scroll 2)
      (should (equal (car (md-table-align-tests--visible-pipe-columns))
                     '(7 37))))))

(ert-deftest md-table-align-test-scrolling-reveals-the-last-column ()
  "Scrolling far enough brings the rightmost column into view.
This is the whole point of the feature: with fitting, the tail of a wide
table could not be reached at all."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (goto-char (point-min))
      (should (search-forward "open" nil t))
      (should (md-table-align-tests--clipped-p (match-beginning 0)))
      ;; Far more than the table is wide; the offset clamps to its edge.
      (md-table-align-tests--scroll 200)
      (goto-char (point-min))
      (should (search-forward "open" nil t))
      (should-not (md-table-align-tests--clipped-p (match-beginning 0))))))

(ert-deftest md-table-align-test-scrolling-back-restores-the-left-edge ()
  "Scrolling right undoes scrolling left, ending at offset zero."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (let ((before (md-table-align-tests--visible-pipe-columns)))
        (md-table-align-tests--scroll 6)
        (should-not (equal (md-table-align-tests--visible-pipe-columns) before))
        (md-table-align-tests--goto-table)
        (md-table-align-hscroll-right 6)
        (redisplay t)
        (should (equal (md-table-align-tests--visible-pipe-columns) before))))))

(ert-deftest md-table-align-test-clipped-text-stays-readable ()
  "Clip overlays carry the hidden text for `display-local-help'."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (goto-char (point-min))
      (should (search-forward "open" nil t))
      (let ((help (get-char-property (match-beginning 0) 'help-echo)))
        (should help)
        (should (string-search "open" help))))))

(ert-deftest md-table-align-test-prose-is-untouched-by-scrolling ()
  "Only table rows are clipped, so surrounding prose never moves.
Native `hscroll' cannot do this: it shifts the whole window, and needs
`truncate-lines' to work at all."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (dolist (offset '(0 5 10))
        (md-table-align-tests--goto-table)
        (md-table-align-hscroll-reset)
        (when (> offset 0) (md-table-align-tests--scroll offset))
        (dolist (text '("prose before the table" "prose after the table"))
          (should (= (md-table-align-tests--column-of text) 0)))))))

(ert-deftest md-table-align-test-point-is-never-inside-clipped-text ()
  "Moving point into a scrolled-off cell brings the viewport to it.

Not a nicety: text hidden by a `display' overlay collapses point onto the
overlay's start, so without this the cursor would sit where nothing is
rendered."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (goto-char (point-min))
      (should (search-forward "open" nil t))
      (goto-char (match-beginning 0))
      (should (md-table-align-tests--clipped-p (point)))
      ;; What `post-command-hook' runs after any command that moves point.
      (md-table-align--follow-point)
      (redisplay t)
      (should-not (md-table-align-tests--clipped-p (point))))))

(ert-deftest md-table-align-test-leaving-a-table-resets-its-offset ()
  "A table left scrolled would be one whose first columns are just missing."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (let ((before (md-table-align-tests--visible-pipe-columns)))
        (md-table-align-tests--scroll 6)
        (should-not (equal (md-table-align-tests--visible-pipe-columns) before))
        (goto-char (point-min))
        (md-table-align--follow-point)
        (redisplay t)
        (should (equal (md-table-align-tests--visible-pipe-columns) before))))))

(ert-deftest md-table-align-test-clipping-does-not-modify-buffer-text ()
  "Clipping is display-only, like every other overlay here."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (let ((before (buffer-substring-no-properties (point-min) (point-max))))
        (md-table-align-tests--enable)
        (md-table-align-tests--scroll 6)
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       before))
        (should-not (buffer-modified-p))))))

(ert-deftest md-table-align-test-table-that-fits-is-not-clipped ()
  "A table with room to spare is left entirely alone."
  (md-table-align-tests--with-buffer md-table-align-tests--simple
    (md-table-align-tests--enable)
    (should-not (md-table-align-tests--clips))
    (dolist (row (md-table-align-tests--pipe-columns))
      (should (equal row md-table-align-tests--simple-columns)))))

(ert-deftest md-table-align-test-table-that-fits-does-not-scroll ()
  "There is nothing off screen to scroll to, so the command does nothing."
  (md-table-align-tests--with-buffer md-table-align-tests--simple
    (md-table-align-tests--enable)
    (md-table-align-tests--scroll 5)
    (should-not (md-table-align-tests--clips))
    (dolist (row (md-table-align-tests--pipe-columns))
      (should (equal row md-table-align-tests--simple-columns)))))

(ert-deftest md-table-align-test-widening-the-frame-restores-the-table ()
  "Growing the window past the table's width clears the clipping."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (should (md-table-align-tests--clips))
      (set-frame-width nil 100)
      ;; `set-frame-width' runs the window-change hooks the mode listens on.
      (redisplay t)
      (should-not (md-table-align-tests--clips))
      (should (equal (md-table-align-tests--screen-lines) '(1 1 1 1))))))

(ert-deftest md-table-align-test-widening-clamps-a-scroll-offset ()
  "An offset outlives a resize only as far as the wider window allows."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (md-table-align-tests--scroll 8)
      (set-frame-width nil 100)
      (redisplay t)
      (should-not (md-table-align-tests--clips))
      (dolist (row (md-table-align-tests--visible-pipe-columns))
        (should (equal row '(0 8 38 47)))))))

(ert-deftest md-table-align-test-narrow-window-still-shows-one-line-rows ()
  "A window far too narrow for the columns clips rather than mangles.
Where fitting gave up and let the table wrap, scrolling has no floor to
hit: there is always a viewport, however little of the table it holds."
  (md-table-align-tests--with-frame-width 16
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (should (md-table-align-tests--clips))
      (should (equal (md-table-align-tests--screen-lines) '(1 1 1 1))))))

(provide 'md-table-align-tests)

;;; md-table-align-tests.el ends here

;;;; Buffers that mark text read-only with a text property
;;
;; A chat or transcript UI locks down what it has already printed with a
;; `read-only' text property rather than `buffer-read-only'.  That property
;; rides along on `buffer-substring', and `string-pixel-width' measures by
;; inserting into a work buffer -- where read-only text signals
;; `text-read-only'.  Measurement is the foundation everything else stands on,
;; so this took out alignment, clipping and scrolling together.

(defmacro md-table-align-tests--with-read-only-text (text &rest body)
  "Run BODY over TEXT with every character carrying a `read-only' property."
  (declare (indent 1) (debug t))
  `(md-table-align-tests--with-buffer ,text
     (let ((inhibit-read-only t))
       (put-text-property (point-min) (point-max) 'read-only t))
     ;; Applying the property is itself a modification; the fixture's own
     ;; setup must not be what a `buffer-modified-p' assertion sees.
     (set-buffer-modified-p nil)
     ,@body))

(ert-deftest md-table-align-test-measures-read-only-text ()
  "Measurement survives a `read-only' text property on the cell text.
The narrowest statement of the bug: `string-pixel-width' signals on such
a string, and every other failure here follows from that one."
  (md-table-align-tests--with-read-only-text md-table-align-tests--simple
    (goto-char (point-min))
    (should (numberp (md-table-align--measure (line-beginning-position)
                                              (line-end-position))))))

(ert-deftest md-table-align-test-aligns-read-only-text ()
  "Alignment applies to text carrying a `read-only' property."
  (md-table-align-tests--with-read-only-text md-table-align-tests--simple
    (md-table-align-tests--enable)
    (dolist (row (md-table-align-tests--pipe-columns))
      (should (equal row md-table-align-tests--simple-columns)))))

(ert-deftest md-table-align-test-clips-read-only-text ()
  "A wide table of read-only text is still clipped to one screen line each."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-read-only-text md-table-align-tests--wide
      (md-table-align-tests--enable)
      (should (md-table-align-tests--clips))
      (should (equal (md-table-align-tests--screen-lines) '(1 1 1 1))))))

(ert-deftest md-table-align-test-scrolls-read-only-text ()
  "Point-following scrolls a table whose text is read-only."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-read-only-text md-table-align-tests--wide
      (md-table-align-tests--enable)
      (goto-char (point-min))
      (should (search-forward "open" nil t))
      (goto-char (match-beginning 0))
      (should (md-table-align-tests--clipped-p (point)))
      (md-table-align--follow-point)
      (redisplay t)
      (should-not (md-table-align-tests--clipped-p (point))))))

(ert-deftest md-table-align-test-read-only-text-is-not-modified ()
  "The property is stripped from the measured copy, never from the buffer."
  (md-table-align-tests--with-read-only-text md-table-align-tests--simple
    (md-table-align-tests--enable)
    (should (get-text-property (point-min) 'read-only))
    (should-not (buffer-modified-p))))

;;;; Point-following must not uninstall itself
;;
;; Emacs removes a `post-command-hook' function that signals.  A failure
;; anywhere in layout would therefore disable point-following for the rest of
;; the session, in every buffer, rather than for the one command that failed.

(ert-deftest md-table-align-test-follow-point-survives-an-error ()
  "A signal from layout is caught, so the hook keeps its handler."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (md-table-align-tests--goto-table)
      (let ((md-table-align-pixel-width-function
             (lambda (_s) (signal 'text-read-only nil))))
        (setq md-table-align--metrics-cache nil)
        ;; Must not signal out to the command loop.
        (md-table-align--post-command))
      (should (memq #'md-table-align--post-command post-command-hook)))))

(ert-deftest md-table-align-test-follow-point-recovers-after-an-error ()
  "Once the cause is gone, scrolling works again without re-enabling."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (md-table-align-tests--goto-table)
      (let ((md-table-align-pixel-width-function
             (lambda (_s) (signal 'text-read-only nil))))
        (setq md-table-align--metrics-cache nil)
        (md-table-align--post-command))
      (setq md-table-align--metrics-cache nil)
      (goto-char (point-min))
      (should (search-forward "open" nil t))
      (goto-char (match-beginning 0))
      (md-table-align--follow-point)
      (redisplay t)
      (should-not (md-table-align-tests--clipped-p (point))))))

;;;; Scrolling through the real command loop
;;
;; `md-table-align-tests--scroll' calls the command as a plain function, so
;; `post-command-hook' never runs -- and point-following, which runs there, is
;; exactly what can undo an explicit scroll.  These drive real key events.

(defun md-table-align-tests--press (keys)
  "Execute KEYS as real key events, then let redisplay settle."
  (execute-kbd-macro (kbd keys))
  (redisplay t))

(ert-deftest md-table-align-test-scroll-key-survives-the-command-loop ()
  "\\[scroll-left] shifts the grid and the shift is still there afterwards.

Point-following runs after the command and must not undo it.  It will if
the scroll leaves point on the viewport's edge, since that is inside
`hscroll-margin' and asks to be scrolled back."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (md-table-align-tests--goto-table)
      (should (equal (car (md-table-align-tests--visible-pipe-columns)) '(0 8)))
      (md-table-align-tests--press "C-x <")
      (should (> md-table-align--hscroll 0))
      (should-not (equal (car (md-table-align-tests--visible-pipe-columns))
                         '(0 8))))))

(ert-deftest md-table-align-test-scroll-key-reaches-the-last-column ()
  "Repeated \\[scroll-left] walks the viewport to the table's right edge."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (md-table-align-tests--goto-table)
      (should (md-table-align-tests--clipped-p
               (progn (goto-char (point-min))
                      (search-forward "Status")
                      (match-beginning 0))))
      (md-table-align-tests--goto-table)
      (dotimes (_ 6) (md-table-align-tests--press "C-x <"))
      (goto-char (point-min))
      (should (search-forward "Status" nil t))
      (should-not (md-table-align-tests--clipped-p (match-beginning 0))))))

(ert-deftest md-table-align-test-scroll-key-returns-to-the-left-edge ()
  "\\[scroll-right] walks the viewport back, and the grid is as it started."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (md-table-align-tests--goto-table)
      (let ((before (car (md-table-align-tests--visible-pipe-columns))))
        (dotimes (_ 3) (md-table-align-tests--press "C-x <"))
        (should (> md-table-align--hscroll 0))
        (dotimes (_ 6) (md-table-align-tests--press "C-x >"))
        (should (= md-table-align--hscroll 0))
        (should (equal (car (md-table-align-tests--visible-pipe-columns))
                       before))))))

(ert-deftest md-table-align-test-scroll-key-scrolls-read-only-text ()
  "The two fixes meet: explicit scrolling over `read-only' text."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-read-only-text md-table-align-tests--wide
      (md-table-align-tests--enable)
      (md-table-align-tests--goto-table)
      (md-table-align-tests--press "C-x <")
      (should (> md-table-align--hscroll 0))
      (should (memq #'md-table-align--post-command post-command-hook)))))

;;;; Vertical records view
;;
;; `md-table-align-toggle-vertical' renders a table as psql's `\x' expanded
;; display: one `label | value' line per cell, one record block per data row.
;; The values are real buffer text; the labels, pipes and record separators
;; are overlay strings.  Rendered, the fixture below reads:
;;
;;     before                    <- row 0
;;     -[ row 1 ]---
;;     a    | value1             <- values at column 8: widest label "bee"
;;     bee  | v2                    is 3 wide, plus the default two-space
;;     c    | value3                gap on each side of the pipe
;;     -[ row 2 ]---
;;     a    | v4
;;     bee  | value5
;;     c    | v6
;;     after                     <- row 9
;;
;; so the header and delimiter lines contribute no screen lines at all.

(defconst md-table-align-tests--vertical
  "before
| a | bee | c |
|---|-----|---|
| value1 | v2 | value3 |
| v4 | value5 | v6 |
after
")

(defconst md-table-align-tests--vertical-value-column 8)

;; Toggled back, the fixture's grid: column widths 6, 6 and 6, so pipes at
;; 0, 9, 18 and 27 on every row.
(defconst md-table-align-tests--vertical-grid '(0 9 18 27))

(defun md-table-align-tests--row (pos)
  "Return the screen row at which buffer position POS is rendered."
  (let ((posn (posn-at-point pos)))
    (should posn)
    (cdr (posn-col-row posn))))

(defun md-table-align-tests--row-of (string)
  "Return the rendered screen row of the first occurrence of STRING."
  (save-excursion
    (goto-char (point-min))
    (should (search-forward string nil t))
    (md-table-align-tests--row (match-beginning 0))))

(defun md-table-align-tests--toggle-vertical ()
  "Toggle the first table vertical and let redisplay settle."
  (md-table-align-tests--goto-table)
  (md-table-align-toggle-vertical)
  (redisplay t))

(ert-deftest md-table-align-test-vertical-stacks-fields-on-aligned-lines ()
  "Each value renders on its own screen line, at the common value column."
  (md-table-align-tests--with-buffer md-table-align-tests--vertical
    (md-table-align-tests--enable)
    (md-table-align-tests--toggle-vertical)
    (let ((base (md-table-align-tests--row-of "value1")))
      (dolist (value '("value1" "v2" "value3" "v4" "value5" "v6"))
        (should (= (md-table-align-tests--column-of value)
                   md-table-align-tests--vertical-value-column)))
      ;; Consecutive lines within a record; the next record one further on,
      ;; past its separator line.
      (should (= (md-table-align-tests--row-of "v2") (+ base 1)))
      (should (= (md-table-align-tests--row-of "value3") (+ base 2)))
      (should (= (md-table-align-tests--row-of "v4") (+ base 4))))))

(ert-deftest md-table-align-test-vertical-gap-follows-the-option ()
  "`md-table-align-vertical-pipe-gap' sets the space on each side of the pipe."
  (md-table-align-tests--with-buffer md-table-align-tests--vertical
    (md-table-align-tests--enable)
    (let ((md-table-align-vertical-pipe-gap 4))
      (md-table-align-tests--toggle-vertical)
      (dolist (value '("value1" "v2" "value3"))
        ;; "bee" is 3 wide; 4 of gap, the pipe, and 4 more puts every value
        ;; at column 12 -- per side, not the old label-to-value span.
        (should (= (md-table-align-tests--column-of value) 12))))))

(ert-deftest md-table-align-test-vertical-separator-is-a-pipe ()
  "Label lines read `label | value': a pipe, no colon, before each value.
The pipe rides in the injected `before-string', which `posn-at-point'
cannot address, so the column tests cover its geometry and this one its
content."
  (md-table-align-tests--with-buffer md-table-align-tests--vertical
    (md-table-align-tests--enable)
    (md-table-align-tests--toggle-vertical)
    (goto-char (point-min))
    (should (search-forward "value1" nil t))
    (let* ((beg (match-beginning 0))
           (ov (seq-find (lambda (o) (and (overlay-get o 'md-table-align)
                                          (= (overlay-end o) beg)
                                          (overlay-get o 'before-string)))
                         (overlays-in (point-min) beg))))
      (should ov)
      (let ((injected (overlay-get ov 'before-string)))
        ;; The label "a", then the pipe, and nowhere a colon.
        (should (string-match-p "a.*|" injected))
        (should-not (string-search ":" injected))))))

;; A long value under `visual-line-mode' wraps; its continuation lines must
;; continue at the value column, under an extra pipe on the rail, rather
;; than restart at the window edge.  Labels "k" and "data": widest label 4,
;; so with the default gap the pipe is at column 6 and values at column 9.
(defconst md-table-align-tests--vertical-wrapping
  "| k | data |
|---|------|
| one | alpha bravo charlie delta echo foxtrot golf hotel india juliet |
")

(ert-deftest md-table-align-test-vertical-wrapped-value-continues-at-the-value-column ()
  "Visual-line continuation lines of a long value start at the value column."
  (md-table-align-tests--with-buffer md-table-align-tests--vertical-wrapping
    (md-table-align-tests--enable)
    (visual-line-mode 1)
    (md-table-align-tests--with-frame-width 40
      (md-table-align-tests--toggle-vertical)
      (let ((first-row (md-table-align-tests--row-of "alpha"))
            (rows (make-hash-table)))
        ;; Only a continuation line's first word sits at the value column;
        ;; collect each row's leftmost word and check that.
        (dolist (word '("bravo" "charlie" "delta" "echo" "foxtrot"
                        "golf" "hotel" "india" "juliet"))
          (let ((row (md-table-align-tests--row-of word))
                (col (md-table-align-tests--column-of word)))
            (if (= row first-row)
                (should (> col 9))
              (should (> row first-row))
              (puthash row (min col (gethash row rows most-positive-fixnum))
                       rows))))
        (should (> (hash-table-count rows) 0))
        (maphash (lambda (_row leftmost) (should (= leftmost 9))) rows)))))

(ert-deftest md-table-align-test-vertical-wrap-prefix-carries-the-rail-pipe ()
  "Each value's overlay holds a `wrap-prefix' with the pipe on the rail.
The prefix renders only on wrapped lines, where `posn-at-point' cannot
address it, so the column test above covers its geometry and this one
its content."
  (md-table-align-tests--with-buffer md-table-align-tests--vertical
    (md-table-align-tests--enable)
    (md-table-align-tests--toggle-vertical)
    (goto-char (point-min))
    (should (search-forward "value1" nil t))
    (let* ((beg (match-beginning 0))
           (ov (seq-find (lambda (o) (and (overlay-get o 'md-table-align)
                                          (overlay-get o 'wrap-prefix)))
                         (overlays-at beg))))
      (should ov)
      (should (= (overlay-end ov) (match-end 0)))
      (should (string-search "|" (overlay-get ov 'wrap-prefix))))))

(ert-deftest md-table-align-test-vertical-data-row-occupies-fields-plus-separator ()
  "A three-column row renders as four screen lines: separator plus fields."
  (md-table-align-tests--with-buffer md-table-align-tests--vertical
    (md-table-align-tests--enable)
    (md-table-align-tests--toggle-vertical)
    (goto-char (point-min))
    (should (search-forward "value1" nil t))
    (should (= (count-screen-lines (line-beginning-position)
                                   (line-end-position))
               4))))

(ert-deftest md-table-align-test-vertical-hides-header-and-delimiter ()
  "The header and delimiter lines contribute no screen lines.
Ten buffer lines of which two are hidden and each data row grows by
three: `after' lands nine rows under `before'."
  (md-table-align-tests--with-buffer md-table-align-tests--vertical
    (md-table-align-tests--enable)
    (md-table-align-tests--toggle-vertical)
    (let ((base (md-table-align-tests--row-of "before")))
      (should (= (md-table-align-tests--row-of "value1") (+ base 2)))
      (should (= (md-table-align-tests--row-of "after") (+ base 9))))))

(ert-deftest md-table-align-test-vertical-does-not-modify-buffer-text ()
  "The vertical view is a rendering; the text is byte-identical."
  (md-table-align-tests--with-buffer md-table-align-tests--vertical
    (let ((before (buffer-substring-no-properties (point-min) (point-max))))
      (md-table-align-tests--enable)
      (md-table-align-tests--toggle-vertical)
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     before))
      (should-not (buffer-modified-p)))))

(ert-deftest md-table-align-test-vertical-toggles-back-to-the-grid ()
  "Toggling twice restores the horizontal grid exactly."
  (md-table-align-tests--with-buffer md-table-align-tests--vertical
    (md-table-align-tests--enable)
    (md-table-align-tests--toggle-vertical)
    (should-not (equal (car (md-table-align-tests--pipe-columns))
                       md-table-align-tests--vertical-grid))
    (md-table-align-tests--toggle-vertical)
    (let ((rows (md-table-align-tests--pipe-columns)))
      (should (= (length rows) 4))
      (dolist (row rows)
        (should (equal row md-table-align-tests--vertical-grid))))))

(ert-deftest md-table-align-test-vertical-survives-an-edit ()
  "jit-lock re-layout after an edit keeps the table vertical."
  (md-table-align-tests--with-buffer md-table-align-tests--vertical
    (md-table-align-tests--enable)
    (md-table-align-tests--toggle-vertical)
    (goto-char (point-min))
    (should (search-forward "v2" nil t))
    (insert "-longer")
    (redisplay t)
    (should (= (md-table-align-tests--column-of "v2-longer")
               md-table-align-tests--vertical-value-column))
    (should (= (md-table-align-tests--row-of "v2-longer")
               (1+ (md-table-align-tests--row-of "value1"))))))

(ert-deftest md-table-align-test-vertical-is-per-table ()
  "Toggling one table leaves the other on its horizontal grid."
  (md-table-align-tests--with-buffer "| a | b |
|---|---|
| x | y |

| c | d |
|---|---|
| p | q |
"
    (md-table-align-tests--enable)
    (md-table-align-tests--toggle-vertical)
    ;; First table vertical: labels \"a\" and \"b\" are 1 wide, then the
    ;; default two-space gap, the pipe and the gap again put the values at
    ;; column 6.
    (should (= (md-table-align-tests--column-of "x") 6))
    (should (= (md-table-align-tests--row-of "y")
               (1+ (md-table-align-tests--row-of "x"))))
    ;; Second table untouched, on its own grid.
    (save-excursion
      (goto-char (point-min))
      (should (search-forward "| c" nil t))
      (let ((start (match-beginning 0)))
        (dotimes (line 3)
          (goto-char start)
          (forward-line line)
          (let ((eol (line-end-position))
                (cols nil))
            (while (search-forward "|" eol t)
              (push (md-table-align-tests--column (1- (point))) cols))
            (should (equal (nreverse cols) '(0 4 8)))))))))

(ert-deftest md-table-align-test-vertical-works-over-read-only-text ()
  "The toggle is display-only, so a `read-only' text property is no bar."
  (md-table-align-tests--with-read-only-text md-table-align-tests--vertical
    (md-table-align-tests--enable)
    (md-table-align-tests--toggle-vertical)
    (should (= (md-table-align-tests--column-of "value1")
               md-table-align-tests--vertical-value-column))
    (should (= (md-table-align-tests--row-of "v2")
               (1+ (md-table-align-tests--row-of "value1"))))
    (should-not (buffer-modified-p))))

(ert-deftest md-table-align-test-vertical-labels-carry-the-label-face ()
  "The synthesized labels render in `md-table-align-vertical-label'."
  (md-table-align-tests--with-buffer md-table-align-tests--vertical
    (md-table-align-tests--enable)
    (md-table-align-tests--toggle-vertical)
    (let ((label
           (catch 'found
             (dolist (ov (md-table-align-tests--own-overlays))
               (let ((d (overlay-get ov 'before-string)))
                 (when (and (stringp d) (string-search "bee" d))
                   (throw 'found d)))))))
      (should label)
      (should (eq (get-text-property (string-search "bee" label) 'face label)
                  'md-table-align-vertical-label)))))

(ert-deftest md-table-align-test-vertical-record-separators-are-rendered ()
  "Each record block sits under a separator built from the record format."
  (md-table-align-tests--with-buffer md-table-align-tests--vertical
    (md-table-align-tests--enable)
    (md-table-align-tests--toggle-vertical)
    (let ((seps (seq-filter
                 (lambda (d) (and (stringp d) (string-search "-[ row " d)))
                 (mapcar (lambda (ov) (overlay-get ov 'before-string))
                         (md-table-align-tests--own-overlays)))))
      (should (= (length seps) 2))
      (should (seq-some (lambda (d) (string-search "-[ row 1 ]---" d)) seps))
      (should (seq-some (lambda (d) (string-search "-[ row 2 ]---" d)) seps)))))

(ert-deftest md-table-align-test-vertical-table-has-no-viewport ()
  "A wide table toggled vertical is neither clipped nor scrollable."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (should (md-table-align-tests--clips))
      (md-table-align-tests--toggle-vertical)
      (should-not (md-table-align-tests--clips))
      ;; The scroll key falls through to `scroll-left' instead of scrolling
      ;; a viewport that no longer exists.
      (md-table-align-tests--goto-table)
      (md-table-align-tests--press "C-x <")
      (should (= md-table-align--hscroll 0)))))

(ert-deftest md-table-align-test-vertical-survives-the-command-loop ()
  "Cursor motion through a vertical table leaves the upkeep hook healthy."
  (md-table-align-tests--with-buffer md-table-align-tests--vertical
    (md-table-align-tests--enable)
    (md-table-align-tests--toggle-vertical)
    (goto-char (point-min))
    (dotimes (_ 5) (md-table-align-tests--press "C-n"))
    (should (memq #'md-table-align--post-command post-command-hook))
    (should-not md-table-align--follow-failed)
    (should (= (md-table-align-tests--column-of "value1")
               md-table-align-tests--vertical-value-column))))

(ert-deftest md-table-align-test-vertical-toggle-outside-a-table-errors ()
  "With point on prose there is nothing to toggle."
  (md-table-align-tests--with-buffer md-table-align-tests--vertical
    (md-table-align-tests--enable)
    (goto-char (point-min))
    (should-error (md-table-align-toggle-vertical) :type 'user-error)))

(ert-deftest md-table-align-test-vertical-toggle-enables-the-mode ()
  "Toggling in a buffer without the mode switches it on first."
  (md-table-align-tests--with-buffer md-table-align-tests--vertical
    (should-not md-table-align-mode)
    (md-table-align-tests--toggle-vertical)
    (should md-table-align-mode)
    (should (= (md-table-align-tests--column-of "value1")
               md-table-align-tests--vertical-value-column))))

;;;; Face remapping arriving after layout
;;
;; `mixed-pitch-mode' switched on *after* this mode used to leave a misaligned
;; table: measurement was right, but `:align-to' targets are frozen at layout
;; time and nothing invalidated them when every glyph changed width.
;;
;; A TTY renders every character one column wide, so a real proportional font
;; cannot be exercised here.  The remapping is real -- `variable-pitch-mode',
;; which is what `mixed-pitch-mode' does to the default face -- and so is
;; everything downstream; only the font metrics are stood in for, through the
;; documented `md-table-align-pixel-width-function' extension point rather than
;; by stubbing anything internal.

(defun md-table-align-tests--pitch-width (string)
  "Measure STRING as a proportional font would, once a remapping is in force.
Widths become content-dependent, so a stale grid shows up as rows
disagreeing rather than merely shifting together."
  (if (string-empty-p string)
      0
    (+ (string-pixel-width string (current-buffer))
       (if face-remapping-alist
           (seq-count (lambda (c) (memq c '(?a ?e ?i ?o ?u))) string)
         0))))

(defmacro md-table-align-tests--with-pitch (text &rest body)
  "Run BODY over TEXT with remapping-sensitive width measurement."
  (declare (indent 1) (debug t))
  `(md-table-align-tests--with-buffer ,text
     (setq-local md-table-align-pixel-width-function
                 #'md-table-align-tests--pitch-width)
     ,@body))

(defun md-table-align-tests--data-rows ()
  "Return the pipe columns of the header and body rows.
The delimiter row is excluded: it is a run of dashes and character-quantised
by design, so it is not expected to land on the pixel grid exactly."
  (let ((rows (md-table-align-tests--pipe-columns)))
    (cons (car rows) (cddr rows))))

(ert-deftest md-table-align-test-remapping-first-is-the-reference ()
  "Remapping before the mode gives a grid every row agrees on."
  (md-table-align-tests--with-pitch md-table-align-tests--simple
    (variable-pitch-mode 1)
    (md-table-align-tests--enable)
    (let ((rows (md-table-align-tests--data-rows)))
      (dolist (row rows)
        (should (equal row (car rows)))))))

(ert-deftest md-table-align-test-remapping-after-layout-realigns ()
  "The mode before the remapping ends up at the same grid as the reference.

This is the ordering bug: `mixed-pitch-mode' switched on afterwards used
to leave the table laid out for the old font."
  (let (reference)
    (md-table-align-tests--with-pitch md-table-align-tests--simple
      (variable-pitch-mode 1)
      (md-table-align-tests--enable)
      (setq reference (md-table-align-tests--data-rows)))
    (md-table-align-tests--with-pitch md-table-align-tests--simple
      (md-table-align-tests--enable)
      (variable-pitch-mode 1)
      ;; What the command loop runs after `M-x variable-pitch-mode'.
      (md-table-align--post-command)
      (redisplay t)
      (should (equal (md-table-align-tests--data-rows) reference)))))

(ert-deftest md-table-align-test-remapping-after-layout-is-not-vacuous ()
  "Without the re-fit the two orders genuinely disagree.
Guards the test above: if the stand-in font made no difference, it would
pass whether or not anything was invalidated."
  (let (reference)
    (md-table-align-tests--with-pitch md-table-align-tests--simple
      (variable-pitch-mode 1)
      (md-table-align-tests--enable)
      (setq reference (md-table-align-tests--data-rows)))
    (md-table-align-tests--with-pitch md-table-align-tests--simple
      (md-table-align-tests--enable)
      (variable-pitch-mode 1)
      (redisplay t)
      ;; No re-fit has run yet, so the layout is still the unremapped one.
      (should-not (equal (md-table-align-tests--data-rows) reference)))))

(ert-deftest md-table-align-test-remapping-realigns-through-the-command-loop ()
  "A real command after the remapping is enough; no manual call needed."
  (md-table-align-tests--with-pitch md-table-align-tests--simple
    (md-table-align-tests--enable)
    (let ((before (md-table-align-tests--data-rows)))
      (variable-pitch-mode 1)
      (md-table-align-tests--press "C-n")
      (should-not (equal (md-table-align-tests--data-rows) before)))))

(ert-deftest md-table-align-test-unchanged-remapping-does-not-refit ()
  "The guard holds: a command that changes nothing re-lays out nothing."
  (md-table-align-tests--with-pitch md-table-align-tests--simple
    (md-table-align-tests--enable)
    (let ((key md-table-align--layout-key)
          (overlays (md-table-align-tests--own-overlays)))
      (should overlays)
      (md-table-align-tests--press "C-n")
      (should (equal md-table-align--layout-key key))
      ;; The same overlay *objects*, not merely an equal-looking layout: a
      ;; re-fit deletes them and builds new ones.  Compared as a set, since
      ;; `overlays-in' does not promise an order and ties on `overlay-start'
      ;; make any sort of it unstable.
      (let ((after (md-table-align-tests--own-overlays)))
        (should (= (length after) (length overlays)))
        (dolist (ov overlays)
          (should (memq ov after)))))))

(ert-deftest md-table-align-test-remapping-refits-with-hscroll-off ()
  "Alignment depends on faces whether or not clipping is enabled."
  (let ((md-table-align-hscroll nil))
    (md-table-align-tests--with-pitch md-table-align-tests--simple
      (md-table-align-tests--enable)
      (let ((before (md-table-align-tests--data-rows)))
        (variable-pitch-mode 1)
        (md-table-align--post-command)
        (redisplay t)
        (should-not (equal (md-table-align-tests--data-rows) before))))))
