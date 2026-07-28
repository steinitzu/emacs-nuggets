;;; emacs-tools.el --- Loader for the emacs-tools collection -*- lexical-binding: t; -*-

;; Author: Steinthor Palsson
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience

;;; Commentary:

;; Loading this file puts every extension in this repository on `load-path',
;; so the whole collection is installable by pointing Emacs at this directory:
;;
;;   (add-to-list 'load-path "/path/to/emacs-tools")
;;   (require 'emacs-tools)
;;
;; Each extension lives in its own subdirectory and is then available via
;; `require', e.g. (require 'md-table-align).  Extensions are not loaded
;; eagerly; autoloads and `require' pull in only what you use.

;;; Code:

(defconst emacs-tools-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Root directory of the emacs-tools collection.")

(defconst emacs-tools-non-extension-directories '("tests" "hacks")
  "Directories under the repository root that hold Lisp but ship nothing.
`tests' is the test suite; `hacks' is untracked local scratch.  Neither
belongs on `load-path'.")

(defun emacs-tools-extension-directories ()
  "Return the directories holding individual extensions."
  (seq-filter
   (lambda (dir)
     (let ((name (file-name-nondirectory (directory-file-name dir))))
       (and (file-directory-p dir)
            (not (string-prefix-p "." name))
            (not (member name emacs-tools-non-extension-directories))
            (directory-files dir nil "\\.el\\'" t))))
   (directory-files emacs-tools-directory t "\\`[^.]" t)))

(defun emacs-tools-setup-load-path ()
  "Add every extension directory to `load-path'."
  (dolist (dir (emacs-tools-extension-directories))
    (add-to-list 'load-path dir)))

(emacs-tools-setup-load-path)

(provide 'emacs-tools)

;;; emacs-tools.el ends here
