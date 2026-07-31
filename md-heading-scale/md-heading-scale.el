;;; md-heading-scale.el --- Size Markdown headings by level -*- lexical-binding: t; -*-

;; Author: Steinthor Palsson
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: markdown, faces, convenience

;;; Commentary:

;; Render a level-1 heading large, a level-2 heading a little smaller, and so
;; on down to body size -- what `markdown-header-scaling' does in the MELPA
;; `markdown-mode', and what `markdown-ts-mode' has no option for.
;;
;; Almost nothing has to happen for this.  `markdown-ts-mode' already applies a
;; distinct face per level, `markdown-ts-heading-1' through
;; `markdown-ts-heading-6'; it just defines all six identically, so the level
;; it worked out is thrown away again in appearance.  This package gives those
;; faces a height.
;;
;; It does so with buffer-local face remapping rather than by editing the faces
;; themselves, so scaling is per-buffer, switching it off restores exactly what
;; was there before, and the heights are relative -- `text-scale-adjust' and
;; `mixed-pitch-mode' still work, with the ratios between levels preserved.
;;
;; Setext headings follow level 1: `markdown-ts-setext-heading' inherits
;; `markdown-ts-heading-1', and face remapping is followed through `:inherit'.
;;
;; Usage:
;;
;;   (require 'md-heading-scale)
;;   (add-hook 'markdown-ts-mode-hook #'md-heading-scale-mode)
;;
;; or turn it on everywhere:
;;
;;   (global-md-heading-scale-mode 1)
;;
;; See DESIGN.md.

;;; Code:

(require 'face-remap)

(defgroup md-heading-scale nil
  "Size Markdown headings according to their level."
  :group 'markdown
  :prefix "md-heading-scale-")

(defconst md-heading-scale-max-level 6
  "How many heading levels there are.
Fixed at six by CommonMark, not by `markdown-ts-mode', which defines
exactly that many heading faces.")

(defcustom md-heading-scale-values '(1.6 1.4 1.25 1.1 1.0 1.0)
  "Height multipliers for headings of level 1 through 6.

Each value multiplies the height the heading would otherwise have, so
scaling composes with `text-scale-adjust', with `mixed-pitch-mode', and
with a `:height' of your own on the `markdown-ts-heading-N' faces,
rather than overriding them.

A value of 1 leaves that level completely alone -- no remapping is
installed for it at all.  Levels past the end of the list are not scaled
either, so \\='(1.6) means \"enlarge level 1, leave the rest\".

The default ramp is gentler than `markdown-mode' uses for
`markdown-header-scaling-values', which is \\='(2.0 1.7 1.4 1.1 1.0 1.0)
-- set it to that for what `markdown-header-scaling' looks like.

Changing this re-applies it in every buffer where the mode is on."
  :type '(repeat (number :tag "Multiplier"))
  ;; Keeps `:set' from running while this file is still being loaded.
  :initialize #'custom-initialize-default
  :set (lambda (symbol value)
         (set-default symbol value)
         (md-heading-scale-refresh))
  :group 'md-heading-scale)

(defcustom md-heading-scale-modes '(markdown-ts-mode)
  "Modes `global-md-heading-scale-mode' switches the mode on in.
Derived modes count."
  :type '(repeat symbol)
  :group 'md-heading-scale)

(defvar-local md-heading-scale--cookies nil
  "Face remapping cookies installed in this buffer, newest first.
Removed by identity when the mode is switched off, so remappings from
elsewhere -- `mixed-pitch-mode', `text-scale-mode', another package --
are left as they are.")

(defun md-heading-scale--face (level)
  "Return the face `markdown-ts-mode' applies to a heading of LEVEL."
  (intern (format "markdown-ts-heading-%d" level)))

(defun md-heading-scale--factor (level)
  "Return the height multiplier for LEVEL, or nil when it is not scaled.
Nil for a level the list does not reach, and for a multiplier of 1 --
which is not the same as remapping it to 1.0: the face is then never
mentioned in `face-remapping-alist' at all.

The result is always a float, because that is what makes a `:height'
relative.  An integer one is an absolute size in units of 1/10 pt, so a
`2' left unfloated would not double a heading, it would render it at
0.2pt."
  (let ((factor (nth (1- level) md-heading-scale-values)))
    (and (numberp factor)
         (/= factor 1)
         (float factor))))

(defun md-heading-scale--clear ()
  "Remove every remapping this buffer installed."
  (mapc #'face-remap-remove-relative md-heading-scale--cookies)
  (setq md-heading-scale--cookies nil))

(defun md-heading-scale--apply ()
  "Install the remappings `md-heading-scale-values' calls for.
Any this buffer already had are removed first, so this doubles as the
way to take up a changed value."
  (md-heading-scale--clear)
  (dotimes (index md-heading-scale-max-level)
    (let* ((level (1+ index))
           (factor (md-heading-scale--factor level)))
      (when factor
        (push (face-remap-add-relative (md-heading-scale--face level)
                                       (list :height factor))
              md-heading-scale--cookies))))
  ;; Faces are resolved at display time, so nothing needs refontifying -- but
  ;; a visible buffer that is not otherwise changing needs to be told to
  ;; repaint, exactly as `text-scale-mode' tells it.
  (force-window-update (current-buffer)))

;;;###autoload
(define-minor-mode md-heading-scale-mode
  "Size Markdown headings according to their level.

Level 1 renders largest, dropping to body size, per
`md-heading-scale-values'.  Heights are relative, so this composes with
`text-scale-adjust' and `mixed-pitch-mode'.

Nothing in the buffer changes and no face is redefined: the heading
faces are remapped in this buffer only, and switching the mode off puts
`face-remapping-alist' back exactly as it was."
  :lighter " H↕"
  :group 'md-heading-scale
  (if md-heading-scale-mode
      (md-heading-scale--apply)
    (md-heading-scale--clear)
    (force-window-update (current-buffer))))

(defun md-heading-scale-refresh ()
  "Re-apply scaling in every buffer where the mode is on.
Called for you when `md-heading-scale-values' is set through Customize
or `setopt'; call it yourself after a plain `setq'."
  (interactive)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (bound-and-true-p md-heading-scale-mode)
        (md-heading-scale--apply)))))

(defun md-heading-scale--maybe-enable ()
  "Enable `md-heading-scale-mode' if this buffer's mode calls for it."
  (when (apply #'derived-mode-p md-heading-scale-modes)
    (md-heading-scale-mode 1)))

;;;###autoload
(define-globalized-minor-mode global-md-heading-scale-mode
  md-heading-scale-mode md-heading-scale--maybe-enable
  :group 'md-heading-scale)

(defun md-heading-scale-unload-function ()
  "Switch the mode off everywhere before `unload-feature' removes it.
Remappings live in `face-remapping-alist', which would otherwise keep
scaling buffers with no code left to switch it off.  Returning nil
leaves the standard unloading to `unload-feature'."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (bound-and-true-p md-heading-scale-mode)
        (md-heading-scale-mode -1))))
  nil)

(provide 'md-heading-scale)

;;; md-heading-scale.el ends here
