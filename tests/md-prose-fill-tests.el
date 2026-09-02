;;; md-prose-fill-tests.el --- Tests for md-prose-fill -*- lexical-binding: t; -*-

;;; Commentary:

;; Like the rest of the suite these run in a real TTY frame, in a real
;; `markdown-ts-mode' buffer, and assert on what redisplay actually did --
;; `posn-at-point' rows and columns.  Nothing is stubbed, which matters here
;; more than usual: the whole package rests on how the display engine treats an
;; injected `display' newline, and a mock would simply agree with whatever we
;; assumed.
;;
;; The fixtures are sized against two numbers: a frame wide enough that nothing
;; wraps on its own (so any break is ours), and a fill column well inside it.

;;; Code:

(require 'ert)
(require 'treesit)
(require 'markdown-ts-mode)
(require 'md-prose-fill)

;;;; Fixtures

(defconst md-prose-fill-tests--frame 100
  "A frame wide enough that the fixtures never wrap at the window edge.")

(defconst md-prose-fill-tests--column 40
  "Fill column used by the tests, well inside the frame.")

;; 88 characters: one screen line in a 100-column frame, three at a fill
;; column of 40.
(defconst md-prose-fill-tests--prose
  "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho\n")

;; Deliberately wider than the fill column, so "Status" lands past it and the
;; assertion that tables keep the full width is not vacuous.
(defconst md-prose-fill-tests--table
  "| Name | Description of the thing being described here | Status |
|:-----|:---------------------------------------------|:-------|
| alpha | first item description that runs on a while | open |
")

(defconst md-prose-fill-tests--code
  "```\nalpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu\n```\n")

(defconst md-prose-fill-tests--heading
  "# alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu\n")

(defconst md-prose-fill-tests--list
  "- alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi\n")

(defconst md-prose-fill-tests--long-word
  "alphabetagammadeltaepsilonzetaetathetaiotakappalambdamunuxiomicronpirhosigma\n")

;; A token wider than the whole budget, with prose on both sides of it.  The
;; token has to overflow, but the prose after it must still be filled.
(defconst md-prose-fill-tests--long-word-in-prose
  "alpha beta gamma delta epsilon zeta https://example.com/a/very/long/path/that/has/no/spaces/in/it and then some more words that should still be filled after it\n")

;; An inline code span longer than the fill column, with prose on both sides.
;; A shell command is one thing; breaking inside it is what made an agent's tool
;; row wrap where it was meant to stay on a single folded line.
(defconst md-prose-fill-tests--code-span
  "alpha beta `sed -i 's/x/y/' file.el && rm -f \"$OUT\" && timeout 90 script -qec` gamma delta epsilon zeta eta\n")

;; A line whose visible width is well inside the fill column but whose buffer
;; text is not -- what an `invisible' overlay makes of a folded tool row.
(defconst md-prose-fill-tests--hidden-tail
  "alpha beta gamma delta and then a long hidden tail that nobody can see at all here\n")

(defconst md-prose-fill-tests--hidden-from 25
  "Character offset at which `md-prose-fill-tests--hidden-tail' is hidden.")

;;;; Helpers

(defmacro md-prose-fill-tests--with-buffer (text &rest body)
  "Display TEXT in a `markdown-ts-mode' buffer in a live window, then run BODY.
The frame is widened first, so a fixture only ever breaks where this
package breaks it, and restored afterwards."
  (declare (indent 1) (debug t))
  `(let ((buf (generate-new-buffer "*md-prose-fill-test*"))
         (original (frame-width))
         (md-prose-fill-column md-prose-fill-tests--column))
     (unwind-protect
         (progn
           (set-frame-width nil md-prose-fill-tests--frame)
           (switch-to-buffer buf)
           (insert ,text)
           (goto-char (point-min))
           (markdown-ts-mode)
           (visual-line-mode 1)
           (visual-wrap-prefix-mode 1)
           (set-buffer-modified-p nil)
           (redisplay t)
           ,@body)
       (set-frame-width nil original)
       (kill-buffer buf))))

(defun md-prose-fill-tests--enable ()
  "Turn on `md-prose-fill-mode' and let redisplay settle."
  (md-prose-fill-mode 1)
  (should md-prose-fill-mode)
  (redisplay t)
  ;; `jit-lock' is lazy by design; the tests assert on a settled buffer.
  (jit-lock-fontify-now (point-min) (point-max))
  (redisplay t))

(defun md-prose-fill-tests--rowcol (pos)
  "Return (ROW . COL) at which buffer position POS is rendered."
  (let ((posn (posn-at-point pos)))
    (should posn)
    (let ((cr (posn-col-row posn)))
      (cons (cdr cr) (car cr)))))

(defun md-prose-fill-tests--row (pos) (car (md-prose-fill-tests--rowcol pos)))
(defun md-prose-fill-tests--col (pos) (cdr (md-prose-fill-tests--rowcol pos)))

(defun md-prose-fill-tests--breaks ()
  "Return the positions this package is rendering as line breaks."
  (let ((pos (point-min))
        (out nil))
    (while (< pos (point-max))
      (when (get-text-property pos 'md-prose-fill-break)
        (push pos out))
      (setq pos (1+ pos)))
    (nreverse out)))

(defun md-prose-fill-tests--rows-of-line (n)
  "Return how many screen rows logical line N (1-based) occupies."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- n))
    (let ((rows nil)
          (end (line-end-position)))
      (while (< (point) end)
        (cl-pushnew (md-prose-fill-tests--row (point)) rows)
        (forward-char 1))
      (length rows))))

(defun md-prose-fill-tests--word (word)
  "Return the buffer position where WORD starts."
  (save-excursion
    (goto-char (point-min))
    (should (search-forward word nil t))
    (match-beginning 0)))

;;;; The core question: is prose filled, and only prose?

(ert-deftest md-prose-fill-test-fills-a-paragraph ()
  "A paragraph that fits the frame is still broken at the fill column."
  (md-prose-fill-tests--with-buffer md-prose-fill-tests--prose
    (md-prose-fill-tests--enable)
    (let ((breaks (md-prose-fill-tests--breaks)))
      (should (= (length breaks) 2))
      ;; Every break lands inside the budget, and starts a new screen row.
      (dolist (pos breaks)
        (should (<= (md-prose-fill-tests--col pos) md-prose-fill-tests--column))
        (should (= (md-prose-fill-tests--row (1+ pos))
                   (1+ (md-prose-fill-tests--row pos))))
        (should (= (md-prose-fill-tests--col (1+ pos)) 0))))))

(ert-deftest md-prose-fill-test-unfilled-before-enabling ()
  "The fixture fits on one screen row unaided, so the test above is not vacuous."
  (md-prose-fill-tests--with-buffer md-prose-fill-tests--prose
    (should (= (md-prose-fill-tests--rows-of-line 1) 1))
    (should-not (md-prose-fill-tests--breaks))))

(ert-deftest md-prose-fill-test-leaves-tables-at-full-width ()
  "A table wider than the fill column is not broken -- the point of the package."
  (md-prose-fill-tests--with-buffer md-prose-fill-tests--table
    (md-prose-fill-tests--enable)
    (should-not (md-prose-fill-tests--breaks))
    ;; The header row runs past the fill column, on one screen row.
    (should (= (md-prose-fill-tests--rows-of-line 1) 1))
    (should (> (md-prose-fill-tests--col (md-prose-fill-tests--word "Status"))
               md-prose-fill-tests--column))))

(ert-deftest md-prose-fill-test-leaves-code-blocks-alone ()
  "A fenced code block is not prose and is never broken."
  (md-prose-fill-tests--with-buffer md-prose-fill-tests--code
    (md-prose-fill-tests--enable)
    (should-not (md-prose-fill-tests--breaks))
    (should (= (md-prose-fill-tests--rows-of-line 2) 1))))

(ert-deftest md-prose-fill-test-leaves-headings-alone ()
  "A heading is not broken: it is short, and `md-heading-scale' may scale it."
  (md-prose-fill-tests--with-buffer md-prose-fill-tests--heading
    (md-prose-fill-tests--enable)
    (should-not (md-prose-fill-tests--breaks))
    (should (= (md-prose-fill-tests--rows-of-line 1) 1))))

(ert-deftest md-prose-fill-test-fills-prose-around-a-table ()
  "Prose next to a table is filled while the table is left alone."
  (md-prose-fill-tests--with-buffer
      (concat md-prose-fill-tests--prose "\n" md-prose-fill-tests--table)
    (md-prose-fill-tests--enable)
    (should (= (length (md-prose-fill-tests--breaks)) 2))
    (dolist (pos (md-prose-fill-tests--breaks))
      (should (< pos (md-prose-fill-tests--word "| Name"))))))

;;;; Indentation of what a break starts

(ert-deftest md-prose-fill-test-list-continuation-keeps-its-indent ()
  "Text after a break in a list item starts at the item's content column.
A line begun by an injected break is not a continuation line, so
`wrap-prefix' does not reach it; this is the `line-prefix' doing its job."
  (md-prose-fill-tests--with-buffer md-prose-fill-tests--list
    (md-prose-fill-tests--enable)
    (let ((breaks (md-prose-fill-tests--breaks)))
      (should breaks)
      (dolist (pos breaks)
        ;; "- " is two columns wide.
        (should (= (md-prose-fill-tests--col (1+ pos)) 2))))))

(ert-deftest md-prose-fill-test-list-lines-end-inside-the-column ()
  "The indent comes out of the budget, so every row ends at the same edge."
  (md-prose-fill-tests--with-buffer md-prose-fill-tests--list
    (md-prose-fill-tests--enable)
    (dolist (pos (md-prose-fill-tests--breaks))
      (should (<= (md-prose-fill-tests--col pos) md-prose-fill-tests--column)))))

;;;; Display-only: the property this package exists to preserve

(ert-deftest md-prose-fill-test-does-not-modify-buffer-text ()
  "Filling leaves buffer text byte-identical and the buffer unmodified."
  (md-prose-fill-tests--with-buffer md-prose-fill-tests--prose
    (let ((before (buffer-substring-no-properties (point-min) (point-max))))
      (md-prose-fill-tests--enable)
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     before))
      (should-not (buffer-modified-p)))))

(ert-deftest md-prose-fill-test-works-in-read-only-buffer ()
  "Filling applies with `buffer-read-only' set."
  (md-prose-fill-tests--with-buffer md-prose-fill-tests--prose
    (setq buffer-read-only t)
    (md-prose-fill-tests--enable)
    (should (md-prose-fill-tests--breaks))))

(ert-deftest md-prose-fill-test-works-under-a-read-only-text-property ()
  "Filling applies where the text carries a `read-only' property.
This is how the chat transcript buffers this package is for are locked."
  (md-prose-fill-tests--with-buffer md-prose-fill-tests--prose
    (let ((inhibit-read-only t))
      (put-text-property (point-min) (point-max) 'read-only t))
    (md-prose-fill-tests--enable)
    (should (md-prose-fill-tests--breaks))))

;;;; Edges

(ert-deftest md-prose-fill-test-does-not-break-a-long-word ()
  "A run with no space in it overflows rather than being cut mid-word."
  (md-prose-fill-tests--with-buffer md-prose-fill-tests--long-word
    (md-prose-fill-tests--enable)
    (should-not (md-prose-fill-tests--breaks))))

(ert-deftest md-prose-fill-test-resumes-filling-after-a-long-token ()
  "A token too wide to fit costs one long line, not the rest of the fill.
The token overflows to the window edge; the prose after it is filled
again from the first space past it."
  (md-prose-fill-tests--with-buffer md-prose-fill-tests--long-word-in-prose
    (md-prose-fill-tests--enable)
    (let* ((url (md-prose-fill-tests--word "https://"))
           (tail (md-prose-fill-tests--word "and then"))
           (last (md-prose-fill-tests--word "after it"))
           (url-row (md-prose-fill-tests--row url)))
      ;; The token is not cut: it starts a row and is still on it at its end.
      (should (= (md-prose-fill-tests--col url) 0))
      (should (= (md-prose-fill-tests--row (1- tail)) url-row))
      ;; And filling resumes: the prose after it is on later rows, and gets
      ;; broken again rather than running on as one long line.
      (should (> (md-prose-fill-tests--row tail) url-row))
      (should (> (md-prose-fill-tests--row last)
                 (md-prose-fill-tests--row tail))))))

;;;; Inline code, and text that is not shown

(ert-deftest md-prose-fill-test-never-breaks-inside-a-code-span ()
  "An inline code span is one token: the fill goes around it, never into it."
  (md-prose-fill-tests--with-buffer md-prose-fill-tests--code-span
    (md-prose-fill-tests--enable)
    (let ((open (md-prose-fill-tests--word "`sed"))
          (close (save-excursion
                   (goto-char (point-min))
                   (should (search-forward "-qec`" nil t))
                   (point))))
      (should (md-prose-fill-tests--breaks))
      (dolist (pos (md-prose-fill-tests--breaks))
        (should-not (and (> pos open) (< pos close)))))))

(ert-deftest md-prose-fill-test-fills-the-prose-around-a-code-span ()
  "Going around a code span does not mean giving up on the rest of the line."
  (md-prose-fill-tests--with-buffer md-prose-fill-tests--code-span
    (md-prose-fill-tests--enable)
    (let ((close (save-excursion
                   (goto-char (point-min))
                   (should (search-forward "-qec`" nil t))
                   (point))))
      ;; At least one break before the span, and one from its end onwards --
      ;; the space closing the span off is itself the natural next break.
      (should (seq-some (lambda (pos) (< pos close)) (md-prose-fill-tests--breaks)))
      (should (seq-some (lambda (pos) (>= pos close))
                        (md-prose-fill-tests--breaks))))))

(ert-deftest md-prose-fill-test-hidden-text-costs-no-columns ()
  "A line hidden down to inside the fill column is not broken.
Counting hidden characters would break a folded tool row that renders
well short of the column."
  (md-prose-fill-tests--with-buffer md-prose-fill-tests--hidden-tail
    (let ((ov (make-overlay (+ (point-min) md-prose-fill-tests--hidden-from)
                            (line-end-position))))
      (overlay-put ov 'invisible 'md-prose-fill-test-fold)
      (add-to-invisibility-spec (cons 'md-prose-fill-test-fold t)))
    (unwind-protect
        (progn
          (md-prose-fill-tests--enable)
          (should-not (md-prose-fill-tests--breaks)))
      (remove-from-invisibility-spec (cons 'md-prose-fill-test-fold t)))))

(ert-deftest md-prose-fill-test-unhiding-refills ()
  "Revealing hidden text puts the breaks back where they now belong.
No character changes, so `jit-lock' sees nothing; the invisibility spec
is part of what the fill is compared against for exactly this reason."
  (md-prose-fill-tests--with-buffer md-prose-fill-tests--hidden-tail
    (let ((ov (make-overlay (+ (point-min) md-prose-fill-tests--hidden-from)
                            (line-end-position))))
      (overlay-put ov 'invisible 'md-prose-fill-test-fold)
      (add-to-invisibility-spec (cons 'md-prose-fill-test-fold t)))
    (unwind-protect
        (progn
          (md-prose-fill-tests--enable)
          (should-not (md-prose-fill-tests--breaks))
          (remove-from-invisibility-spec (cons 'md-prose-fill-test-fold t))
          (md-prose-fill--refill)
          (redisplay t)
          (jit-lock-fontify-now (point-min) (point-max))
          (should (md-prose-fill-tests--breaks)))
      (remove-from-invisibility-spec (cons 'md-prose-fill-test-fold t)))))

(ert-deftest md-prose-fill-test-leaves-foreign-display-properties-alone ()
  "A space already carrying a `display' property is never taken as a break.
Other packages here put `display' on buffer text; whoever got there
first keeps the character.

The claim is staked with overlays, which is how `md-table-align' and
`md-table-inline' place theirs -- and the only way it can be staked from
a test, since `font-lock' unfontifies a region before refontifying it
and would strip a bare `display' text property placed beforehand."
  (md-prose-fill-tests--with-buffer md-prose-fill-tests--prose
    (save-excursion
      (goto-char (point-min))
      (while (search-forward " " nil t)
        (overlay-put (make-overlay (match-beginning 0) (match-end 0))
                     'display " ")))
    (set-buffer-modified-p nil)
    (md-prose-fill-tests--enable)
    (should-not (md-prose-fill-tests--breaks))))

(ert-deftest md-prose-fill-test-narrow-window-drops-the-fill ()
  "Below the fill column the window edge takes over and no break is placed."
  (md-prose-fill-tests--with-buffer md-prose-fill-tests--prose
    (md-prose-fill-tests--enable)
    (should (md-prose-fill-tests--breaks))
    ;; `set-frame-width' runs the window-change hooks the mode listens on.
    (set-frame-width nil 30)
    (redisplay t)
    (jit-lock-fontify-now (point-min) (point-max))
    (should-not (md-prose-fill-tests--breaks))))

(ert-deftest md-prose-fill-test-widening-back-restores-the-fill ()
  "Crossing the threshold the other way puts the fill back."
  (md-prose-fill-tests--with-buffer md-prose-fill-tests--prose
    (md-prose-fill-tests--enable)
    (set-frame-width nil 30)
    (redisplay t)
    (jit-lock-fontify-now (point-min) (point-max))
    (should-not (md-prose-fill-tests--breaks))
    (set-frame-width nil md-prose-fill-tests--frame)
    (redisplay t)
    (jit-lock-fontify-now (point-min) (point-max))
    (should (md-prose-fill-tests--breaks))))

(ert-deftest md-prose-fill-test-disabling-removes-everything ()
  "Switching the mode off leaves no property of ours behind."
  (md-prose-fill-tests--with-buffer md-prose-fill-tests--list
    (md-prose-fill-tests--enable)
    (should (md-prose-fill-tests--breaks))
    (md-prose-fill-mode -1)
    (redisplay t)
    (should-not (md-prose-fill-tests--breaks))
    (let ((pos (point-min))
          (found nil))
      (while (< pos (point-max))
        (when (or (get-text-property pos 'md-prose-fill-prefix)
                  (get-text-property pos 'md-prose-fill-break))
          (setq found t))
        (setq pos (1+ pos)))
      (should-not found))
    ;; And the paragraph renders as one row again.
    (should (= (md-prose-fill-tests--rows-of-line 1) 1))))

(ert-deftest md-prose-fill-test-refuses-without-a-parser ()
  "Without a `markdown' parser the mode declines rather than half-working."
  (let ((buf (generate-new-buffer "*md-prose-fill-test*")))
    (unwind-protect
        (progn
          (switch-to-buffer buf)
          (insert md-prose-fill-tests--prose)
          (fundamental-mode)
          (md-prose-fill-mode 1)
          (should-not md-prose-fill-mode))
      (kill-buffer buf))))

;;; md-prose-fill-tests.el ends here
