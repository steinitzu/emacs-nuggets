;;; md-bare-url.el --- Follow bare URLs in Markdown -*- lexical-binding: t; -*-

;; Author: Steinthor Palsson
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: markdown, hypermedia, convenience

;;; Commentary:

;; Make a plain URL in Markdown --
;;
;;     See https://example.com/foo for details.
;;
;; -- open in a browser on \\[push-button] or a click, the way a tagged
;; `[see](https://example.com/foo)' already does.
;;
;; `markdown-ts-mode' does almost all of this already: it buttonizes bare URLs
;; from a `jit-lock' handler, and `RET' and `mouse-1' reach `push-button' there
;; just as they do on a tagged link.  What it gets wrong is the destination.
;; It scans with two regexps, `goto-address-url-regexp' then
;; `goto-address-mail-regexp', and decides whether to prefix "mailto:" with
;;
;;     (if (eq uri-start 0) uri (concat "mailto:" uri))
;;
;; where `uri-start' is a buffer position.  Buffer positions start at 1, so the
;; test is never true and *every* bare URI is treated as an email address.  A
;; bare https:// URL is handed to `url-mail-command' instead of `browse-url',
;; and no browser opens.  (Bare email addresses come out right, by accident.)
;;
;; So this package repairs rather than reimplements: one advice, which strips a
;; "mailto:" prefix only when the remainder carries its own URI scheme.  A real
;; `mailto:' URL can never look like that, and once upstream is fixed nothing
;; will -- the advice then does nothing, rather than pinning a stale copy of a
;; function that has moved on.  See DESIGN.md.
;;
;; Usage:
;;
;;   (require 'md-bare-url)
;;   (md-bare-url-mode 1)

;;; Code:

(declare-function markdown-ts--make-link-button "markdown-ts-mode")

(defgroup md-bare-url nil
  "Follow bare URLs in Markdown buffers."
  :group 'markdown
  :prefix "md-bare-url-")

(defconst md-bare-url--double-scheme-regexp
  "\\`mailto:\\([a-zA-Z][-a-zA-Z0-9+.]*:\\)"
  "Regexp matching a \"mailto:\" URL whose body is itself a URI.

Only the upstream bug this package works around can produce such a
string.  A bare email address cannot: `goto-address-mail-regexp' admits
no `:', so neither it nor the \"mailto:\" that
`markdown-ts--fontify-autolink' prepends to an email autolink can grow a
second scheme.  Nor can an explicit [x](mailto:a@b.com), whose
destination is passed through verbatim.")

(defun md-bare-url-destination (url)
  "Return the URL a Markdown link button should really point at.
Strip the \"mailto:\" that `markdown-ts--fontify-bare-uri' prefixes to
every bare URI when URL carries a scheme of its own.  Any other URL --
including a genuine mailto: address -- is returned unchanged."
  (if (and (stringp url)
           (let ((case-fold-search nil))
             (string-match-p md-bare-url--double-scheme-regexp url)))
      (substring url (length "mailto:"))
    url))

(defun md-bare-url--filter-args (args)
  "Repair the URL in ARGS for `markdown-ts--make-link-button'.
ARGS is (BEG END URL)."
  (list (nth 0 args) (nth 1 args) (md-bare-url-destination (nth 2 args))))

(defun md-bare-url--reset-buffers ()
  "Rebuild the link buttons in every `markdown-ts-mode' buffer.

Buttons are text properties that `jit-lock' has already applied, and it
will not revisit a region it considers fontified -- so switching this
mode on or off would otherwise leave open buffers holding buttons built
under the old behaviour.

`font-lock-flush' suffices only because `markdown-ts-mode' puts `button',
`category', `action' and `help-echo' in `font-lock-extra-managed-props'.
The flush therefore removes the `button' property, which in turn releases
the `(get-text-property uri-start \\='button)' guard in
`markdown-ts--fontify-bare-uri', and the next redisplay rebuilds the
button from scratch."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'markdown-ts-mode)
        (font-lock-flush)))))

;;;###autoload
(define-minor-mode md-bare-url-mode
  "Send bare URLs in Markdown to the browser rather than the mail client.

This corrects a `markdown-ts-mode' bug in which every bare URI is
buttonized as if it were an email address, so pressing \\[push-button] on
a plain https:// URL composes mail instead of browsing (or fails with a
void `url-mail-command').  Tagged links, <autolinks> and bare email
addresses are unaffected -- they already work.

The mode is global because it works by advising a function, which is
global state; there is nothing buffer-local to switch on."
  :global t
  :group 'md-bare-url
  (if md-bare-url-mode
      (advice-add 'markdown-ts--make-link-button
                  :filter-args #'md-bare-url--filter-args)
    (advice-remove 'markdown-ts--make-link-button
                   #'md-bare-url--filter-args))
  (md-bare-url--reset-buffers))

(defun md-bare-url-unload-function ()
  "Switch the mode off before `unload-feature' removes it.
Without this, unloading would strip `md-bare-url--filter-args' while the
advice referring to it was still installed on a function that outlives
this package.  Returning nil leaves the standard unloading to
`unload-feature'."
  (when md-bare-url-mode
    (md-bare-url-mode -1))
  nil)

(provide 'md-bare-url)

;;; md-bare-url.el ends here
