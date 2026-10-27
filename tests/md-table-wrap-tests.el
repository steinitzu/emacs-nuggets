;;; md-table-wrap-tests.el --- Tests for md-table-wrap -*- lexical-binding: t; -*-

;;; Commentary:

;; These run in real `markdown-ts-mode' buffers in a live TTY frame, with the
;; mode's real hooks driven by real key events.  Two kinds of evidence:
;;
;; - Redisplay's own measurements: `count-screen-lines' and
;;   `window-text-pixel-size' report what the display engine laid out,
;;   before-strings included.
;; - The screen lines the overlays describe, rebuilt by
;;   `md-table-wrap-tests--screen': each position's before-string, then its
;;   `display' string or its own character, with `:align-to' stretches
;;   expanded.  In a TTY frame a pixel is a column, so this is the grid the
;;   terminal shows, and borders can be checked column by column.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'markdown-ts-mode)
(require 'md-table-wrap)
(require 'md-table-align)
(require 'md-table-align-tests)

;;;; Fixtures

(defconst md-table-wrap-tests--wide
  "Prose before.

| Name | Description | Status |
|---|---|---|
| alpha | The first item, whose description runs on well past what one screen line of this window can hold. | open |
| beta | A second long description, so that every body row has to wrap onto several lines here. | done |
| gamma | Short. | open |

Prose after.
"
  "A table far wider than `md-table-wrap-tests--frame' columns.")

(defconst md-table-wrap-tests--narrow
  "| a | b |
|---|---|
| 1 | 2 |
| 3 | 4 |
"
  "A table that fits on one line per row.")

(defconst md-table-wrap-tests--list-item
  "1. A table inside a list item:

   | Step | Notes |
   |---|---|
   | Load | Evaluate the file, or load it from wherever it lives on disk, then carry on. |
   | Enable | Turn the mode on in any Markdown buffer, read-only or not, and it wraps. |
"
  "A wide table indented under a list item.")

(defconst md-table-wrap-tests--frame 60
  "Frame width, in columns, the tests run in.")

(defconst md-table-wrap-tests--borders "│┌┐└┘├┤┼┬┴╞╡╪"
  "Characters that stand on a column boundary in the `box' style.")

;;;; Helpers

(defmacro md-table-wrap-tests--with-table (text &rest body)
  "Show TEXT in a `markdown-ts-mode' buffer with `md-table-wrap-mode' on.
BODY runs in a frame `md-table-wrap-tests--frame' columns wide."
  (declare (indent 1) (debug t))
  `(md-table-align-tests--with-frame-width md-table-wrap-tests--frame
     (md-table-align-tests--with-buffer ,text
       (delete-other-windows)
       (md-table-wrap-mode 1)
       (should md-table-wrap-mode)
       (redisplay t)
       ,@body)))

(defun md-table-wrap-tests--press (keys)
  "Execute KEYS as real key events, then let redisplay settle."
  (execute-kbd-macro (kbd keys))
  (redisplay t))

(defun md-table-wrap-tests--own-overlays ()
  (seq-filter (lambda (o) (overlay-get o 'md-table-wrap))
              (overlays-in (point-min) (point-max))))

(defun md-table-wrap-tests--table-region ()
  "(BEG . END) of the first table's lines."
  (let* ((rows (md-table-wrap--table-rows (car md-table-wrap--tables)))
         (beg (md-table-wrap--beg (aref rows 0)))
         (end (md-table-wrap--end (aref rows (1- (length rows))))))
    (cons (save-excursion (goto-char beg) (line-beginning-position)) end)))

(defun md-table-wrap-tests--drawn (beg end)
  "The string redisplay draws for BEG..END, from this mode's overlays."
  (let ((pos beg) (parts nil))
    (while (< pos end)
      (dolist (o (overlays-in pos (1+ pos)))
        (when (and (overlay-get o 'md-table-wrap) (= (overlay-start o) pos)
                   (overlay-get o 'before-string))
          (push (overlay-get o 'before-string) parts)))
      (let ((cover (seq-find (lambda (o)
                               (and (overlay-get o 'md-table-wrap)
                                    (= (overlay-start o) pos) (> (overlay-end o) pos)
                                    (stringp (overlay-get o 'display))))
                             (overlays-in pos (1+ pos)))))
        (if cover
            (progn (push (overlay-get cover 'display) parts)
                   (setq pos (overlay-end cover)))
          (push (buffer-substring pos (1+ pos)) parts)
          (setq pos (1+ pos)))))
    (apply #'concat (nreverse parts))))

(defun md-table-wrap-tests--render (s)
  "Screen lines of S, with `:align-to' stretches expanded to spaces."
  (let ((lines nil) (line ""))
    (dotimes (i (length s))
      (let ((c (aref s i)) (d (get-text-property i 'display s)))
        (cond ((and (consp d) (eq (car d) 'space))
               (let ((to (car (plist-get (cdr d) :align-to))))
                 (setq line (concat line (make-string (max 0 (- to (string-width line)))
                                                      ?\s)))))
              ((eq c ?\n) (push line lines) (setq line ""))
              (t (setq line (concat line (string c)))))))
    (nreverse (cons line lines))))

(defun md-table-wrap-tests--screen ()
  "The first table's screen lines, as the terminal shows them."
  (let ((r (md-table-wrap-tests--table-region)))
    (md-table-wrap-tests--render (md-table-wrap-tests--drawn (car r) (cdr r)))))

(defun md-table-wrap-tests--cursor-line ()
  "Index of the first table's screen line the cursor is drawn on.
With point in a wrapped row, point is inside hidden text, so
`posn-at-point' reports the anchor, not the cursor.  The cursor is
wherever the `cursor' property puts it, on a copy."
  (let* ((r (md-table-wrap-tests--table-region))
         (s (md-table-wrap-tests--drawn (car r) (cdr r)))
         (i (text-property-not-all 0 (length s) 'cursor nil s)))
    (should i)
    (cl-count ?\n s :end i)))

(defun md-table-wrap-tests--border-columns (line)
  "Columns of LINE holding a character that stands on a column boundary."
  (let ((col 0) (out nil))
    (dotimes (i (length line))
      (when (seq-contains-p md-table-wrap-tests--borders (aref line i))
        (push col out))
      (setq col (+ col (char-width (aref line i)))))
    (nreverse out)))

(defun md-table-wrap-tests--lines-starting (prefix lines)
  (seq-filter (lambda (l) (string-prefix-p prefix (string-trim-left l))) lines))

(defun md-table-wrap-tests--goto (string)
  (goto-char (point-min))
  (should (search-forward string nil t))
  (goto-char (match-beginning 0)))

;;;; Display-only

(ert-deftest md-table-wrap-test-buffer-text-unchanged ()
  "Wrapping leaves the buffer's text and modified flag alone."
  (md-table-wrap-tests--with-table md-table-wrap-tests--wide
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   md-table-wrap-tests--wide))
    (should-not (buffer-modified-p))
    (should (md-table-wrap-tests--own-overlays))))

(ert-deftest md-table-wrap-test-read-only-buffer ()
  "A `buffer-read-only' buffer is wrapped, and stays unmodified."
  (md-table-align-tests--with-frame-width md-table-wrap-tests--frame
    (md-table-align-tests--with-buffer md-table-wrap-tests--wide
      (setq buffer-read-only t)
      (md-table-wrap-mode 1)
      (redisplay t)
      (should (> (length (md-table-wrap-tests--screen)) 8))
      (should-not (buffer-modified-p)))))

(ert-deftest md-table-wrap-test-read-only-text ()
  "Text carrying a `read-only' property, as chat transcripts use, is wrapped.
Measuring the table's indent copies such text into a work buffer."
  (md-table-align-tests--with-frame-width md-table-wrap-tests--frame
    (md-table-align-tests--with-read-only-text md-table-wrap-tests--list-item
      (md-table-wrap-mode 1)
      (redisplay t)
      (should (> (length (md-table-wrap-tests--screen)) 6))
      (should-not (buffer-modified-p)))))

;;;; Layout

(ert-deftest md-table-wrap-test-wide-table-fits-the-window ()
  "Redisplay lays the wrapped table out no wider than the window.
Unwrapped, its widest row needs over 100 columns."
  (md-table-wrap-tests--with-table md-table-wrap-tests--wide
    (let* ((r (md-table-wrap-tests--table-region))
           (size (window-text-pixel-size nil (car r) (cdr r))))
      (should (<= (car size) (window-body-width nil t)))
      ;; Three body rows on more than three lines: the long cells wrapped.
      (should (> (count-screen-lines (car r) (cdr r)) 8)))
    (dolist (line (md-table-wrap-tests--screen))
      (should (<= (string-width line) (window-body-width))))))

(ert-deftest md-table-wrap-test-borders-line-up ()
  "Every border on every screen line stands on the same column grid."
  (md-table-wrap-tests--with-table md-table-wrap-tests--wide
    (let* ((lines (md-table-wrap-tests--screen))
           (grid (md-table-wrap-tests--border-columns (car lines))))
      (should (= (length grid) 4))
      (should (= (car grid) 0))
      (dolist (line lines)
        (should (equal (md-table-wrap-tests--border-columns line) grid))))))

(ert-deftest md-table-wrap-test-rules-between-wrapped-rows ()
  "A wrapped table is framed, with a rule between each pair of body rows."
  (md-table-wrap-tests--with-table md-table-wrap-tests--wide
    (let ((lines (md-table-wrap-tests--screen)))
      (should (string-prefix-p "┌" (car lines)))
      (should (= (length (md-table-wrap-tests--lines-starting "╞" lines)) 1))
      (should (= (length (md-table-wrap-tests--lines-starting "├" lines)) 2))
      (should (string-prefix-p "└" (car (last lines)))))))

(ert-deftest md-table-wrap-test-narrow-table-has-no-row-rules ()
  "A table whose rows fit on one line each gets its frame, but no rules."
  (md-table-wrap-tests--with-table md-table-wrap-tests--narrow
    (let ((lines (md-table-wrap-tests--screen)))
      (should (equal lines '("┌───┬───┐"
                             "│ a │ b │"
                             "╞═══╪═══╡"
                             "│ 1 │ 2 │"
                             "│ 3 │ 4 │"
                             "└───┴───┘"))))))

(ert-deftest md-table-wrap-test-ascii-style ()
  "The `ascii' style draws Markdown pipes and dashes."
  (let ((md-table-wrap-style 'ascii))
    (md-table-wrap-tests--with-table md-table-wrap-tests--narrow
      (should (equal (md-table-wrap-tests--screen)
                     '("| a | b |"
                       "|---|---|"
                       "| 1 | 2 |"
                       "| 3 | 4 |"))))))

(ert-deftest md-table-wrap-test-list-item-table-keeps-its-indent ()
  "A table in a list item is drawn at its indent on every screen line.
Continuation lines start at the window's edge, with nothing real before
them, so the copies must stand at the indent by themselves."
  (md-table-wrap-tests--with-table md-table-wrap-tests--list-item
    (let ((lines (md-table-wrap-tests--screen)))
      (should (> (length lines) 6))
      (dolist (line lines)
        (should (string-prefix-p "   " line))
        (should (= (car (md-table-wrap-tests--border-columns line)) 3))
        (should (<= (string-width line) (window-body-width)))))))

;;;; Motion and editing

(ert-deftest md-table-wrap-test-next-line-walks-a-wrapped-row ()
  "C-n moves down one screen line at a time through a wrapped row,
and the cursor shows one screen row lower each time."
  (md-table-wrap-tests--with-table md-table-wrap-tests--wide
    (md-table-wrap-tests--goto "The first item")
    (md-table-wrap-tests--press "C-f")
    (let ((row (md-table-wrap-tests--cursor-line))
          (line (car (md-table-wrap--pos-line-x
                      md-table-wrap--prow
                      (- (point) (md-table-wrap--beg md-table-wrap--prow))))))
      (should (= line 0))
      (md-table-wrap-tests--press "C-n")
      (should (= (car (md-table-wrap--pos-line-x
                       md-table-wrap--prow
                       (- (point) (md-table-wrap--beg md-table-wrap--prow))))
                 1))
      (should (= (md-table-wrap-tests--cursor-line) (1+ row))))))

(ert-deftest md-table-wrap-test-beginning-of-line-stays-in-the-screen-line ()
  "C-a goes to the start of the screen line holding point, not the row."
  (md-table-wrap-tests--with-table md-table-wrap-tests--wide
    (md-table-wrap-tests--goto "The first item")
    (md-table-wrap-tests--press "C-f C-n C-e")
    (let ((row md-table-wrap--prow) (line nil))
      (setq line (car (md-table-wrap--pos-line-x
                       row (- (point) (md-table-wrap--beg row)))))
      (should (> line 0))
      (md-table-wrap-tests--press "C-a")
      (should (eq md-table-wrap--prow row))
      (should (= (car (md-table-wrap--pos-line-x row (- (point) (md-table-wrap--beg row))))
                 line)))))

(ert-deftest md-table-wrap-test-typing-rewraps-the-cell ()
  "Typing into a cell re-wraps its row, and the text lands in the buffer."
  (md-table-wrap-tests--with-table md-table-wrap-tests--wide
    (md-table-wrap-tests--goto "Short.")
    (let* ((row (md-table-wrap--row-at (point)))
           (before (md-table-wrap--row-height row)))
      (should (= before 1))
      (md-table-wrap-tests--press "C-e")
      (md-table-wrap-tests--goto "Short.")
      (forward-char (length "Short."))
      (insert " Now it says a great deal more, enough to need a second line or a third.")
      (md-table-wrap--post-command)
      (redisplay t)
      (should (> (md-table-wrap--row-height (md-table-wrap--row-at (point))) 1))
      (should (search-backward "Short. Now it says" nil t)))))

;;;; Lifecycle and md-table-align

(ert-deftest md-table-wrap-test-off-removes-everything ()
  "Turning the mode off leaves no overlay, hook or timer behind."
  (md-table-wrap-tests--with-table md-table-wrap-tests--wide
    (md-table-wrap-mode -1)
    (should-not (md-table-wrap-tests--own-overlays))
    (should-not (memq #'md-table-wrap--post-command post-command-hook))
    (should-not md-table-wrap--timer)
    (should-not md-table-wrap--tables)))

(ert-deftest md-table-wrap-test-hands-back-to-md-table-align ()
  "md-table-align steps aside while the mode is on, and comes back after."
  (md-table-align-tests--with-frame-width md-table-wrap-tests--frame
    (md-table-align-tests--with-buffer md-table-wrap-tests--wide
      (md-table-align-mode 1)
      (md-table-wrap-mode 1)
      (should-not md-table-align-mode)
      (md-table-wrap-mode -1)
      (should md-table-align-mode)
      (md-table-align-mode -1))))

(ert-deftest md-table-wrap-test-global-md-table-align-leaves-it-alone ()
  "`global-md-table-align-mode' does not switch itself on over a wrapped buffer."
  (md-table-align-tests--with-frame-width md-table-wrap-tests--frame
    (md-table-align-tests--with-buffer md-table-wrap-tests--wide
      (md-table-wrap-mode 1)
      (md-table-align--maybe-enable)
      (should-not md-table-align-mode)
      (should md-table-wrap-mode))))

(provide 'md-table-wrap-tests)

;;; md-table-wrap-tests.el ends here
