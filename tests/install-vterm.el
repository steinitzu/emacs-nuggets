;;; install-vterm.el --- Install the vterm the test suite needs -*- lexical-binding: t; -*-

;;; Commentary:

;; termdex's tests drive real terminals, so they need a real `vterm' -- which
;; is not a plain Lisp package: it compiles `vterm-module.so' against libvterm
;; on first use, and asks before doing so.  Batch mode cannot answer that
;; prompt, hence `vterm-always-compile-module' here and `make deps' up front.
;;
;; Installed into `.test-env/elpa' rather than the user's own package
;; directory, so the suite neither depends on nor disturbs what they have.
;;
;; Needs cmake, a C compiler and libvterm's headers.  Without them the module
;; build fails, `vterm' does not load, and the termdex tests skip themselves
;; rather than failing the run.

;;; Code:

(require 'package)

(let ((dir (or (getenv "NUGGETS_ELPA_DIR")
               (expand-file-name ".test-env/elpa"))))
  (setq package-user-dir dir)
  (add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
  (package-initialize)
  (unless (package-installed-p 'vterm)
    (package-refresh-contents)
    (package-install 'vterm))
  ;; The module is built on the first `require', not by `package-install'.
  (setq vterm-always-compile-module t)
  (require 'vterm)
  (unless (locate-library "vterm-module")
    (error "vterm installed but its module did not build"))
  (message "Installed vterm into %s" dir))

;;; install-vterm.el ends here
