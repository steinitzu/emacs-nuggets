;;; install-ghostel.el --- Install the ghostel the test suite needs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Steinthor Palsson
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; termdex's tests drive real terminals of every backend it supports, and
;; ghostel, like vterm, is not a plain Lisp package: it needs a native module.
;; ghostel offers to fetch a pre-built one from its GitHub releases on first
;; interactive use, which batch mode cannot answer, so the download is asked
;; for here instead.
;;
;; Installed into `.test-env/elpa' rather than the user's own package
;; directory, so the suite neither depends on nor disturbs what they have.
;;
;; Without network access, or on a platform ghostel publishes no binary for,
;; the module is missing, `ghostel' does not load, and the ghostel half of the
;; termdex tests skips itself rather than failing the run.

;;; Code:

(require 'package)

(let ((dir (or (getenv "NUGGETS_ELPA_DIR")
               (expand-file-name ".test-env/elpa"))))
  (setq package-user-dir dir)
  (add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
  (package-initialize)
  (unless (package-installed-p 'ghostel)
    (package-refresh-contents)
    (package-install 'ghostel))
  ;; Loading ghostel never downloads; the module is fetched on first use,
  ;; after a prompt this skips.
  (require 'ghostel-module-install)
  (let ((package-dir (file-name-directory (locate-library "ghostel"))))
    (unless (locate-library "ghostel-module")
      (ghostel--download-module package-dir)))
  (unless (locate-library "ghostel-module")
    (error "ghostel installed but its module could not be fetched"))
  (message "Installed ghostel into %s" dir))

;;; install-ghostel.el ends here
