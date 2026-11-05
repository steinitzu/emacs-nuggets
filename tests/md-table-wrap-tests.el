;;; md-table-wrap-tests.el --- Tests for md-table-wrap -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Steinthor Palsson
;; SPDX-License-Identifier: GPL-3.0-or-later

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
(require 'md-table-inline)
(require 'nuggets-test-helpers)

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
  `(nuggets-test-with-frame-width md-table-wrap-tests--frame
     (nuggets-test-with-buffer ,text
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

(defvar md-table-wrap-tests--real nil
  "Positions whose own text `md-table-wrap-tests--drawn' showed, newest first.")

(defun md-table-wrap-tests--drawn (beg end)
  "The string redisplay draws for BEG..END, from this mode's overlays.
Each position whose own character is shown, for want of an overlay
covering it, is pushed onto `md-table-wrap-tests--real'."
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
          (push pos md-table-wrap-tests--real)
          (setq pos (1+ pos)))))
    (apply #'concat (nreverse parts))))

(defun md-table-wrap-tests--hidden-p (s i)
  "Non-nil if character I of S is invisible in this buffer."
  (let ((v (get-text-property i 'invisible s)))
    (and v (invisible-p v))))

(defun md-table-wrap-tests--render (s)
  "Screen lines of S, with `:align-to' stretches expanded to spaces, and
invisible characters (hidden markup) left out."
  (let ((lines nil) (line ""))
    (dotimes (i (length s))
      (let ((c (aref s i)) (d (get-text-property i 'display s)))
        (cond ((md-table-wrap-tests--hidden-p s i))
              ((and (consp d) (eq (car d) 'space))
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
  (nuggets-test-with-frame-width md-table-wrap-tests--frame
    (nuggets-test-with-buffer md-table-wrap-tests--wide
      (setq buffer-read-only t)
      (md-table-wrap-mode 1)
      (redisplay t)
      (should (> (length (md-table-wrap-tests--screen)) 8))
      (should-not (buffer-modified-p)))))

(ert-deftest md-table-wrap-test-read-only-text ()
  "Text carrying a `read-only' property, as chat transcripts use, is wrapped.
Measuring the table's indent copies such text into a work buffer."
  (nuggets-test-with-frame-width md-table-wrap-tests--frame
    (nuggets-test-with-read-only-text md-table-wrap-tests--list-item
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

(defconst md-table-wrap-tests--code-spans
  "| Site | Status |
|---|---|
| `db/acl/handlers.py:116` `widget_viewer_access_super_admin` (#271) | **port: in the fix-up commit (B3)** |
| `db/acl/functions/audit/audit_trigger.sql:32-59` reads `app.user_id/session_id/remote_ip` | metadata, not identity; attached to no table. |
"
  "A wrapped table whose rows start with code spans, as reported.")

(defun md-table-wrap-tests--undefaulted ()
  "Characters of this mode's strings that lack `default' under their face.
Each is (STRING . INDEX).  Such a character takes its unfaced attributes
from the buffer text its overlay is anchored at."
  (let (bad)
    (dolist (o (md-table-wrap-tests--own-overlays))
      (dolist (s (list (overlay-get o 'before-string) (overlay-get o 'display)))
        (when (stringp s)
          (dotimes (i (length s))
            (unless (memq 'default (flatten-tree (get-text-property i 'face s)))
              (push (cons s i) bad))))))
    bad))

(ert-deftest md-table-wrap-test-borders-ignore-their-anchor ()
  "Every drawn character carries `default', borders and rules included.
Rules and edges ride on line strings anchored where point is.  Without
`default' they took the face of the text there -- a code span's height in
a GUI -- so the bottom edge's junctions slid left of the pipes above, and
rules changed width as point moved through the table."
  (md-table-wrap-tests--with-table md-table-wrap-tests--code-spans
    (should-not (md-table-wrap-tests--undefaulted))
    (md-table-wrap-tests--goto "app.user_id")
    (md-table-wrap--post-command)
    (redisplay t)
    (should (md-table-wrap--row-lc md-table-wrap--prow))
    (should-not (md-table-wrap-tests--undefaulted))))

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

(ert-deftest md-table-wrap-test-no-real-text-on-a-table-line ()
  "A table line draws nothing of the buffer's own but row-ending newlines.
In particular a row's indentation is hidden, not shown: the grammar faces
a body row's indentation fixed-pitch and the header's not at all, so in
a GUI they differ in width, and a row's first line, drawn after its
real indentation, stood off the grid the other lines stretch to.  A
terminal draws both one column wide, so the invariant is the evidence."
  (md-table-wrap-tests--with-table md-table-wrap-tests--list-item
    (let ((md-table-wrap-tests--real nil)
          (r (md-table-wrap-tests--table-region)))
      ;; Unanchored rows, and the row holding point, anchored around it.
      (md-table-wrap-tests--screen)
      (md-table-wrap-tests--goto "then carry on")
      (md-table-wrap--post-command)
      (redisplay t)
      (md-table-wrap-tests--screen)
      (should (seq-every-p (lambda (p) (eq (char-after p) ?\n))
                           (seq-filter (lambda (p) (< p (cdr r)))
                                       md-table-wrap-tests--real))))))

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

(defconst md-table-wrap-tests--links
  "| PR | Change |
| --- | --- |
| [widgetco-backend-lib#218](https://github.com/ExampleWidgetOrg/widgetco-backend-lib/pull/218) | lib 0.50: optional formatting hooks, `default_style_id`, `linked_by_rule_id` override |
| [widgetco-platform-services#379](https://github.com/ExampleWidgetOrg/widgetco-platform-services/pull/379) | item label columns, item styles under the item's parent label, `GET /items` filters |
| [widgetco-platform-services#378](https://github.com/ExampleWidgetOrg/widgetco-platform-services/pull/378) | #350 follow-ups: paging fix, 404 gate, tests |
"
  "A table, as reported, whose link cells break inside words, and whose
rows leave one column's last screen lines blank.")

(defun md-table-wrap-tests--cursor ()
  "(LINE . COLUMN) of the cursor on the first table's screen lines."
  (let* ((r (md-table-wrap-tests--table-region))
         (s (md-table-wrap-tests--drawn (car r) (cdr r)))
         (i (text-property-not-all 0 (length s) 'cursor nil s)))
    (should i)
    ;; A cursor on hidden text isn't drawn there.
    (should-not (md-table-wrap-tests--hidden-p s i))
    (let ((lines (md-table-wrap-tests--render (substring s 0 i))))
      (cons (1- (length lines)) (string-width (car (last lines)))))))

(defvar md-table-wrap-tests--trail nil)

(defun md-table-wrap-tests--record ()
  "Push the cursor's place, without counting as a command: goal columns
carry over from the motion before."
  (interactive)
  (setq this-command last-command)
  (redisplay t)
  (push (md-table-wrap-tests--cursor) md-table-wrap-tests--trail))

(defvar md-table-wrap-tests--between nil
  "Function run between a press and the record of where it went.")

(defun md-table-wrap-tests--between ()
  "Run `md-table-wrap-tests--between' as an idle timer would, between
two commands: the motion before still counts as the last command."
  (interactive)
  (setq this-command last-command)
  (funcall md-table-wrap-tests--between))

(defun md-table-wrap-tests--walk (key n &optional between)
  "The cursor's places after each of N presses of KEY, in one macro.
BETWEEN, a function, runs after each press, before its place is read."
  (let ((md-table-wrap-tests--trail nil)
        (md-table-wrap-tests--between between)
        (map (make-sparse-keymap)))
    (define-key map (kbd "<f12>") #'md-table-wrap-tests--record)
    (define-key map (kbd "<f11>") #'md-table-wrap-tests--between)
    (let ((minor-mode-overriding-map-alist nil)
          (emulation-mode-map-alists (cons `((t . ,map)) emulation-mode-map-alists)))
      (md-table-wrap-tests--press
       (mapconcat #'identity
                  (make-list n (concat key (if between " <f11>" "") " <f12>")) " ")))
    (nreverse md-table-wrap-tests--trail)))

(ert-deftest md-table-wrap-test-vertical-motion-follows-the-screen ()
  "C-n from the header visits every screen line holding text, in order,
in the column it started in; C-p walks back the same way.  It steps
over the delimiter row and the rules, holds the column through words
broken mid-word, and stays in the column on a line where its cell is
blank, as the cursor on a short line would."
  (md-table-wrap-tests--with-table md-table-wrap-tests--links
    (let* ((lines (md-table-wrap-tests--screen))
           (text (cl-loop for l in lines for i from 0
                          when (string-prefix-p "│" l) collect i)))
      (should (= (length text) 14))
      (md-table-wrap-tests--goto "PR")
      (md-table-wrap-tests--press "C-f C-b")
      (should (equal (md-table-wrap-tests--cursor) '(1 . 2)))
      (let ((down (md-table-wrap-tests--walk "C-n" 13)))
        (should (equal (mapcar #'car down) (cdr text)))
        (should (seq-every-p (lambda (c) (= (cdr c) 2)) down)))
      (let ((up (md-table-wrap-tests--walk "C-p" 13)))
        (should (equal (mapcar #'car up) (cdr (reverse text))))
        (should (seq-every-p (lambda (c) (= (cdr c) 2)) up)))
      ;; Down the second column, whose last row ends a line early.
      (md-table-wrap-tests--goto "Change")
      (md-table-wrap-tests--press "C-f C-b")
      (let ((x (cdr (md-table-wrap-tests--cursor)))
            (down (md-table-wrap-tests--walk "C-n" 13)))
        (should (equal (mapcar #'car down) (cdr text)))
        (should (seq-every-p (lambda (c) (= (cdr c) x)) down))))))

(ert-deftest md-table-wrap-test-vertical-motion-survives-a-relayout ()
  "C-n down a column walks the same lines when every table is laid out
anew between presses, as a chat buffer printing just below a table
makes happen.  A re-layout makes every row anew; the line a blank cell
holds the cursor on must outlast it, or C-n sticks there."
  (md-table-wrap-tests--with-table md-table-wrap-tests--links
    (md-table-wrap-tests--goto "Change")
    (md-table-wrap-tests--press "C-f C-b")
    (let ((quiet (md-table-wrap-tests--walk "C-n" 13)))
      (md-table-wrap-tests--goto "Change")
      (md-table-wrap-tests--press "C-f C-b")
      (should (equal (md-table-wrap-tests--walk
                      "C-n" 13 (lambda ()
                                 (md-table-wrap--layout-all)
                                 (md-table-wrap--follow-point)
                                 ;; Inside a macro, redisplay leaves the
                                 ;; rows unbuilt; build them as it would.
                                 (jit-lock-fontify-now (point-min) (point-max))))
                     quiet)))))

(defun md-table-wrap-tests--hide-markup ()
  "Hide markup in cells, as `md-table-inline-mode' lets upstream do."
  (md-table-inline-mode 1)
  (markdown-ts-toggle-hide-markup)
  (should markdown-ts-hide-markup))

(defun md-table-wrap-tests--check-hidden-layout ()
  "The links table drawn with its markup hidden: every screen line of a
row shows some text, and C-n down the first column visits them all."
  (let* ((lines (md-table-wrap-tests--screen))
         (text (cl-loop for l in lines for i from 0
                        when (string-prefix-p "│" l) collect i)))
    ;; The markup hides: no bracket, no URL, no backtick drawn.
    (should-not (seq-some (lambda (l) (string-match-p "https\\|](\\|`" l)) lines))
    (should (seq-some (lambda (l) (string-match-p "│ widgetco-backend-" l)) lines))
    ;; A hidden URL leaves no line of its own.
    (dolist (i text)
      (should (string-match-p "[^│ ]" (nth i lines))))
    (md-table-wrap-tests--goto "PR")
    (md-table-wrap-tests--press "C-f C-b")
    (let ((down (md-table-wrap-tests--walk "C-n" (1- (length text)))))
      (should (equal (mapcar #'car down) (cdr text)))
      (should (seq-every-p (lambda (c) (= (cdr c) 2)) down)))))

(ert-deftest md-table-wrap-test-hidden-markup-takes-no-room ()
  "With markup hidden, cells are wrapped as they show: a link's URL is
measured as nothing, and C-n walks the lines that are drawn."
  (nuggets-test-with-frame-width md-table-wrap-tests--frame
    (nuggets-test-with-buffer md-table-wrap-tests--links
      (delete-other-windows)
      (md-table-wrap-tests--hide-markup)
      (md-table-wrap-mode 1)
      (redisplay t)
      (md-table-wrap-tests--check-hidden-layout))))

(ert-deftest md-table-wrap-test-hiding-markup-rewraps-the-table ()
  "Hiding markup in a table already drawn re-wraps it: refontified rows
are re-modelled, and the widths reallocated when idle."
  (md-table-wrap-tests--with-table md-table-wrap-tests--links
    (md-table-wrap-tests--hide-markup)
    (redisplay t)
    (md-table-wrap--idle-realloc)
    (redisplay t)
    (md-table-wrap-tests--check-hidden-layout)))

(ert-deftest md-table-wrap-test-point-steps-over-hidden-markup ()
  "C-f and C-b move through a link cell one shown character at a time:
point never rests on hidden markup, so every press moves the cursor."
  (md-table-wrap-tests--with-table md-table-wrap-tests--links
    (md-table-wrap-tests--hide-markup)
    (redisplay t)
    (md-table-wrap-tests--goto "[widgetco-backend-lib#218]")
    (md-table-wrap-tests--press "C-f C-b")
    (dolist (key '("C-f" "C-b"))
      (let ((places (cons (md-table-wrap-tests--cursor)
                          (md-table-wrap-tests--walk key 30))))
        (cl-loop for (a b) on places while b do (should-not (equal a b)))))))

(ert-deftest md-table-wrap-test-lines-added-far-away-keep-the-layout ()
  "A line printed below the table, outside any command, leaves its rows
be once the idle rescan finds the tables unchanged; a line that makes
a new table gets it laid out."
  (md-table-wrap-tests--with-table (concat md-table-wrap-tests--wide "\n\nTail.\n")
    (let ((row (aref (md-table-wrap--table-rows (car md-table-wrap--tables)) 2)))
      (save-excursion (goto-char (point-max)) (insert "More output.\n"))
      (md-table-wrap--idle-realloc)
      (md-table-wrap--rescan)
      (should (eq (aref (md-table-wrap--table-rows (car md-table-wrap--tables)) 2) row))
      (save-excursion (goto-char (point-max)) (insert "\n| x | y |\n|---|---|\n| 1 | 2 |\n"))
      (md-table-wrap--idle-realloc)
      (md-table-wrap--rescan)
      (should (= (length md-table-wrap--tables) 2)))))

(ert-deftest md-table-wrap-test-end-of-line-ends-at-the-last-text ()
  "C-e on a screen line whose last cell is blank there goes to the end
of the line's text, not into the blank cell; C-a, past the blank first
cell, to the start of the line's text."
  (md-table-wrap-tests--with-table md-table-wrap-tests--wide
    (md-table-wrap-tests--goto "The first item")
    (md-table-wrap-tests--press "C-f C-n C-e")
    (let* ((c (md-table-wrap-tests--cursor))
           (line (nth (car c) (md-table-wrap-tests--screen))))
      (should (string-match "of *│ *│\\'" line))
      (should (= (cdr c) (+ (match-beginning 0) 2)))
      (md-table-wrap-tests--press "C-a")
      (should (equal (md-table-wrap-tests--cursor) (cons (car c) 10))))))

(ert-deftest md-table-wrap-test-beginning-of-line-stays-in-the-screen-line ()
  "C-a goes to the start of the screen line holding point, not the row."
  (md-table-wrap-tests--with-table md-table-wrap-tests--wide
    (md-table-wrap-tests--goto "The first item")
    (md-table-wrap-tests--press "C-f C-n C-e")
    (let ((row md-table-wrap--prow) (line (md-table-wrap-tests--cursor-line)))
      (should (> line 3))
      (md-table-wrap-tests--press "C-a")
      (should (eq md-table-wrap--prow row))
      (should (= (md-table-wrap-tests--cursor-line) line)))))

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

(ert-deftest md-table-wrap-test-refontified-row-is-redrawn-under-the-cursor ()
  "Refontifying a built row redraws its copies, and the row holding point
keeps the cursor on the screen line it was on."
  (md-table-wrap-tests--with-table md-table-wrap-tests--wide
    (md-table-wrap-tests--goto "The first item")
    (md-table-wrap-tests--press "C-f C-n")
    (let ((line (md-table-wrap-tests--cursor-line))
          (drawn (seq-keep (lambda (o) (let ((s (overlay-get o 'before-string)))
                                          (and s (cons o s))))
                           (md-table-wrap-tests--own-overlays))))
      (should drawn)
      (font-lock-flush)
      (redisplay t)
      ;; New string objects, or the overlay replaced outright: the rows were
      ;; drawn again from their text.
      (should (seq-every-p (lambda (d) (or (null (overlay-buffer (car d)))
                                           (not (eq (overlay-get (car d) 'before-string)
                                                    (cdr d)))))
                           drawn))
      (should (= (md-table-wrap-tests--cursor-line) line)))))

;;;; Lazy building

(defconst md-table-wrap-tests--tall
  (concat "| Id | Note |\n|---|---|\n"
          (mapconcat (lambda (i)
                       (format "| r%d | Row %d says enough that it wraps onto a second \
line in a sixty-column window, every time. |" i i))
                     (number-sequence 1 300) "\n")
          "\n")
  "A 300-row table, far taller than any window.")

(defun md-table-wrap-tests--built ()
  "The first table's rows that have overlays, as indices."
  (cl-loop for r across (md-table-wrap--table-rows (car md-table-wrap--tables))
           for i from 0
           when (md-table-wrap--built-p r) collect i))

(defun md-table-wrap-tests--row-index (pos)
  (cl-position (md-table-wrap--row-at pos)
               (md-table-wrap--table-rows (car md-table-wrap--tables))))

(ert-deftest md-table-wrap-test-builds-only-what-is-shown ()
  "Of 300 rows, only those redisplay showed have overlays, and all of
those were drawn, since the window starts at the table."
  (md-table-wrap-tests--with-table md-table-wrap-tests--tall
    (let ((built (md-table-wrap-tests--built)))
      (should (memq 0 built))
      (should (memq 2 built))
      (should (< (length built) 30))
      ;; Two overlays per two-line row, plus a lead each, and nothing more.
      (should (< (length (md-table-wrap-tests--own-overlays)) 100)))))

(ert-deftest md-table-wrap-test-far-rows-are-evicted-and-come-back ()
  "Jumping to the end builds the rows there and tears down the top; going
back rebuilds the top from jit-lock, since eviction left it unfontified.
The neighbourhood kept is narrowed, so two windowfuls exceed it."
  (let ((md-table-wrap--keep-rows 15))
  (md-table-wrap-tests--with-table md-table-wrap-tests--tall
    (md-table-wrap-tests--press "M->")
    (let ((built (md-table-wrap-tests--built)))
      (should-not (memq 2 built))
      (should (memq (md-table-wrap-tests--row-index (window-start)) built))
      (should (memq 300 built))
      (should (< (length built) 100)))
    (md-table-wrap-tests--press "M-<")
    (should (memq 2 (md-table-wrap-tests--built)))
    ;; Eviction reads window starts before redisplay moves them, so the
    ;; end's rows go one command later.
    (md-table-wrap-tests--press "C-n")
    (let ((built (md-table-wrap-tests--built)))
      (should (memq 2 built))
      (should-not (memq 300 built))
      ;; The rebuilt rows are drawn to the grid again.
      (let ((lines (md-table-wrap-tests--render
                    (md-table-wrap-tests--drawn
                     (point-min)
                     (md-table-wrap--end
                      (aref (md-table-wrap--table-rows (car md-table-wrap--tables)) 4))))))
        (should (string-prefix-p "┌" (car lines)))
        (dolist (line lines)
          (should (equal (md-table-wrap-tests--border-columns line)
                         (md-table-wrap-tests--border-columns (car lines))))))))))

(ert-deftest md-table-wrap-test-next-line-onto-an-unbuilt-row ()
  "C-n into a row that was never drawn builds it and puts the cursor on it."
  (md-table-wrap-tests--with-table md-table-wrap-tests--tall
    (let* ((rows (md-table-wrap--table-rows (car md-table-wrap--tables)))
           (far (aref rows 150)))
      (should-not (md-table-wrap--built-p far))
      (goto-char (md-table-wrap--beg (aref rows 149)))
      (md-table-wrap-tests--press "C-n C-n C-n")
      (should (eq (md-table-wrap--row-at (point)) far))
      (should (md-table-wrap--built-p far))
      (should (cl-some (lambda (o)
                         (let ((s (overlay-get o 'before-string)))
                           (and s (text-property-not-all 0 (length s) 'cursor nil s))))
                       (cdr (md-table-wrap--row-ovs far)))))))

;;;; Lifecycle

(ert-deftest md-table-wrap-test-off-removes-everything ()
  "Turning the mode off leaves no overlay, hook or timer behind."
  (md-table-wrap-tests--with-table md-table-wrap-tests--wide
    (md-table-wrap-mode -1)
    (should-not (md-table-wrap-tests--own-overlays))
    (should-not (memq #'md-table-wrap--post-command post-command-hook))
    (should-not md-table-wrap--timer)
    (should-not md-table-wrap--tables)))

;;;; Geometry changes without a command

;; The tests run outside the command loop, so `post-command-hook' never
;; runs unless a test presses keys: a bare `redisplay' is a change that no
;; command follows.

(defun md-table-wrap-tests--check-fits ()
  "The first table's screen lines fit the window, on one column grid."
  (let* ((lines (md-table-wrap-tests--screen))
         (grid (md-table-wrap-tests--border-columns (car lines))))
    (should (> (length lines) 6))
    (should (= (length grid) 4))
    (dolist (line lines)
      (should (<= (string-width line) (window-body-width)))
      (should (equal (md-table-wrap-tests--border-columns line) grid)))))

(defun md-table-wrap-tests--owned-by-this-buffer ()
  "Every overlay and marker the layout holds belongs to this buffer."
  (let ((buf (current-buffer)))
    (should md-table-wrap--tables)
    (dolist (tbl md-table-wrap--tables)
      (cl-loop for r across (md-table-wrap--table-rows tbl)
               do (should (eq (marker-buffer (md-table-wrap--row-m r)) buf))
               (dolist (o (md-table-wrap--row-ovs r))
                 (should (eq (overlay-buffer o) buf)))))))

(ert-deftest md-table-wrap-test-enabled-before-display-fits-on-first-redisplay ()
  "A buffer whose mode came on before it had a window, as when a file is
opened, fits the window it is first shown in, with no command run.
Laid out windowless, it took an 80-column fallback budget."
  (nuggets-test-with-frame-width md-table-wrap-tests--frame
    (let ((buf (generate-new-buffer "*nuggets-test*")))
      (unwind-protect
          (progn
            (with-current-buffer buf
              (insert md-table-wrap-tests--wide)
              (goto-char (point-min))
              (markdown-ts-mode)
              (md-table-wrap-mode 1))
            (should-not (get-buffer-window buf t))
            (switch-to-buffer buf)
            (delete-other-windows)
            (redisplay t)
            (md-table-wrap-tests--check-fits))
        (kill-buffer buf)))))

(ert-deftest md-table-wrap-test-narrower-window-rewraps-before-redisplay ()
  "Splitting the window re-wraps the table for the narrower half on the
next redisplay, with no command run."
  (md-table-wrap-tests--with-table md-table-wrap-tests--wide
    (split-window-right)
    (redisplay t)
    (should (< (window-body-width) 40))
    (md-table-wrap-tests--check-fits)))

(ert-deftest md-table-wrap-test-face-remap-relays-out-before-redisplay ()
  "A face remap made without a command (screenshot.el's `buffer-face-set')
re-lays the table out on the next redisplay.  A terminal draws every
face one column wide, so the new layout can't look different here; the
check is that it was made with the remap in force."
  (md-table-wrap-tests--with-table md-table-wrap-tests--wide
    (let ((before (md-table-wrap-tests--own-overlays)))
      (buffer-face-set :weight 'bold)
      (redisplay t)
      (should (equal md-table-wrap--remap face-remapping-alist))
      (should-not (seq-intersection before (md-table-wrap-tests--own-overlays)))
      (md-table-wrap-tests--check-fits))))

(ert-deftest md-table-wrap-test-indirect-clone-gets-its-own-layout ()
  "An indirect clone lays its tables out with overlays and markers of its
own, and the base buffer's layout outlives the clone.  The clone copies
the base's local variables, `md-table-wrap--tables' among them, whose
rows' overlays and markers belong to the base."
  (md-table-wrap-tests--with-table md-table-wrap-tests--wide
    (let* ((base (current-buffer))
           (base-tables md-table-wrap--tables)
           (base-overlays (md-table-wrap-tests--own-overlays))
           (clone (clone-indirect-buffer nil nil)))
      (unwind-protect
          (progn
            (switch-to-buffer clone)
            (redisplay t)
            (should md-table-wrap-mode)
            (should-not (eq md-table-wrap--tables base-tables))
            (md-table-wrap-tests--owned-by-this-buffer)
            (dolist (o (md-table-wrap-tests--own-overlays))
              (should-not (memq o base-overlays)))
            (md-table-wrap-tests--check-fits))
        (kill-buffer clone))
      (switch-to-buffer base)
      (redisplay t)
      (should (eq md-table-wrap--tables base-tables))
      (md-table-wrap-tests--owned-by-this-buffer)
      (md-table-wrap-tests--check-fits))))

(ert-deftest md-table-wrap-test-screenshot-style-clone ()
  "What screenshot.el does: clone the buffer with `make-indirect-buffer',
narrow the clone to the table, set its face, and show it in a window,
with no command run.  The clone's table is laid out for its own face
and window."
  (md-table-wrap-tests--with-table md-table-wrap-tests--wide
    (let* ((r (md-table-wrap-tests--table-region))
           (clone (make-indirect-buffer (current-buffer) " *md-table-wrap-shot*" t t)))
      (unwind-protect
          (progn
            (with-current-buffer clone
              (narrow-to-region (car r) (1+ (cdr r)))
              (buffer-face-set :weight 'bold))
            (switch-to-buffer clone)
            (redisplay t)
            (should (equal md-table-wrap--remap face-remapping-alist))
            (md-table-wrap-tests--owned-by-this-buffer)
            (md-table-wrap-tests--check-fits))
        (kill-buffer clone)))))

(provide 'md-table-wrap-tests)

;;; md-table-wrap-tests.el ends here
