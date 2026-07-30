;;; emacs-tools.el --- Loader for the emacs-tools collection -*- lexical-binding: t; -*-

;; Author: Steinthor Palsson
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1"))
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

;; `unload-feature' sweeps the obarray for hook-like variables and removes
;; every function the feature defined, then does the same over every buffer's
;; buffer-local variables.  That is right when a feature is going away for
;; good: a hook left holding a now-void function signals in every buffer that
;; runs it.  It is wrong when the feature is coming straight back.  Hooks hold
;; *symbols*, so a redefined function needs no attention at all -- only an
;; unbound one would have been a problem, and after the reload it is bound
;; again.  Left alone, reloading quietly drops the `add-hook' calls in a user's
;; init file, and new buffers stop getting the mode.

(defun emacs-tools--feature-functions (feature)
  "Return the function symbols FEATURE's file defines.
These are exactly what `unload-feature' strips from hooks."
  (let (functions)
    (dolist (entry (cdr (feature-symbols feature)) (nreverse functions))
      (when (eq (car-safe entry) 'defun)
        (push (cdr entry) functions)))))

(defun emacs-tools--hook-like-p (symbol value)
  "Non-nil when SYMBOL holding VALUE is a hook `unload-feature' would sweep.
Mirrors its rule: a list-valued variable whose name ends in `-hook' or
`-hooks', or one of the abnormal hooks it knows by name."
  (or (and (consp value)
           (string-match-p "-hooks?\\'" (symbol-name symbol)))
      (memq symbol unload-feature-special-hooks)))

(defun emacs-tools--hook-depth (hook function local)
  "Return the depth FUNCTION was added to HOOK with, or 0.
LOCAL non-nil reads the buffer-local table.  `add-hook' keeps depths in
an uninterned symbol on HOOK's `hook--depth-alist' property; reading it
back is what keeps a restored `add-hook' from silently reordering a hook
whose entries were given an explicit depth -- an appended entry, most
commonly."
  (or (when-let* ((sym (get hook 'hook--depth-alist))
                  ((boundp sym)))
        (alist-get function (if local (symbol-value sym) (default-value sym))))
      0))

(defun emacs-tools--hook-registrations (functions)
  "Return where FUNCTIONS sit on hooks, as a list of (HOOK FN BUFFER DEPTH).
BUFFER is nil for a global registration.  The sweep mirrors
`unload-feature''s, so that whatever it is about to strip can be put back."
  (let (found)
    (mapatoms
     (lambda (sym)
       (when (boundp sym)
         (let ((value (ignore-errors (default-value sym))))
           (when (and (listp value) (emacs-tools--hook-like-p sym value))
             (dolist (func functions)
               (when (memq func value)
                 (push (list sym func nil
                             (emacs-tools--hook-depth sym func nil))
                       found))))))))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (dolist (entry (buffer-local-variables))
          (when (consp entry)
            (let ((sym (car entry))
                  (value (cdr entry)))
              (when (and (listp value) (emacs-tools--hook-like-p sym value))
                (dolist (func functions)
                  (when (memq func value)
                    (push (list sym func buffer
                                (emacs-tools--hook-depth sym func t))
                          found)))))))))
    (nreverse found)))

(defun emacs-tools--restore-hooks (registrations)
  "Re-add every one of REGISTRATIONS no longer in place.
Returns how many were restored.  Anything still present is left alone,
so a registration the reloaded file re-established itself is not
duplicated, and a buffer killed in the meantime is skipped."
  (let ((restored 0))
    (dolist (entry registrations restored)
      (let ((hook (nth 0 entry))
            (func (nth 1 entry))
            (buffer (nth 2 entry))
            (depth (nth 3 entry)))
        (when (or (null buffer) (buffer-live-p buffer))
          (with-current-buffer (or buffer (current-buffer))
            (let ((value (if buffer
                             (and (local-variable-p hook) (symbol-value hook))
                           (and (boundp hook) (default-value hook)))))
              (unless (and (listp value) (memq func value))
                (add-hook hook func depth (and buffer t))
                (setq restored (1+ restored))))))))))

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
    ;; Snapshot after the modes are off, so the hooks a mode installs for
    ;; itself are already gone and only genuine registrations -- an init
    ;; file's `add-hook' -- are captured.  Switching the modes back on
    ;; reinstates their own.
    (let ((hooks (emacs-tools--hook-registrations
                  (emacs-tools--feature-functions feature)))
          (restored 0))
      (when (featurep feature)
        ;; Forced: nothing here is depended on by other packages, and a
        ;; dependency check would only get in the way while iterating.
        (unload-feature feature t))
      (load source nil t)
      (setq restored (emacs-tools--restore-hooks hooks))
      (emacs-tools--set-modes records t)
      (message "Reloaded %s (%d buffer%s, %d hook%s restored)"
               feature
               (length (cdr records))
               (if (= 1 (length (cdr records))) "" "s")
               restored
               (if (= 1 restored) "" "s")))
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
