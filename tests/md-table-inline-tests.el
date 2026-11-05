;;; md-table-inline-tests.el --- Tests for md-table-inline -*- lexical-binding: t; -*-

;;; Commentary:

;; These run in real buffers under a real `markdown-ts-mode' with both real
;; tree-sitter grammars, fontified by real `jit-lock' in a live TTY frame.
;; Nothing upstream is stubbed: the assertions read back the text properties
;; `markdown-ts-mode's own fontifiers applied once the missing parser ranges
;; exist, and -- for the interplay tests -- the copies `md-table-wrap' draws
;; the cells from.

;;; Code:

(require 'ert)
(require 'treesit)
(require 'markdown-ts-mode)
(require 'md-table-inline)
(require 'md-table-wrap)
(require 'nuggets-test-helpers)

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
  `(nuggets-test-with-buffer md-table-inline-tests--document
     ;; Buffer-locally, the way `markdown-ts-view-mode' does it:
     ;; fontifiers read the variable lazily, at jit-lock time, so a
     ;; `let' around the mode call would have unwound by then.
     (when ,hide
       (setq-local markdown-ts-hide-markup t)
       (markdown-ts--set-hide-markup t)
       (redisplay t))
     ,@body))

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

;;;; Interplay with md-table-wrap
;;
;; `md-table-wrap' draws every cell as a copy of its text, taken after the
;; row is fontified.  The faces this mode gives a cell have to reach that
;; copy, or the drawn table shows none of them.

(defun md-table-inline-tests--drawn-faces (string)
  "Faces on the first copy of STRING in `md-table-wrap's strings, flattened."
  (seq-some (lambda (ov)
              (let ((s (overlay-get ov 'before-string)))
                (when-let* ((i (and (overlay-get ov 'md-table-wrap) s
                                    (string-search string s))))
                  (flatten-tree (get-text-property i 'face s)))))
            (overlays-in (point-min) (point-max))))

(ert-deftest md-table-inline-test-wrapped-copy-carries-cell-faces ()
  "A code span's face is on the copy `md-table-wrap' draws of it."
  (nuggets-test-with-frame-width 60
    (md-table-inline-tests--with-buffer nil
      (md-table-inline-tests--enable)
      (md-table-wrap-mode 1)
      (redisplay t)
      (should (memq 'markdown-ts-code-span
                    (md-table-inline-tests--drawn-faces "xxxxxx"))))))

(ert-deftest md-table-inline-test-wrapped-copy-picks-up-faces-arriving-later ()
  "The same, with the wrapped table drawn before the cells had faces.
The hook order an init file produces is not guaranteed, and this mode
arriving second refontifies text whose copies are already drawn."
  (nuggets-test-with-frame-width 60
    (md-table-inline-tests--with-buffer nil
      (md-table-wrap-mode 1)
      (redisplay t)
      (should-not (memq 'markdown-ts-code-span
                        (md-table-inline-tests--drawn-faces "xxxxxx")))
      (md-table-inline-tests--enable)
      (should (memq 'markdown-ts-code-span
                    (md-table-inline-tests--drawn-faces "xxxxxx"))))))

(provide 'md-table-inline-tests)

;;; md-table-inline-tests.el ends here
