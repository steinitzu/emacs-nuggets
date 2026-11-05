;;; install-grammars.el --- Build the grammars the test suite needs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Steinthor Palsson
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Interactively, `markdown-ts-mode' registers its own grammar recipes and
;; offers to install them the first time a Markdown buffer opens.  Batch mode
;; cannot answer that prompt, so `make deps' builds them up front.
;;
;; The recipes are taken from `markdown-ts-mode' rather than repeated here, so
;; the test environment tracks the commit Emacs pins rather than drifting from
;; what users actually get.
;;
;; Kept as a file rather than inlined in the Makefile: an `--eval' spanning
;; several lines needs backslash continuations, which the shell passes through
;; literally inside single quotes and Emacs then chokes on.

;;; Code:

(require 'markdown-ts-mode)

(let ((dir (or (getenv "NUGGETS_GRAMMAR_DIR")
               (expand-file-name ".test-env/tree-sitter"))))
  (make-directory dir t)
  ;; Without this, the post-install check looks only in the default location
  ;; and warns at length about a grammar that installed perfectly well.
  (add-to-list 'treesit-extra-load-path (file-name-as-directory dir))
  (dolist (lang '(markdown markdown-inline))
    (treesit-install-language-grammar lang dir))
  (dolist (lang '(markdown markdown-inline))
    (unless (file-exists-p (expand-file-name (format "libtree-sitter-%s.so" lang) dir))
      (error "Grammar for %s was not installed into %s" lang dir)))
  (message "Installed markdown grammars into %s" dir))

;;; install-grammars.el ends here
