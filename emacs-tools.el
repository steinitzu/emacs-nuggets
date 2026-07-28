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
;;
;; While developing an extension, `M-x emacs-tools-reload' reloads it in a
;; live session without the state a plain `load' would leave behind.

;;; Code:

(require 'loadhist)
(require 'seq)

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

;;;; Reloading during development
;;
;; `load' on its own is not enough to pick up an edit:
;;
;; - `defvar' and `defcustom' do not reassign a variable that is already
;;   bound, so a changed default silently keeps its old value -- and if the
;;   meaning of that variable changed, the stale value is reinterpreted
;;   rather than rejected;
;; - overlays, hooks and `jit-lock' registrations installed by the previous
;;   definition survive;
;; - a stale `.elc' shadows the `.el' you just edited.
;;
;; `unload-feature' fixes the first two by unbinding everything the file
;; defined; loading the `.el' path explicitly fixes the third.

(defun emacs-tools-features ()
  "Return the features this collection's extensions provide.
The loader itself is excluded: unloading `emacs-tools' would remove the
very functions doing the unloading."
  (let (features)
    (dolist (dir (emacs-tools-extension-directories) (nreverse features))
      (dolist (file (directory-files dir nil "\\.el\\'"))
        (push (intern (file-name-base file)) features)))))

(defun emacs-tools-loaded-features ()
  "Return this collection's features that are currently loaded."
  (seq-filter #'featurep (emacs-tools-features)))

(defun emacs-tools--definitions (feature)
  "Return the symbols defined by FEATURE's file."
  (seq-filter #'symbolp (cdr (feature-symbols feature))))

(defun emacs-tools--minor-modes (feature)
  "Return the minor modes FEATURE defines, global ones included."
  (seq-filter (lambda (sym) (memq sym minor-mode-list))
              (emacs-tools--definitions feature)))

(defun emacs-tools--active-modes (modes)
  "Return which of MODES are switched on, as (GLOBAL . LOCAL).
GLOBAL is a list of mode symbols; LOCAL is a list of (BUFFER . MODE)."
  (let (global local)
    (dolist (mode modes)
      (when (and (boundp mode) (default-value mode))
        (push mode global)))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (dolist (mode modes)
          (when (and (local-variable-p mode) (symbol-value mode))
            (push (cons buffer mode) local)))))
    (cons (nreverse global) (nreverse local))))

(defun emacs-tools--set-modes (records enable)
  "Switch the modes in RECORDS on when ENABLE is non-nil, off otherwise.
Globals are enabled first so a globalized mode can set its buffers up,
and disabled last so turning one off does not pre-empt the per-buffer
pass."
  (let ((arg (if enable 1 -1))
        (globals (car records))
        (locals (cdr records)))
    (when enable
      (dolist (mode globals)
        (when (fboundp mode) (funcall mode arg))))
    (dolist (entry locals)
      (when (and (buffer-live-p (car entry)) (fboundp (cdr entry)))
        (with-current-buffer (car entry) (funcall (cdr entry) arg))))
    (unless enable
      (dolist (mode globals)
        (when (fboundp mode) (funcall mode arg))))))

;;;###autoload
(defun emacs-tools-reload (feature)
  "Reload FEATURE from source, discarding state a plain `load' would keep.

FEATURE is unloaded first, which unbinds every variable and function its
file defined, so changed `defcustom' and `defvar' defaults actually take
effect.  The `.el' source is then loaded explicitly, bypassing any stale
byte-compiled file.

Minor modes from FEATURE that are currently on are switched off before
the unload and back on afterwards, so their buffers are rebuilt by the
new definitions rather than left holding overlays and hooks from the old
ones.

Interactively, complete over this collection's loaded features."
  (interactive
   (list (intern (completing-read
                  "Reload feature: "
                  (or (emacs-tools-loaded-features)
                      (user-error "No emacs-tools features are loaded"))
                  nil t))))
  (let* ((modes (emacs-tools--minor-modes feature))
         (records (emacs-tools--active-modes modes))
         (source (or (locate-file (symbol-name feature) load-path '(".el"))
                     (user-error "No .el source on `load-path' for %s" feature))))
    (emacs-tools--set-modes records nil)
    (when (featurep feature)
      ;; Forced: nothing here is depended on by other packages, and a
      ;; dependency check would only get in the way while iterating.
      (unload-feature feature t))
    (load source nil t)
    (emacs-tools--set-modes records t)
    (message "Reloaded %s (%d buffer%s restored)"
             feature
             (length (cdr records))
             (if (= 1 (length (cdr records))) "" "s"))
    feature))

;;;###autoload
(defun emacs-tools-reload-all ()
  "Reload every loaded extension in this collection."
  (interactive)
  (let ((features (emacs-tools-loaded-features)))
    (unless features
      (user-error "No emacs-tools features are loaded"))
    (dolist (feature features)
      (emacs-tools-reload feature))
    (message "Reloaded %s" (mapconcat #'symbol-name features ", "))))

(provide 'emacs-tools)

;;; emacs-tools.el ends here
