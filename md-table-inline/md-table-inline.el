;;; md-table-inline.el --- Inline markup inside Markdown table cells -*- lexical-binding: t; -*-

;; Author: Steinthor Palsson
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: markdown, faces, convenience

;;; Commentary:

;; Make inline markup work inside `markdown-ts-mode' pipe table cells.
;;
;; Upstream, a `code span`, **emphasis** or [link](url) in a table cell gets
;; no face, and `markdown-ts-toggle-hide-markup' leaves its delimiters
;; visible.  The cause is in the mode's parser plumbing: the `markdown-inline'
;; grammar only parses regions the range rules hand it, the mode's one rule
;; captures `inline' nodes, and the block grammar parses table cells into
;; `pipe_table_cell' nodes that contain no `inline' node at all.  So no
;; inline parse ever covers a cell, and every inline font-lock rule -- faces
;; and markup hiding alike -- has nothing to fire on.
;;
;; This mode appends one more range rule, handing `pipe_table_cell' nodes to
;; the `markdown-inline' parser the same way (`:local', one small parser per
;; node) the mode already hands it `inline' nodes.  Everything downstream --
;; faces, hide-markup, property cleanup -- is upstream's own machinery,
;; reused rather than reimplemented.  See DESIGN.md.
;;
;; Usage:
;;
;;   (add-hook 'markdown-ts-mode-hook #'md-table-inline-mode)
;;
;; or globally:
;;
;;   (global-md-table-inline-mode 1)

;;; Code:

(require 'treesit)
(require 'seq)

(defgroup md-table-inline nil
  "Inline markup inside Markdown table cells."
  :group 'markdown
  :prefix "md-table-inline-")

(defcustom md-table-inline-modes '(markdown-ts-mode)
  "Major modes in which `global-md-table-inline-mode' enables the mode."
  :type '(repeat symbol))

(defvar-local md-table-inline--settings nil
  "The range settings this buffer's mode appended, held for exact removal.
`treesit-range-settings' entries have no identity beyond `eq' on the
objects themselves, so switching off removes precisely what switching
on added -- never a structurally similar rule someone else installed.")

(defun md-table-inline--ready-p ()
  "Return non-nil when this buffer can parse table cells inline.
That needs the buffer to have a `markdown' parser -- i.e. be a real
`markdown-ts-mode' buffer -- and the `markdown-inline' grammar to be
loadable for the per-cell parsers."
  (and (treesit-parser-list nil 'markdown)
       (treesit-ready-p 'markdown-inline t)))

(defun md-table-inline--rules ()
  "Return range settings handing table cells to the inline parser.
`:local' matches the rule `markdown-ts-mode' installs for `inline'
nodes: each cell gets its own parser, so inline state cannot bleed
across cells, and the two settings coexist without either resetting the
other's ranges.  Delimiter cells are deliberately not captured -- their
dashes hold no markup worth parsing."
  (treesit-range-rules
   :embed 'markdown-inline
   :host 'markdown
   :local t
   '((pipe_table_cell) @markdown-inline)))

(defun md-table-inline--remove-parsers ()
  "Delete every local `markdown-inline' parser in the buffer.

Removing our range rule does not remove the per-cell parsers it
created: `treesit-update-ranges' only garbage-collects a local parser
whose overlay timestamp is older than the buffer's modified tick, so in
an unmodified buffer the orphans survive -- and font-lock finds local
parsers through their overlays, so cells would simply stay fontified.

All local `markdown-inline' parsers go, not just ours: telling a cell
parser from an upstream `inline'-node parser is guesswork, whereas
recreating the upstream ones is the single `treesit-update-ranges' call
that follows, now running only the rules still installed."
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when-let* ((parser (overlay-get ov 'treesit-parser)))
      (when (and (overlay-get ov 'treesit-parser-local-p)
                 (eq (treesit-parser-language parser) 'markdown-inline))
        (treesit-parser-delete parser)
        (delete-overlay ov))))
  (treesit-update-ranges (point-min) (point-max)))

;;;###autoload
(define-minor-mode md-table-inline-mode
  "Fontify and hide inline markup inside Markdown table cells.

`markdown-ts-mode' never hands table cells to its inline parser, so
markup in a cell gets no face and \\[markdown-ts-toggle-hide-markup]
leaves its delimiters showing.  This mode adds the missing parser
ranges; the faces and hiding themselves are `markdown-ts-mode's own."
  :lighter " TblMd"
  (if md-table-inline-mode
      (if (not (md-table-inline--ready-p))
          (progn
            (setq md-table-inline-mode nil)
            (message "md-table-inline: no `markdown' parser in this buffer"))
        (setq md-table-inline--settings (md-table-inline--rules))
        (setq treesit-range-settings
              (append treesit-range-settings md-table-inline--settings))
        (font-lock-flush))
    (when md-table-inline--settings
      (setq treesit-range-settings
            (seq-remove (lambda (setting)
                          (memq setting md-table-inline--settings))
                        treesit-range-settings))
      (setq md-table-inline--settings nil)
      (md-table-inline--remove-parsers)
      (font-lock-flush))))

(defun md-table-inline--maybe-enable ()
  "Enable `md-table-inline-mode' if this buffer's mode calls for it."
  (when (and (apply #'derived-mode-p md-table-inline-modes)
             (md-table-inline--ready-p))
    (md-table-inline-mode 1)))

;;;###autoload
(define-globalized-minor-mode global-md-table-inline-mode
  md-table-inline-mode md-table-inline--maybe-enable)

(defun md-table-inline-unload-function ()
  "Switch the mode off everywhere before `unload-feature' removes it.
Without this, unloading would leave range settings and per-cell parsers
installed with the functions that manage them gone.  Returning nil
leaves the standard unloading to `unload-feature'."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (bound-and-true-p md-table-inline-mode)
        (md-table-inline-mode -1))))
  nil)

(provide 'md-table-inline)

;;; md-table-inline.el ends here
