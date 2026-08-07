;;; md-file-anchor.el --- Follow anchors on Markdown file links -*- lexical-binding: t; -*-

;; Author: Steinthor Palsson
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: markdown, hypermedia, convenience

;;; Commentary:

;; Make a Markdown file link carrying a line or heading anchor --
;;
;;     [builder.py:392-400](../src/builder.py#L392-L400)
;;     [notes](notes.md#deferred-decisions)
;;
;; -- open the file and jump to the anchored place on \\[push-button] or a
;; click, instead of visiting a buffer for a file literally named
;; "builder.py#L392-L400".
;;
;; `markdown-ts-mode' dispatches a link button's action on the URL string:
;; in-buffer #fragment, mailto:, URI scheme, and a final catch-all that
;; passes everything else to `find-file' verbatim.  A file path with a
;; fragment falls into that catch-all whole -- the fragment is never split
;; off.  This package supplies the missing case: one advice that takes over
;; button creation for scheme-less URLs containing `#', opens the path part,
;; and interprets the anchor -- GitHub/GitLab-style line anchors jump to the
;; line (a range is momentarily highlighted); anything else is a heading
;; slug, resolved by upstream's own `markdown-ts--follow-fragment' when the
;; target is a `markdown-ts-mode' buffer.  See DESIGN.md.
;;
;; Usage:
;;
;;   (require 'md-file-anchor)
;;   (md-file-anchor-mode 1)

;;; Code:

(require 'pulse)

(declare-function markdown-ts--make-link-button "markdown-ts-mode")
(declare-function markdown-ts--follow-fragment "markdown-ts-mode")

(defgroup md-file-anchor nil
  "Follow anchors on file links in Markdown buffers."
  :group 'markdown
  :prefix "md-file-anchor-")

(defconst md-file-anchor--scheme-regexp "\\`[a-zA-Z][-a-zA-Z0-9+.]*:"
  "Regexp matching a URI scheme prefix, per RFC 3986.

Deliberately wider than upstream's lowercase-only \\=`[a-z]+: test: an
any-cased scheme is routed away from the file branch rather than into
it, which is the defensible reading, and the divergence is unreachable
from sanely-written Markdown.")

(defconst md-file-anchor--line-anchor-regexp
  "\\`L\\([0-9]+\\)\\(?:C[0-9]+\\)?\\(?:-L?\\([0-9]+\\)\\(?:C[0-9]+\\)?\\)?\\'"
  "Regexp matching a forge-style line anchor, sans the leading `#'.
Covers GitHub `L392', `L392-L400' and `L392C5-L400C10' (columns are
ignored) and GitLab `L392-400'.  Case-sensitive: a lowercase `l' is a
heading slug, not a line.")

(defun md-file-anchor-split (url)
  "Split URL at its first `#' into a cons (PATH . ANCHOR).
The `#' itself belongs to neither part.  URL without a `#' yields
\(URL . nil)."
  (if-let* ((hash (string-search "#" url)))
      (cons (substring url 0 hash) (substring url (1+ hash)))
    (cons url nil)))

(defun md-file-anchor-line-range (anchor)
  "Return the line range ANCHOR denotes as a cons (BEG . END), or nil.
ANCHOR is a fragment without its leading `#'.  A single-line anchor
yields BEG = END; a reversed range is normalised.  Nil means ANCHOR is
not a line anchor -- a heading slug, by definition."
  (let ((case-fold-search nil))
    (when (and (stringp anchor)
               (string-match md-file-anchor--line-anchor-regexp anchor))
      (let* ((beg (string-to-number (match-string 1 anchor)))
             (end (if (match-string 2 anchor)
                      (string-to-number (match-string 2 anchor))
                    beg)))
        (cons (min beg end) (max beg end))))))

(defun md-file-anchor--goto-lines (beg end)
  "Move to line BEG and momentarily highlight lines BEG through END.
Pushes the mark before moving, so \\[universal-argument] \\[set-mark-command] returns, mirroring
`markdown-ts--follow-fragment'.  Lines past end-of-buffer clamp to
end-of-buffer, where `forward-line' stops."
  (push-mark)
  (goto-char (point-min))
  (forward-line (1- beg))
  (let ((start (point))
        (finish (save-excursion
                  (forward-line (- end beg))
                  (line-end-position))))
    (recenter)
    (pulse-momentary-highlight-region start finish)))

(defun md-file-anchor--goto-heading (anchor)
  "Jump to the heading ANCHOR names, when this buffer can resolve it.
Delegates to upstream's `markdown-ts--follow-fragment', which owns the
slug rules, rather than re-implementing them.  In a buffer that is not
`markdown-ts-mode' the anchor is announced and ignored -- the file is
open, which is the bulk of the value."
  (if (and (derived-mode-p 'markdown-ts-mode)
           (fboundp 'markdown-ts--follow-fragment))
      (markdown-ts--follow-fragment anchor)
    (message "md-file-anchor: no way to resolve #%s in %s" anchor major-mode)))

(defun md-file-anchor-visit (url)
  "Open the file URL names, honouring a #line or #heading anchor.

If URL names an existing file whole -- a filename really containing
`#' -- it is opened verbatim, preserving what worked before this
package.  Otherwise URL is split at its first `#'; the path part is
found and the anchor interpreted: a line anchor jumps to the line, any
other anchor is a heading slug, an empty anchor is just the file."
  (if (file-exists-p url)
      (find-file url)
    (pcase-let ((`(,path . ,anchor) (md-file-anchor-split url)))
      (find-file path)
      (unless (member anchor '(nil ""))
        (if-let* ((range (md-file-anchor-line-range anchor)))
            (md-file-anchor--goto-lines (car range) (cdr range))
          (md-file-anchor--goto-heading anchor))))))

(defun md-file-anchor--handles-p (url)
  "Non-nil when URL is a scheme-less path carrying a `#' anchor.
Exactly the URLs upstream's dispatch would hand whole to `find-file'
while this package can do better.  In-buffer `#fragment' links and URLs
with a URI scheme are upstream's business."
  (let ((case-fold-search nil))
    (and (stringp url)
         (not (string-prefix-p "#" url))
         (not (string-match-p md-file-anchor--scheme-regexp url))
         (string-search "#" url)
         t)))

(defun md-file-anchor--make-button (orig beg end url)
  "Buttonize BEG..END for URL, taking over the file-with-anchor case.
Around advice for `markdown-ts--make-link-button' (ORIG); every other
URL shape is passed through untouched.  As upstream documents, no `face'
is passed to `make-text-button', which would clobber the face list
applied by `treesit-fontify-with-override'."
  (if (md-file-anchor--handles-p url)
      (make-text-button beg end
                        'action (lambda (_button) (md-file-anchor-visit url))
                        'help-echo url)
    (funcall orig beg end url)))

(defun md-file-anchor--reset-buffers ()
  "Rebuild the link buttons in every `markdown-ts-mode' buffer.
`jit-lock' will not revisit a region it considers fontified, so toggling
the mode must flush open buffers or their buttons keep the old action.
`font-lock-flush' suffices because `markdown-ts-mode' lists the button
properties, `action' included, in `font-lock-extra-managed-props'."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'markdown-ts-mode)
        (font-lock-flush)))))

;;;###autoload
(define-minor-mode md-file-anchor-mode
  "Follow line and heading anchors on file links in Markdown.

Upstream `markdown-ts-mode' passes a link destination like
\"builder.py#L392-L400\" to `find-file' whole, visiting a buffer for a
file of that literal name.  With this mode on, such a link opens
builder.py and jumps to line 392, momentarily highlighting the range;
\"notes.md#slug\" opens notes.md at that heading.  Links with a URI
scheme, in-buffer #fragment links and plain file links are untouched.

The mode is global because it works by advising a function, which is
global state; there is nothing buffer-local to switch on."
  :global t
  :group 'md-file-anchor
  (if md-file-anchor-mode
      (advice-add 'markdown-ts--make-link-button
                  :around #'md-file-anchor--make-button)
    (advice-remove 'markdown-ts--make-link-button
                   #'md-file-anchor--make-button))
  (md-file-anchor--reset-buffers))

(defun md-file-anchor-unload-function ()
  "Switch the mode off before `unload-feature' removes it.
Without this, unloading would leave the advice installed on a function
that outlives this package while its implementation goes void.
Returning nil leaves the standard unloading to `unload-feature'."
  (when md-file-anchor-mode
    (md-file-anchor-mode -1))
  nil)

(provide 'md-file-anchor)

;;; md-file-anchor.el ends here
