;;; md-table-inline-tests.el --- Tests for md-table-inline -*- lexical-binding: t; -*-

;;; Commentary:

;; These run in real buffers under a real `markdown-ts-mode' with both real
;; tree-sitter grammars, fontified by real `jit-lock' in a live TTY frame.
;; Nothing upstream is stubbed: the assertions read back the text properties
;; `markdown-ts-mode's own fontifiers applied once the missing parser ranges
;; exist, and -- for the interplay tests -- the screen columns `posn-at-point'
;; reports after `md-table-align' laid the result out.

;;; Code:

(require 'ert)
(require 'treesit)
(require 'markdown-ts-mode)
(require 'md-table-inline)
(require 'md-table-align)
(require 'md-table-align-tests)

;;;; Fixtures

(defconst md-table-inline-tests--document
  "prose with `tick` in it

| Name | **B** |
|------|-------|
| `xxxxxx` | y |
| zzz | w |
"
  "A table full of inline markup, plus prose markup outside it.")

;;;; Helpers

(defmacro md-table-inline-tests--with-buffer (hide &rest body)
  "Display the fixture in `markdown-ts-mode', then run BODY.
HIDE non-nil turns markup hiding on for the buffer."
  (declare (indent 1) (debug t))
  `(let ((buf (generate-new-buffer "*md-table-inline-test*")))
     (unwind-protect
         (progn
           (switch-to-buffer buf)
           (insert md-table-inline-tests--document)
           (goto-char (point-min))
           (markdown-ts-mode)
           ;; Buffer-locally, the way `markdown-ts-view-mode' does it:
           ;; fontifiers read the variable lazily, at jit-lock time, so a
           ;; `let' around the mode call would have unwound by then.
           (when ,hide
             (setq-local markdown-ts-hide-markup t)
             (markdown-ts--set-hide-markup t))
           (set-buffer-modified-p nil)
           (redisplay t)
           ,@body)
       (kill-buffer buf))))

(defun md-table-inline-tests--enable ()
  "Turn on `md-table-inline-mode' and let fontification settle."
  (md-table-inline-mode 1)
  (should md-table-inline-mode)
  (redisplay t))

(defun md-table-inline-tests--pos-of (string)
  "Return the buffer position where STRING starts."
  (save-excursion
    (goto-char (point-min))
    (should (search-forward string nil t))
    (match-beginning 0)))

(defun md-table-inline-tests--faces-at (pos)
  "Return the face property at POS as a list."
  (ensure-list (get-text-property pos 'face)))

(defun md-table-inline-tests--cell-parser-overlays ()
  "Return local-parser overlays lying inside the fixture's table."
  (let ((beg (md-table-inline-tests--pos-of "| Name")))
    (seq-filter
     (lambda (ov)
       (and (overlay-get ov 'treesit-parser-local-p)
            (overlay-get ov 'treesit-parser)
            (>= (overlay-start ov) beg)))
     (overlays-in beg (point-max)))))

;;;; Fontification inside cells

(ert-deftest md-table-inline-test-code-span-in-cell-gets-its-face ()
  "A cell's code span carries `markdown-ts-code-span' once the mode is on."
  (md-table-inline-tests--with-buffer nil
    (let ((pos (md-table-inline-tests--pos-of "xxxxxx")))
      (should-not (memq 'markdown-ts-code-span
                        (md-table-inline-tests--faces-at pos)))
      (md-table-inline-tests--enable)
      (should (memq 'markdown-ts-code-span
                    (md-table-inline-tests--faces-at pos))))))

(ert-deftest md-table-inline-test-emphasis-in-header-cell ()
  "Strong emphasis in a header cell is fontified."
  (md-table-inline-tests--with-buffer nil
    (md-table-inline-tests--enable)
    (should (memq 'markdown-ts-bold
                  (md-table-inline-tests--faces-at
                   (md-table-inline-tests--pos-of "B"))))))

(ert-deftest md-table-inline-test-hide-markup-reaches-cells ()
  "With `markdown-ts-hide-markup', a cell's backticks go invisible."
  (md-table-inline-tests--with-buffer t
    (let ((tick (1- (md-table-inline-tests--pos-of "xxxxxx"))))
      (should (eq (char-after tick) ?\`))
      (should-not (get-text-property tick 'invisible))
      (md-table-inline-tests--enable)
      (should (eq (get-text-property tick 'invisible) 'markdown-ts--markup)))))

(ert-deftest md-table-inline-test-prose-fontification-unaffected ()
  "Markup outside tables is fontified with the mode on, and buffer text
stays byte-identical throughout."
  (md-table-inline-tests--with-buffer nil
    (let ((before (buffer-substring-no-properties (point-min) (point-max))))
      (md-table-inline-tests--enable)
      (should (memq 'markdown-ts-code-span
                    (md-table-inline-tests--faces-at
                     (md-table-inline-tests--pos-of "tick"))))
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     before))
      (should-not (buffer-modified-p)))))

;;;; Switching off

(ert-deftest md-table-inline-test-off-restores-upstream-behaviour ()
  "Switching off removes the cell faces, the invisibility, and the
per-cell parsers, while prose fontification survives."
  (md-table-inline-tests--with-buffer t
    (md-table-inline-tests--enable)
    (should (md-table-inline-tests--cell-parser-overlays))
    (md-table-inline-mode -1)
    (redisplay t)
    (let ((pos (md-table-inline-tests--pos-of "xxxxxx")))
      (should-not (memq 'markdown-ts-code-span
                        (md-table-inline-tests--faces-at pos)))
      (should-not (get-text-property (1- pos) 'invisible)))
    ;; The orphaned cell parsers are gone -- `treesit-update-ranges' cannot
    ;; collect them in an unmodified buffer, so the mode deletes them itself.
    (should-not (md-table-inline-tests--cell-parser-overlays))
    ;; Prose still fontifies: the upstream `inline' rule survived the removal.
    (should (memq 'markdown-ts-code-span
                  (md-table-inline-tests--faces-at
                   (md-table-inline-tests--pos-of "tick"))))))

;;;; Interplay with md-table-align

;; With markup hidden, the first column's widest content is `xxxxxx` rendered
;; *without* its backticks: 6 columns, not 8.  The header's `**B**' renders
;; as a single character.  So the aligned grid is
;;
;;     | Name   | B |
;;     |--------|---|
;;     | xxxxxx | y |
;;     | zzz    | w |
;;
;; pipes at columns 0, 9 and 13 on every row.

(defconst md-table-inline-tests--hidden-grid '(0 9 13))

(ert-deftest md-table-inline-test-alignment-measures-hidden-markup ()
  "The grid is laid out to rendered widths: hidden backticks measure zero."
  (md-table-inline-tests--with-buffer t
    (md-table-inline-tests--enable)
    (md-table-align-tests--enable)
    (dolist (row (md-table-align-tests--pipe-columns))
      (should (equal row md-table-inline-tests--hidden-grid)))))

(ert-deftest md-table-inline-test-alignment-enabled-first-still-measures-hidden ()
  "Enabling alignment before this mode ends up at the same grid.

The hook order a user's init file produces is not guaranteed, and the
inline ranges arriving second means alignment first measured raw text:
the flush must re-fontify and then re-measure -- fontification runs
before alignment inside a shared jit-lock pass, and the property writes
advance the modified tick the metrics cache keys on."
  (md-table-inline-tests--with-buffer t
    (md-table-align-tests--enable)
    (md-table-inline-tests--enable)
    (dolist (row (md-table-align-tests--pipe-columns))
      (should (equal row md-table-inline-tests--hidden-grid)))))

(ert-deftest md-table-inline-test-toggling-hide-markup-re-aligns ()
  "The hide-markup toggle re-fits the table to the new rendered widths.
The toggle changes `buffer-invisibility-spec', which is in the layout
key, so the post-command re-fit notices it."
  (md-table-inline-tests--with-buffer t
    (md-table-inline-tests--enable)
    (md-table-align-tests--enable)
    (markdown-ts-toggle-hide-markup)
    (md-table-align--post-command)
    (redisplay t)
    ;; Backticks visible again: the first column is 8 wide, `**B**' is 5.
    (dolist (row (md-table-align-tests--pipe-columns))
      (should (equal row '(0 11 19))))
    (markdown-ts-toggle-hide-markup)
    (md-table-align--post-command)
    (redisplay t)
    (dolist (row (md-table-align-tests--pipe-columns))
      (should (equal row md-table-inline-tests--hidden-grid)))))

(provide 'md-table-inline-tests)

;;; md-table-inline-tests.el ends here
