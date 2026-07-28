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

;;;; Fitting a table to the window
;;
;; A table wider than the window wraps, and a wrapped row is not merely ugly:
;; its continuation lines restart at the window's left edge, so the column grid
;; is gone.  Narrowing the frame is what makes these assertions bite -- at the
;; default frame width the fixture below fits and nothing is elided.

(defconst md-table-align-tests--wide
  "| Name | Description | Status |
|------|-------------|--------|
| alpha | first item description here | open |
| beta | second item description | done |
")

;; Aligned but unfitted, the fixture needs 48 columns: 4 borders, 6 spaces of
;; padding, and content of 5 ("alpha"), 27 ("first item description here") and
;; 6 ("Status").  Every test below runs it in a 40-column frame.
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

(defun md-table-align-tests--elisions ()
  "Return the `help-echo' of every elision overlay, in buffer order."
  (let (out)
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (and (overlay-get ov 'md-table-align)
                 (overlay-get ov 'help-echo))
        (push (cons (overlay-start ov) (overlay-get ov 'help-echo)) out)))
    (mapcar #'cdr (sort out :key #'car))))

(ert-deftest md-table-align-test-wide-table-wraps-without-fitting ()
  "The fixture really does overflow, so the fitting tests are not vacuous."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (let ((md-table-align-fit-to-window nil))
        (md-table-align-tests--enable)
        (should (seq-some (lambda (n) (> n 1))
                          (md-table-align-tests--screen-lines)))))))

(ert-deftest md-table-align-test-fitting-keeps-rows-on-one-screen-line ()
  "With fitting on, every row of an overflowing table occupies one line."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (should (equal (md-table-align-tests--screen-lines) '(1 1 1 1))))))

(ert-deftest md-table-align-test-fitted-table-is-still-aligned ()
  "Fitting must not cost the alignment it exists to protect."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (let ((rows (md-table-align-tests--pipe-columns)))
        (should (= (length rows) 4))
        (dolist (row rows)
          (should (equal row (car rows))))))))

(ert-deftest md-table-align-test-fitting-elides-the-widest-column ()
  "The shortfall is taken from the widest column, not spread over all of them."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (let ((elided (md-table-align-tests--elisions)))
        ;; Only the Description cells are too wide for their capped column.
        (should (equal elided
                       '("first item description here"
                         "second item description")))))))

(ert-deftest md-table-align-test-elided-text-stays-readable ()
  "Elision overlays carry the full cell text for `display-local-help'."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (goto-char (point-min))
      ;; Must land inside the elided tail, not merely inside the cell.
      (should (search-forward "here" nil t))
      (should (equal (get-char-property (match-beginning 0) 'help-echo)
                     "first item description here")))))

(ert-deftest md-table-align-test-fitting-does-not-modify-buffer-text ()
  "Eliding is display-only, like every other overlay here."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (let ((before (buffer-substring-no-properties (point-min) (point-max))))
        (md-table-align-tests--enable)
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       before))
        (should-not (buffer-modified-p))))))

(ert-deftest md-table-align-test-table-that-fits-is-not-elided ()
  "A table with room to spare is left entirely alone."
  (md-table-align-tests--with-buffer md-table-align-tests--simple
    (md-table-align-tests--enable)
    (should-not (md-table-align-tests--elisions))
    (dolist (row (md-table-align-tests--pipe-columns))
      (should (equal row md-table-align-tests--simple-columns)))))

(ert-deftest md-table-align-test-widening-the-frame-restores-the-table ()
  "Growing the window re-fits, and the elisions go away."
  (md-table-align-tests--with-frame-width md-table-align-tests--wide-frame
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (should (md-table-align-tests--elisions))
      (set-frame-width nil 100)
      ;; `set-frame-width' runs the window-change hooks the mode listens on.
      (redisplay t)
      (should-not (md-table-align-tests--elisions))
      (should (equal (md-table-align-tests--screen-lines) '(1 1 1 1))))))

(ert-deftest md-table-align-test-fits-down-to-the-floor ()
  "Columns shrink as far as `md-table-align-min-column-width' and no further.
At 20 columns the fixture fits with all three columns exactly at the floor."
  (md-table-align-tests--with-frame-width 20
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (should (md-table-align-tests--elisions))
      (should (equal (md-table-align-tests--screen-lines) '(1 1 1 1))))))

(ert-deftest md-table-align-test-gives-up-rather-than-mangle ()
  "A window too narrow even for floor-width columns leaves the table to wrap.
Falling back to the current behaviour beats a row of bare ellipses."
  (md-table-align-tests--with-frame-width 16
    (md-table-align-tests--with-buffer md-table-align-tests--wide
      (md-table-align-tests--enable)
      (should-not (md-table-align-tests--elisions))
      (should (seq-some (lambda (n) (> n 1))
                        (md-table-align-tests--screen-lines))))))

(provide 'md-table-align-tests)

;;; md-table-align-tests.el ends here
