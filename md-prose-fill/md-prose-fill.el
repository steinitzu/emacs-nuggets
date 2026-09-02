;;; md-prose-fill.el --- Fill Markdown prose without narrowing the window -*- lexical-binding: t; -*-

;; Author: Steinthor Palsson
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: markdown, convenience

;;; Commentary:

;; Give prose a comfortable measure without taking the width away from
;; everything else.
;;
;; `visual-fill-column-mode' and `olivetti-mode' narrow text by setting window
;; margins.  Margins come out of the window's text area, so the narrowing is a
;; property of the window and nothing in the buffer can opt out of it: on a
;; full-screen frame a Markdown table that would have fitted is clipped to the
;; prose measure and has to be scrolled sideways to read.
;;
;; This package inverts that.  The window stays at its full width -- so tables,
;; code blocks and headings get the whole screen, exactly as they do with
;; `visual-fill-column-mode' switched off -- and prose paragraphs are broken
;; early, in the display only, at `md-prose-fill-column'.
;;
;; Nothing is inserted.  A break is a `display' property of "\n" on a space
;; that is already there, so buffer text is untouched, `buffer-substring' and
;; therefore copy and yank are unaffected, and it all works in a buffer locked
;; with a `read-only' text property.
;;
;; Because the fill column is absolute rather than a function of the window,
;; resizing a window invalidates nothing -- which is the structural advantage
;; over the margin approach.
;;
;; Use it with `visual-line-mode' and `visual-wrap-prefix-mode':
;;
;;   (add-hook 'markdown-ts-mode-hook #'visual-line-mode)
;;   (add-hook 'markdown-ts-mode-hook #'visual-wrap-prefix-mode)
;;   (add-hook 'markdown-ts-mode-hook #'md-prose-fill-mode)
;;
;; or turn the last one on everywhere:
;;
;;   (global-md-prose-fill-mode 1)
;;
;; `visual-wrap-prefix-mode' is optional -- without it, continuation lines
;; start at column 0, the same as they would without this package.
;;
;; Requires a `markdown' tree-sitter parser in the buffer; see
;; `markdown-ts-mode'.
;;
;; See DESIGN.md.

;;; Code:

(require 'treesit)
(require 'jit-lock)
(require 'visual-wrap)

(declare-function treesit-parser-list "treesit")
(declare-function treesit-query-capture "treesit")
(declare-function treesit-query-compile "treesit")

(defgroup md-prose-fill nil
  "Fill Markdown prose without narrowing the window."
  :group 'markdown
  :prefix "md-prose-fill-")

(defcustom md-prose-fill-column 80
  "Column that prose is filled to.

Every rendered line of a filled paragraph ends at or before this column,
including the indent a list item or block quote contributes -- so the
right edge of the text is straight regardless of nesting.

This is an absolute column, not a fraction of the window, which is what
makes a resize free: nothing has to be recomputed when the window
changes size.  In a window narrower than this the fill switches itself
off and the window edge takes over."
  :type 'integer
  :group 'md-prose-fill)

(defcustom md-prose-fill-modes '(markdown-ts-mode)
  "Modes `global-md-prose-fill-mode' switches the mode on in.
Derived modes count."
  :type '(repeat symbol)
  :group 'md-prose-fill)

;; Declared before its `define-minor-mode', which is at the bottom of the
;; file, so the functions above can test it.
(defvar md-prose-fill-mode)

(defvar-local md-prose-fill--state nil
  "What the last fill was computed against, besides the buffer text.
Compared against on every window change, so an ordinary resize costs a
comparison rather than a refontification.  See `md-prose-fill--state'
the function.")

;;;; Properties
;;
;; Two of them, because the two spans differ: the break is one character, the
;; prefix runs from there to the end of the logical line.  Each is marked with
;; a private property so clearing only ever removes what this package put in,
;; and never a `display' belonging to `md-bare-url' or `md-table-inline'.

(defconst md-prose-fill--break 'md-prose-fill-break
  "Property marking a space rendered as a line break.")

(defconst md-prose-fill--prefix 'md-prose-fill-prefix
  "Property marking text given a `line-prefix' by this package.")

(defun md-prose-fill--clear-property (marker properties beg end)
  "Remove PROPERTIES wherever MARKER is set between BEG and END."
  (let ((pos beg))
    (while (< pos end)
      (let ((next (next-single-property-change pos marker nil end)))
        (when (get-text-property pos marker)
          (remove-text-properties pos next properties))
        (setq pos next)))))

(defun md-prose-fill--clear-region (beg end)
  "Remove every break and prefix this package placed between BEG and END."
  (md-prose-fill--clear-property
   md-prose-fill--break (list 'display nil md-prose-fill--break nil) beg end)
  (md-prose-fill--clear-property
   md-prose-fill--prefix (list 'line-prefix nil md-prose-fill--prefix nil) beg end))

;;;; Geometry

(defun md-prose-fill--wide-enough-p ()
  "Return non-nil when a window is wide enough for the fill to make sense.

Judged against the widest window showing the buffer: the properties are
buffer-wide while windows are not, so a buffer shown both wide and
narrow is filled for the wide one.  With no window showing it there is
nothing being rendered, and the fill is left on so that text fontified
ahead of display does not have to be redone."
  (let ((windows (get-buffer-window-list nil nil t)))
    (or (null windows)
        (>= (apply #'max (mapcar #'window-body-width windows))
            md-prose-fill-column))))

(defun md-prose-fill--state ()
  "Return what the fill depends on besides the buffer text.

Two things.  Whether any window is wide enough to fill for at all, which
is the one piece of geometry that matters.  And
`buffer-invisibility-spec', because hidden text costs no columns
\(`md-prose-fill--width') and toggling what is hidden --
`markdown-ts-hide-markup' works exactly that way -- changes where every
break on the line belongs, without changing a character of text for
`jit-lock' to notice."
  (cons (md-prose-fill--wide-enough-p) buffer-invisibility-spec))

;;;; Discovery

(defun md-prose-fill--parser ()
  "Return this buffer's `markdown' tree-sitter parser, if any."
  (car (treesit-parser-list nil 'markdown)))

(defvar md-prose-fill--paragraph-query nil
  "Compiled query matching `paragraph' nodes.
Built on first use rather than at load time, for the reason
`md-table-align--table-query' gives: compiling needs the markdown
grammar, which may not be loadable when this file is.")

(defun md-prose-fill--paragraphs (beg end)
  "Return `paragraph' nodes overlapping the region BEG to END.

Paragraphs are the whole policy of this package.  A table, a fenced or
indented code block and a heading are all other node types, so they are
never broken; a list item and a block quote *contain* paragraphs, so
their prose is."
  (when-let* ((parser (md-prose-fill--parser))
              (root (treesit-parser-root-node parser)))
    (unless md-prose-fill--paragraph-query
      (setq md-prose-fill--paragraph-query
            (treesit-query-compile 'markdown '((paragraph) @para))))
    (mapcar #'cdr
            (treesit-query-capture root md-prose-fill--paragraph-query beg end))))

;;;; Filling

(defun md-prose-fill--indent (prefix)
  "Return the column a line rendered under PREFIX starts at.
PREFIX is a `wrap-prefix' value: the `(space :align-to (N . width))'
spec `visual-wrap-prefix-mode' builds, a literal string for a prefix it
repeats verbatim such as a block quote's, or nil."
  (cond
   ((null prefix) 0)
   ((stringp prefix) (string-width prefix))
   ((and (consp prefix) (eq (car prefix) 'space))
    (let ((align (plist-get (cdr prefix) :align-to)))
      (cond ((numberp align) (floor align))
            ((and (consp align) (numberp (car align))) (floor (car align)))
            (t 0))))
   (t 0)))

(defun md-prose-fill--code-spans (beg end)
  "Return the inline code spans between BEG and END, as ((START . END) ...).

A code span is one thing -- a command, a path, a symbol -- and breaking
inside it is what makes a shell line unreadable and unpasteable.  It is
treated as a single token instead.

Costs nothing on a line with no backtick in it, which is nearly all of
them.  `markdown-ts-mode' embeds `markdown-inline' with `:local t', so
its parsers exist only where something has asked for one; asking is what
`treesit-node-at' does, and it is how the mode reaches inline nodes
itself.  Walking backtick to backtick, and skipping to the end of each
span found, keeps that to one query per span."
  (when (treesit-ready-p 'markdown-inline t)
    (save-excursion
      (goto-char beg)
      (let ((spans nil))
        (while (search-forward "`" end t)
          (let* ((node (treesit-node-at (1- (point)) 'markdown-inline))
                 (span (and node
                            (treesit-parent-until
                             node
                             (lambda (n) (equal (treesit-node-type n) "code_span"))
                             t))))
            ;; A backtick that opens nothing is literal text; keep looking.
            (when span
              (push (cons (treesit-node-start span) (treesit-node-end span))
                    spans)
              (goto-char (max (point) (min end (treesit-node-end span)))))))
        (nreverse spans)))))

(defun md-prose-fill--in-span-p (pos spans)
  "Return non-nil when POS falls inside one of SPANS."
  (seq-some (lambda (span) (and (>= pos (car span)) (< pos (cdr span)))) spans))

(defun md-prose-fill--breakable-p (pos spans)
  "Return non-nil when POS is a space this package may render as a break.

Not one already carrying a `display' property: it belongs to something
else -- `md-bare-url' and `md-table-inline' both place them -- and
replacing it would fight that package for the character.  Not a hidden
one either, since a break nothing renders is no break.  And not one
inside a code span, per `md-prose-fill--code-spans'."
  (and (eq (char-after pos) ?\s)
       (null (get-char-property pos 'display))
       (not (invisible-p pos))
       (not (md-prose-fill--in-span-p pos spans))))

(defun md-prose-fill--width (beg end)
  "Return the columns the text from BEG to END occupies on screen.

Hidden text occupies none.  Counting it would misplace every break on a
line carrying an `invisible' overlay -- which is what a folded tool row
in a chat transcript is, and what `markdown-ts-hide-markup' makes of
markup characters."
  (let ((pos beg)
        (width 0))
    (while (< pos end)
      (if (invisible-p pos)
          (setq pos (next-single-char-property-change pos 'invisible nil end))
        (setq width (+ width (char-width (char-after pos)))
              pos (1+ pos))))
    width))

(defun md-prose-fill--break-position (start limit budget spans)
  "Return where to break the text from START, or nil for no break.

BUDGET is how many columns the line may occupy and SPANS are the code
spans not to break inside.  Normally the result is the last breakable
space that leaves the text before it inside the budget, and nil means
the rest of the text fits.

A token longer than the whole budget -- a URL, or a code span -- has no
such space.  It is not cut: it overflows to the window edge and wraps
there, as it would under `fill-column'.  But filling *resumes* after it,
at the first breakable space past the overflow, so one long token costs
one long line rather than turning off the fill for everything that
follows it."
  (let ((pos start)
        (width 0)
        (last nil))
    (while (and (< pos limit) (<= width budget))
      (if (invisible-p pos)
          ;; Hidden text renders nothing, so it costs no columns.
          (setq pos (next-single-char-property-change pos 'invisible nil limit))
        (when (and (> pos start) (md-prose-fill--breakable-p pos spans))
          (setq last pos))
        (setq width (+ width (char-width (char-after pos)))
              pos (1+ pos))))
    (cond
     ((<= width budget) nil)             ; what is left fits
     (last last)                         ; break inside the budget
     (t                                  ; a token wider than the budget
      (while (and (< pos limit) (not (md-prose-fill--breakable-p pos spans)))
        (setq pos (1+ pos)))
      (and (< pos limit) pos)))))

(defun md-prose-fill--fill-line (beg end prefix start-column)
  "Break the logical line from BEG to END at `md-prose-fill-column'.

PREFIX is the line's `wrap-prefix' value, reused as the `line-prefix' of
every line a break starts.  START-COLUMN is how many columns the line
already occupies before BEG -- a list item's marker, say, which is part
of the line but not part of the paragraph node -- and comes out of the
first line's budget so that it too ends at the fill column."
  (let ((indent (md-prose-fill--indent prefix))
        (spans (md-prose-fill--code-spans beg end))
        (start beg)
        (budget (- md-prose-fill-column start-column)))
    (while-let ((pos (and (< start end)
                          (> budget 0)
                          (md-prose-fill--break-position start end budget spans))))
      (put-text-property pos (1+ pos) 'display "\n")
      (put-text-property pos (1+ pos) md-prose-fill--break t)
      ;; The line after an injected break is a fresh line, not a
      ;; continuation, so `wrap-prefix' does not reach it and the indent has
      ;; to be claimed as a `line-prefix'.  Applied to the rest of the line
      ;; rather than to the next segment alone, so a later break inherits it
      ;; without a second application.
      (when prefix
        (put-text-property (1+ pos) end 'line-prefix prefix)
        (put-text-property (1+ pos) end md-prose-fill--prefix t))
      ;; Text after a break renders at the prefix column, so it has that
      ;; much less room before it reaches the same right edge.
      (setq start (1+ pos)
            budget (- md-prose-fill-column indent)))))

(defun md-prose-fill--fill-paragraph (node)
  "Fill the paragraph NODE, one logical line at a time.
Markdown source is often hard wrapped, so a paragraph is several logical
lines; filling them separately is also what keeps a break from being
computed across a hard line boundary."
  (save-excursion
    (goto-char (treesit-node-start node))
    (let ((limit (min (treesit-node-end node) (point-max))))
      (while (< (point) limit)
        (let* ((beg (point))
               (end (min limit (line-end-position)))
               ;; A paragraph inside a list item starts *after* the marker,
               ;; so the line is already this many columns wide at BEG.
               (start-column (md-prose-fill--width
                              (line-beginning-position) beg)))
          (when (< beg end)
            (md-prose-fill--fill-line
             beg end (get-text-property beg 'wrap-prefix) start-column))
          (forward-line 1))))))

(defun md-prose-fill--fill-region (beg end)
  "Re-fill every paragraph overlapping the region BEG to END."
  (with-silent-modifications
    (md-prose-fill--clear-region beg end)
    (when (md-prose-fill--wide-enough-p)
      ;; `visual-wrap-prefix-mode' registers itself at the end of
      ;; `jit-lock-functions' on purpose, so on a first pass over a chunk its
      ;; `wrap-prefix' may not be there to read yet.  Asking for it up front
      ;; is idempotent, and its own later pass will not undo the fill:
      ;; `visual-wrap--remove-properties' removes `wrap-prefix' and
      ;; `min-width', never `line-prefix'.
      (when (bound-and-true-p visual-wrap-prefix-mode)
        (save-excursion (visual-wrap-prefix-function beg end)))
      (dolist (node (md-prose-fill--paragraphs beg end))
        (md-prose-fill--fill-paragraph node)))))

(defun md-prose-fill--jit (beg end)
  "Fill entry point for `jit-lock', covering BEG to END.
The region is rounded out to whole lines, because a break is computed
from the start of a logical line and a chunk boundary lands anywhere."
  (let ((beg (save-excursion (goto-char beg) (line-beginning-position)))
        (end (save-excursion (goto-char end)
                             (if (bolp) (point) (line-beginning-position 2)))))
    (md-prose-fill--fill-region beg end)
    `(jit-lock-bounds ,beg . ,end)))

;;;; Geometry changes

(defun md-prose-fill--refill (&rest _)
  "Re-fill when something the fill was computed against has changed.

An absolute fill column means an ordinary resize changes nothing, so
this does nothing on one -- the comparison against
`md-prose-fill--state' is what keeps a hook that fires on every window
operation from turning into a refill of the buffer.

The two things that do matter are the width threshold, below which the
breaks would land past the window edge and wrap twice so the fill is
dropped, and a change in what is hidden, which moves every break on the
affected line."
  (when md-prose-fill-mode
    (let ((state (md-prose-fill--state)))
      (unless (equal state md-prose-fill--state)
        (setq md-prose-fill--state state)
        (with-silent-modifications
          (md-prose-fill--clear-region (point-min) (point-max)))
        (jit-lock-refontify)))))

;;;; Commands

(defun md-prose-fill-buffer ()
  "Fill the whole buffer now, rather than as it comes into view."
  (interactive)
  (unless md-prose-fill-mode
    (user-error "`md-prose-fill-mode' is not on in this buffer"))
  (md-prose-fill--fill-region (point-min) (point-max)))

(defun md-prose-fill-clear ()
  "Remove every break this package placed in the buffer."
  (interactive)
  (with-silent-modifications
    (save-restriction
      (widen)
      (md-prose-fill--clear-region (point-min) (point-max)))))

;;;###autoload
(define-minor-mode md-prose-fill-mode
  "Fill Markdown prose to `md-prose-fill-column' without narrowing the window.

Prose paragraphs are broken early in the display, so they keep a
readable measure while tables, code blocks and headings still get the
full width of the window -- which is what a margin-based package like
`visual-fill-column-mode' cannot do, margins being a property of the
window rather than of any region in it.

Buffer text is never modified: a break is a `display' property on a
space that is already there, so this works in read-only buffers and
leaves copy and yank alone.

Meant to be used with `visual-line-mode', and with
`visual-wrap-prefix-mode' for correct indents on wrapped list items and
block quotes.  Requires a `markdown' tree-sitter parser in the buffer."
  :lighter " ¶"
  :group 'md-prose-fill
  (if md-prose-fill-mode
      (if (not (md-prose-fill--parser))
          (progn
            (setq md-prose-fill-mode nil)
            (message "md-prose-fill: no `markdown' tree-sitter parser available"))
        (setq md-prose-fill--state (md-prose-fill--state))
        (jit-lock-register #'md-prose-fill--jit t)
        ;; `jit-lock-register' prepends, which would run the fill before
        ;; `font-lock-fontify-region' whenever the two share a pass -- and
        ;; before `visual-wrap-prefix-mode', which deliberately puts itself
        ;; last.  Re-adding at a late depth keeps registration's other
        ;; effects and only moves the hook entry.  The same reasoning as
        ;; `md-table-align-mode's registration.
        (remove-hook 'jit-lock-functions #'md-prose-fill--jit t)
        (add-hook 'jit-lock-functions #'md-prose-fill--jit 95 t)
        ;; Geometry is not something `jit-lock' watches.  Unlike a
        ;; margin-based package this is needed for one threshold only, and
        ;; `md-prose-fill--refill' compares before it acts.
        (add-hook 'window-configuration-change-hook #'md-prose-fill--refill nil t)
        (add-hook 'window-state-change-functions #'md-prose-fill--refill nil t)
        ;; Text fontified before we registered would otherwise never reach
        ;; our handler.  Re-marking keeps the work lazy: only what is or
        ;; becomes visible is filled.
        (jit-lock-refontify))
    (jit-lock-unregister #'md-prose-fill--jit)
    (remove-hook 'window-configuration-change-hook #'md-prose-fill--refill t)
    (remove-hook 'window-state-change-functions #'md-prose-fill--refill t)
    (setq md-prose-fill--state nil)
    (md-prose-fill-clear)))

(defun md-prose-fill--maybe-enable ()
  "Enable `md-prose-fill-mode' if this buffer's mode calls for it."
  (when (and (apply #'derived-mode-p md-prose-fill-modes)
             (md-prose-fill--parser))
    (md-prose-fill-mode 1)))

;;;###autoload
(define-globalized-minor-mode global-md-prose-fill-mode
  md-prose-fill-mode md-prose-fill--maybe-enable
  :group 'md-prose-fill)

(defun md-prose-fill-unload-function ()
  "Switch the mode off everywhere before `unload-feature' removes it.
Without this, unloading would strip the definitions while the injected
properties and the `jit-lock' registration were still installed.
Returning nil leaves the standard unloading to `unload-feature'."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (bound-and-true-p md-prose-fill-mode)
        (md-prose-fill-mode -1))))
  nil)

(provide 'md-prose-fill)

;;; md-prose-fill.el ends here
