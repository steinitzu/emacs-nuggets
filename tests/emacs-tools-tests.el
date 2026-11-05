;;; emacs-tools-tests.el --- Tests for the collection loader -*- lexical-binding: t; -*-

;;; Commentary:

;; Exercises `emacs-tools-reload' against a real extension in a real buffer:
;; the mode is on, the buffer's table is drawn, an option has been left at a
;; stale value, and the reload has to put all of that right.
;;
;; The reload genuinely unloads and re-loads `md-table-wrap' mid-test, so
;; these run against the same definitions everything else does.

;;; Code:

(require 'ert)
(require 'emacs-tools)
(require 'md-table-wrap)
(require 'emacs-tools-test-helpers)

(defconst emacs-tools-tests--table
  "| Name | Qty |
|:-----|----:|
| apple | 3 |
| fig | 12 |
"
  "A table for `md-table-wrap' to draw.")

(defun emacs-tools-tests--overlays ()
  "The overlays `md-table-wrap' has drawn in the current buffer."
  (seq-filter (lambda (ov) (overlay-get ov 'md-table-wrap))
              (overlays-in (point-min) (point-max))))

;;;; Discovery

(ert-deftest emacs-tools-test-features-lists-extensions-only ()
  "Extension features are discoverable; infrastructure is not."
  (should (memq 'md-table-wrap (emacs-tools-features)))
  (should (memq 'md-table-wrap (emacs-tools-loaded-features)))
  ;; Unloading the loader would remove the functions doing the unloading.
  (should-not (memq 'emacs-tools (emacs-tools-features)))
  ;; The suite and the scratch directory are not extensions.
  (should-not (memq 'md-table-wrap-tests (emacs-tools-features)))
  (should-not (memq 'emacs-tools-test-helpers (emacs-tools-features)))
  (should-not (memq 'md-font-diagnose (emacs-tools-features))))

(ert-deftest emacs-tools-test-finds-minor-modes-of-a-feature ()
  "Both the buffer-local and the globalized mode are found."
  (let ((modes (emacs-tools--minor-modes 'md-table-wrap)))
    (should (memq 'md-table-wrap-mode modes))
    (should (memq 'global-md-table-wrap-mode modes))))

;;;; Reloading

(ert-deftest emacs-tools-test-reload-resets-stale-option-values ()
  "Reloading restores changed defaults.

`defcustom' does not reassign a variable that is already bound, so a
plain `load' leaves the old value in place -- the failure this command
exists to prevent."
  (emacs-tools-test-with-buffer emacs-tools-tests--table
    (md-table-wrap-mode 1)
    (let ((cap md-table-wrap-word-cap)
          (style md-table-wrap-style))
      (unwind-protect
          (progn
            ;; Stand in for a session still holding an older version's values.
            (setq md-table-wrap-word-cap 7)
            (setq md-table-wrap-style 'ascii)
            (emacs-tools-reload 'md-table-wrap)
            (should (= md-table-wrap-word-cap 20))
            (should (eq md-table-wrap-style 'box)))
        (setq md-table-wrap-word-cap cap)
        (setq md-table-wrap-style style)))))

(ert-deftest emacs-tools-test-reload-keeps-modes-on-and-redraws ()
  "A buffer with the mode on comes back on, with its table drawn."
  (emacs-tools-test-with-buffer emacs-tools-tests--table
    (md-table-wrap-mode 1)
    (redisplay t)
    (emacs-tools-reload 'md-table-wrap)
    (should md-table-wrap-mode)
    (redisplay t)
    (should (emacs-tools-tests--overlays))))

(ert-deftest emacs-tools-test-reload-leaves-modes-off-that-were-off ()
  "Reloading does not switch the mode on in buffers that had it off."
  (emacs-tools-test-with-buffer emacs-tools-tests--table
    (should-not (bound-and-true-p md-table-wrap-mode))
    (emacs-tools-reload 'md-table-wrap)
    (should-not (bound-and-true-p md-table-wrap-mode))))

(ert-deftest emacs-tools-test-reload-drops-overlays-from-old-definition ()
  "No overlay outlives the reload that replaced its code."
  (emacs-tools-test-with-buffer emacs-tools-tests--table
    (md-table-wrap-mode 1)
    (redisplay t)
    (let ((before (emacs-tools-tests--overlays)))
      (should before)
      (emacs-tools-reload 'md-table-wrap)
      (redisplay t)
      ;; Fresh overlays are expected; the previous objects must be gone.
      (dolist (ov before)
        (should-not (overlay-buffer ov))))))

;;;; Compiling

(defun emacs-tools-tests--source (feature)
  (locate-file (symbol-name feature) load-path '(".el")))

(ert-deftest emacs-tools-test-reload-compiles ()
  "A reload leaves the extension running compiled, from a fresh `.elc'
next to its source, so the next start loads it compiled too."
  (emacs-tools-test-with-buffer emacs-tools-tests--table
    (md-table-wrap-mode 1)
    (emacs-tools-reload 'md-table-wrap)
    (let* ((source (emacs-tools-tests--source 'md-table-wrap))
           (elc (concat source "c")))
      (should (compiled-function-p (symbol-function 'md-table-wrap--show-row)))
      (should (equal (symbol-file 'md-table-wrap--show-row 'defun) elc))
      (should (file-exists-p elc))
      (should-not (file-newer-than-file-p source elc))
      (should md-table-wrap-mode))))

(ert-deftest emacs-tools-test-reload-can-load-source ()
  "With `emacs-tools-reload-compile' off, a reload loads the source."
  (let ((emacs-tools-reload-compile nil))
    (emacs-tools-reload 'md-table-wrap)
    (should-not (compiled-function-p (symbol-function 'md-table-wrap--show-row))))
  ;; Leave it compiled for the suites after this one.
  (emacs-tools-reload 'md-table-wrap))

(ert-deftest emacs-tools-test-failed-compile-removes-the-old-elc ()
  "A file that doesn't compile has no `.elc' left to shadow it."
  (let* ((dir (make-temp-file "emacs-tools-test" t))
         (source (expand-file-name "broken-ext.el" dir))
         (elc (concat source "c")))
    (unwind-protect
        (progn
          (with-temp-file source (insert ";;; -*- lexical-binding: t -*-\n(defun broken (\n"))
          (with-temp-file elc (insert ";; an old build\n"))
          (should-not (emacs-tools--compile source))
          (should-not (file-exists-p elc)))
      (delete-directory dir t))))

(ert-deftest emacs-tools-test-loader-recompiles-a-stale-elc ()
  "An `.elc' older than its source is rebuilt when the loader starts:
`require' would load the stale one."
  (let* ((source (emacs-tools-tests--source 'md-table-wrap))
         (elc (concat source "c")))
    (should (emacs-tools--compile source))
    ;; As after an edit made without a reload.
    (set-file-times elc (time-subtract (file-attribute-modification-time
                                        (file-attributes source))
                                       100))
    (should (file-newer-than-file-p source elc))
    (emacs-tools--refresh-stale-elc)
    (should (file-exists-p elc))
    (should-not (file-newer-than-file-p source elc))))

(ert-deftest emacs-tools-test-reload-rejects-unknown-feature ()
  "An unknown feature is reported rather than silently doing nothing."
  (should-error (emacs-tools-reload 'no-such-emacs-tools-feature)
                :type 'user-error))

;;;; Unload hook

(ert-deftest emacs-tools-test-unload-function-cleans-up-overlays ()
  "`unload-feature' alone leaves no overlays behind.
`md-table-wrap-unload-function' switches the mode off first, so the
definitions are not stripped out from under live overlays."
  (emacs-tools-test-with-buffer emacs-tools-tests--table
    (md-table-wrap-mode 1)
    (redisplay t)
    (let ((buffer (current-buffer)))
      (unwind-protect
          (progn
            (unload-feature 'md-table-wrap t)
            (with-current-buffer buffer
              (should-not (emacs-tools-tests--overlays))))
        ;; Put the package back for the rest of the suite.
        (load (locate-file "md-table-wrap" load-path '(".el")) nil t)))))

;;;; Hook registrations must survive a reload
;;
;; `unload-feature' strips a feature's functions from every hook, because a
;; hook left holding a void function signals in every buffer that runs it.
;; Reloading puts the function straight back, so the strip is pure loss: it
;; silently drops the `add-hook' calls in an init file, and new buffers stop
;; getting the mode.

(defvar emacs-tools-tests--sample-hook nil
  "A hook variable for reload tests, named so `unload-feature' sweeps it.")

(defmacro emacs-tools-tests--with-clean-hook (&rest body)
  "Run BODY with `emacs-tools-tests--sample-hook' empty, and restore it."
  (declare (indent 0) (debug t))
  `(let ((global (default-value 'emacs-tools-tests--sample-hook)))
     (unwind-protect
         (progn (setq-default emacs-tools-tests--sample-hook nil) ,@body)
       (setq-default emacs-tools-tests--sample-hook global))))

(ert-deftest emacs-tools-test-unload-alone-strips-hooks ()
  "The baseline the reload has to compensate for, so the tests below bite."
  (emacs-tools-tests--with-clean-hook
    (add-hook 'emacs-tools-tests--sample-hook #'md-table-wrap-mode)
    (should (memq #'md-table-wrap-mode emacs-tools-tests--sample-hook))
    (unwind-protect
        (progn
          (unload-feature 'md-table-wrap t)
          (should-not (memq #'md-table-wrap-mode
                            emacs-tools-tests--sample-hook)))
      ;; Whatever the assertion did, put the feature back for everything else.
      (load (locate-file "md-table-wrap" load-path '(".el")) nil t))))

(ert-deftest emacs-tools-test-reload-keeps-global-hook-registrations ()
  "A global `add-hook' from an init file survives the reload."
  (emacs-tools-tests--with-clean-hook
    (add-hook 'emacs-tools-tests--sample-hook #'md-table-wrap-mode)
    (emacs-tools-reload 'md-table-wrap)
    (should (memq #'md-table-wrap-mode emacs-tools-tests--sample-hook))))

(ert-deftest emacs-tools-test-reload-preserves-hook-depth ()
  "An appended registration comes back appended, not at the front."
  (emacs-tools-tests--with-clean-hook
    (add-hook 'emacs-tools-tests--sample-hook #'md-table-wrap-mode 90)
    (add-hook 'emacs-tools-tests--sample-hook #'ignore)
    (should (equal emacs-tools-tests--sample-hook
                   '(ignore md-table-wrap-mode)))
    (emacs-tools-reload 'md-table-wrap)
    (should (equal emacs-tools-tests--sample-hook
                   '(ignore md-table-wrap-mode)))))

(ert-deftest emacs-tools-test-reload-keeps-buffer-local-hook-registrations ()
  "A buffer-local registration survives, and stays local to its buffer."
  (emacs-tools-tests--with-clean-hook
    (emacs-tools-test-with-buffer emacs-tools-tests--table
      (add-hook 'emacs-tools-tests--sample-hook #'md-table-wrap-mode nil t)
      (should (memq #'md-table-wrap-mode emacs-tools-tests--sample-hook))
      (emacs-tools-reload 'md-table-wrap)
      (should (memq #'md-table-wrap-mode emacs-tools-tests--sample-hook))
      (should (local-variable-p 'emacs-tools-tests--sample-hook))
      (should-not (memq #'md-table-wrap-mode
                        (default-value 'emacs-tools-tests--sample-hook))))))

(ert-deftest emacs-tools-test-reload-does-not-duplicate-registrations ()
  "Restoring is idempotent: nothing appears twice after several reloads."
  (emacs-tools-tests--with-clean-hook
    (add-hook 'emacs-tools-tests--sample-hook #'md-table-wrap-mode)
    (emacs-tools-reload 'md-table-wrap)
    (emacs-tools-reload 'md-table-wrap)
    (should (equal emacs-tools-tests--sample-hook '(md-table-wrap-mode)))))

(ert-deftest emacs-tools-test-reload-does-not-invent-registrations ()
  "A hook the feature was never on stays empty."
  (emacs-tools-tests--with-clean-hook
    (emacs-tools-reload 'md-table-wrap)
    (should-not emacs-tools-tests--sample-hook)))

(ert-deftest emacs-tools-test-reload-restores-mode-hook-registration ()
  "The documented setup -- the mode on `markdown-ts-mode-hook' -- survives."
  (let ((present (memq #'md-table-wrap-mode markdown-ts-mode-hook)))
    (unwind-protect
        (progn
          (add-hook 'markdown-ts-mode-hook #'md-table-wrap-mode)
          (emacs-tools-reload 'md-table-wrap)
          (should (memq #'md-table-wrap-mode markdown-ts-mode-hook)))
      (unless present
        (remove-hook 'markdown-ts-mode-hook #'md-table-wrap-mode)))))

;;;; Reloading the loader itself
;;
;; `emacs-tools-reload' excludes `emacs-tools', since unloading it would remove
;; the functions doing the unloading.  A plain `load' of its own source is both
;; safe and sufficient here -- there is no `defcustom' or stateful `defvar' to
;; reset, only functions to redefine.

(ert-deftest emacs-tools-test-reload-loader-restores-a-clobbered-definition ()
  "A redefined function is put back by reloading the loader."
  (let ((original (symbol-function 'emacs-tools--hook-like-p)))
    (unwind-protect
        (progn
          (fset 'emacs-tools--hook-like-p (lambda (&rest _) 'clobbered))
          (should (eq (emacs-tools--hook-like-p 'x nil) 'clobbered))
          (emacs-tools-reload-loader)
          (should-not (eq (emacs-tools--hook-like-p 'foo-hook '(a)) 'clobbered))
          (should (emacs-tools--hook-like-p 'foo-hook '(a))))
      (unless (eq (symbol-function 'emacs-tools--hook-like-p) original)
        (fset 'emacs-tools--hook-like-p original)))))

(ert-deftest emacs-tools-test-reload-loader-does-not-grow-load-path ()
  "Its top-level `load-path' setup is idempotent, so reloading is repeatable."
  (emacs-tools-reload-loader)
  (let ((before (length load-path)))
    (emacs-tools-reload-loader)
    (emacs-tools-reload-loader)
    (should (= (length load-path) before))
    (should (= (length load-path)
               (length (delete-dups (copy-sequence load-path)))))))

(ert-deftest emacs-tools-test-reload-loader-keeps-hook-registrations ()
  "Nothing is unloaded, so hooks are not swept in the first place."
  (emacs-tools-tests--with-clean-hook
    (add-hook 'emacs-tools-tests--sample-hook #'md-table-wrap-mode)
    (emacs-tools-reload-loader)
    (should (memq #'md-table-wrap-mode emacs-tools-tests--sample-hook))))

(ert-deftest emacs-tools-test-reload-loader-keeps-extensions-loaded ()
  "Reloading the loader does not disturb the extensions it loaded."
  (emacs-tools-reload-loader)
  (should (featurep 'md-table-wrap))
  (should (memq 'md-table-wrap (emacs-tools-loaded-features))))

(ert-deftest emacs-tools-test-reload-loader-reports-missing-source ()
  "A loader that cannot find itself says so rather than failing obscurely."
  (let ((emacs-tools-directory (expand-file-name "no-such-dir/" temporary-file-directory)))
    (should-error (emacs-tools-reload-loader) :type 'user-error)))

(provide 'emacs-tools-tests)

;;; emacs-tools-tests.el ends here
