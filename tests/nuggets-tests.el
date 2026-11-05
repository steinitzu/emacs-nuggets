;;; nuggets-tests.el --- Tests for the collection loader -*- lexical-binding: t; -*-

;;; Commentary:

;; Exercises `nuggets-reload' against a real extension in a real buffer:
;; the mode is on, the buffer's table is drawn, an option has been left at a
;; stale value, and the reload has to put all of that right.
;;
;; The reload genuinely unloads and re-loads `md-table-wrap' mid-test, so
;; these run against the same definitions everything else does.

;;; Code:

(require 'ert)
(require 'nuggets)
(require 'md-table-wrap)
(require 'nuggets-test-helpers)

(defconst nuggets-tests--table
  "| Name | Qty |
|:-----|----:|
| apple | 3 |
| fig | 12 |
"
  "A table for `md-table-wrap' to draw.")

(defun nuggets-tests--overlays ()
  "The overlays `md-table-wrap' has drawn in the current buffer."
  (seq-filter (lambda (ov) (overlay-get ov 'md-table-wrap))
              (overlays-in (point-min) (point-max))))

;;;; Discovery

(ert-deftest nuggets-test-features-lists-extensions-only ()
  "Extension features are discoverable; infrastructure is not."
  (should (memq 'md-table-wrap (nuggets-features)))
  (should (memq 'md-table-wrap (nuggets-loaded-features)))
  ;; Unloading the loader would remove the functions doing the unloading.
  (should-not (memq 'nuggets (nuggets-features)))
  ;; The suite and the scratch directory are not extensions.
  (should-not (memq 'md-table-wrap-tests (nuggets-features)))
  (should-not (memq 'nuggets-test-helpers (nuggets-features)))
  (should-not (memq 'md-font-diagnose (nuggets-features))))

(ert-deftest nuggets-test-finds-minor-modes-of-a-feature ()
  "Both the buffer-local and the globalized mode are found."
  (let ((modes (nuggets--minor-modes 'md-table-wrap)))
    (should (memq 'md-table-wrap-mode modes))
    (should (memq 'global-md-table-wrap-mode modes))))

;;;; Reloading

(ert-deftest nuggets-test-reload-resets-stale-option-values ()
  "Reloading restores changed defaults.

`defcustom' does not reassign a variable that is already bound, so a
plain `load' leaves the old value in place -- the failure this command
exists to prevent."
  (nuggets-test-with-buffer nuggets-tests--table
    (md-table-wrap-mode 1)
    (let ((cap md-table-wrap-word-cap)
          (style md-table-wrap-style))
      (unwind-protect
          (progn
            ;; Stand in for a session still holding an older version's values.
            (setq md-table-wrap-word-cap 7)
            (setq md-table-wrap-style 'ascii)
            (nuggets-reload 'md-table-wrap)
            (should (= md-table-wrap-word-cap 20))
            (should (eq md-table-wrap-style 'box)))
        (setq md-table-wrap-word-cap cap)
        (setq md-table-wrap-style style)))))

(ert-deftest nuggets-test-reload-keeps-modes-on-and-redraws ()
  "A buffer with the mode on comes back on, with its table drawn."
  (nuggets-test-with-buffer nuggets-tests--table
    (md-table-wrap-mode 1)
    (redisplay t)
    (nuggets-reload 'md-table-wrap)
    (should md-table-wrap-mode)
    (redisplay t)
    (should (nuggets-tests--overlays))))

(ert-deftest nuggets-test-reload-leaves-modes-off-that-were-off ()
  "Reloading does not switch the mode on in buffers that had it off."
  (nuggets-test-with-buffer nuggets-tests--table
    (should-not (bound-and-true-p md-table-wrap-mode))
    (nuggets-reload 'md-table-wrap)
    (should-not (bound-and-true-p md-table-wrap-mode))))

(ert-deftest nuggets-test-reload-drops-overlays-from-old-definition ()
  "No overlay outlives the reload that replaced its code."
  (nuggets-test-with-buffer nuggets-tests--table
    (md-table-wrap-mode 1)
    (redisplay t)
    (let ((before (nuggets-tests--overlays)))
      (should before)
      (nuggets-reload 'md-table-wrap)
      (redisplay t)
      ;; Fresh overlays are expected; the previous objects must be gone.
      (dolist (ov before)
        (should-not (overlay-buffer ov))))))

;;;; Compiling

(defun nuggets-tests--source (feature)
  (locate-file (symbol-name feature) load-path '(".el")))

(ert-deftest nuggets-test-reload-compiles ()
  "A reload leaves the extension running compiled, from a fresh `.elc'
next to its source, so the next start loads it compiled too."
  (nuggets-test-with-buffer nuggets-tests--table
    (md-table-wrap-mode 1)
    (nuggets-reload 'md-table-wrap)
    (let* ((source (nuggets-tests--source 'md-table-wrap))
           (elc (concat source "c")))
      (should (compiled-function-p (symbol-function 'md-table-wrap--show-row)))
      (should (equal (symbol-file 'md-table-wrap--show-row 'defun) elc))
      (should (file-exists-p elc))
      (should-not (file-newer-than-file-p source elc))
      (should md-table-wrap-mode))))

(ert-deftest nuggets-test-reload-can-load-source ()
  "With `nuggets-reload-compile' off, a reload loads the source."
  (let ((nuggets-reload-compile nil))
    (nuggets-reload 'md-table-wrap)
    (should-not (compiled-function-p (symbol-function 'md-table-wrap--show-row))))
  ;; Leave it compiled for the suites after this one.
  (nuggets-reload 'md-table-wrap))

(ert-deftest nuggets-test-failed-compile-removes-the-old-elc ()
  "A file that doesn't compile has no `.elc' left to shadow it."
  (let* ((dir (make-temp-file "nuggets-test" t))
         (source (expand-file-name "broken-ext.el" dir))
         (elc (concat source "c")))
    (unwind-protect
        (progn
          (with-temp-file source (insert ";;; -*- lexical-binding: t -*-\n(defun broken (\n"))
          (with-temp-file elc (insert ";; an old build\n"))
          (should-not (nuggets--compile source))
          (should-not (file-exists-p elc)))
      (delete-directory dir t))))

(ert-deftest nuggets-test-loader-recompiles-a-stale-elc ()
  "An `.elc' older than its source is rebuilt when the loader starts:
`require' would load the stale one."
  (let* ((source (nuggets-tests--source 'md-table-wrap))
         (elc (concat source "c")))
    (should (nuggets--compile source))
    ;; As after an edit made without a reload.
    (set-file-times elc (time-subtract (file-attribute-modification-time
                                        (file-attributes source))
                                       100))
    (should (file-newer-than-file-p source elc))
    (nuggets--refresh-stale-elc)
    (should (file-exists-p elc))
    (should-not (file-newer-than-file-p source elc))))

(ert-deftest nuggets-test-reload-rejects-unknown-feature ()
  "An unknown feature is reported rather than silently doing nothing."
  (should-error (nuggets-reload 'no-such-nuggets-feature)
                :type 'user-error))

;;;; Unload hook

(ert-deftest nuggets-test-unload-function-cleans-up-overlays ()
  "`unload-feature' alone leaves no overlays behind.
`md-table-wrap-unload-function' switches the mode off first, so the
definitions are not stripped out from under live overlays."
  (nuggets-test-with-buffer nuggets-tests--table
    (md-table-wrap-mode 1)
    (redisplay t)
    (let ((buffer (current-buffer)))
      (unwind-protect
          (progn
            (unload-feature 'md-table-wrap t)
            (with-current-buffer buffer
              (should-not (nuggets-tests--overlays))))
        ;; Put the package back for the rest of the suite.
        (load (locate-file "md-table-wrap" load-path '(".el")) nil t)))))

;;;; Hook registrations must survive a reload
;;
;; `unload-feature' strips a feature's functions from every hook, because a
;; hook left holding a void function signals in every buffer that runs it.
;; Reloading puts the function straight back, so the strip is pure loss: it
;; silently drops the `add-hook' calls in an init file, and new buffers stop
;; getting the mode.

(defvar nuggets-tests--sample-hook nil
  "A hook variable for reload tests, named so `unload-feature' sweeps it.")

(defmacro nuggets-tests--with-clean-hook (&rest body)
  "Run BODY with `nuggets-tests--sample-hook' empty, and restore it."
  (declare (indent 0) (debug t))
  `(let ((global (default-value 'nuggets-tests--sample-hook)))
     (unwind-protect
         (progn (setq-default nuggets-tests--sample-hook nil) ,@body)
       (setq-default nuggets-tests--sample-hook global))))

(ert-deftest nuggets-test-unload-alone-strips-hooks ()
  "The baseline the reload has to compensate for, so the tests below bite."
  (nuggets-tests--with-clean-hook
    (add-hook 'nuggets-tests--sample-hook #'md-table-wrap-mode)
    (should (memq #'md-table-wrap-mode nuggets-tests--sample-hook))
    (unwind-protect
        (progn
          (unload-feature 'md-table-wrap t)
          (should-not (memq #'md-table-wrap-mode
                            nuggets-tests--sample-hook)))
      ;; Whatever the assertion did, put the feature back for everything else.
      (load (locate-file "md-table-wrap" load-path '(".el")) nil t))))

(ert-deftest nuggets-test-reload-keeps-global-hook-registrations ()
  "A global `add-hook' from an init file survives the reload."
  (nuggets-tests--with-clean-hook
    (add-hook 'nuggets-tests--sample-hook #'md-table-wrap-mode)
    (nuggets-reload 'md-table-wrap)
    (should (memq #'md-table-wrap-mode nuggets-tests--sample-hook))))

(ert-deftest nuggets-test-reload-preserves-hook-depth ()
  "An appended registration comes back appended, not at the front."
  (nuggets-tests--with-clean-hook
    (add-hook 'nuggets-tests--sample-hook #'md-table-wrap-mode 90)
    (add-hook 'nuggets-tests--sample-hook #'ignore)
    (should (equal nuggets-tests--sample-hook
                   '(ignore md-table-wrap-mode)))
    (nuggets-reload 'md-table-wrap)
    (should (equal nuggets-tests--sample-hook
                   '(ignore md-table-wrap-mode)))))

(ert-deftest nuggets-test-reload-keeps-buffer-local-hook-registrations ()
  "A buffer-local registration survives, and stays local to its buffer."
  (nuggets-tests--with-clean-hook
    (nuggets-test-with-buffer nuggets-tests--table
      (add-hook 'nuggets-tests--sample-hook #'md-table-wrap-mode nil t)
      (should (memq #'md-table-wrap-mode nuggets-tests--sample-hook))
      (nuggets-reload 'md-table-wrap)
      (should (memq #'md-table-wrap-mode nuggets-tests--sample-hook))
      (should (local-variable-p 'nuggets-tests--sample-hook))
      (should-not (memq #'md-table-wrap-mode
                        (default-value 'nuggets-tests--sample-hook))))))

(ert-deftest nuggets-test-reload-does-not-duplicate-registrations ()
  "Restoring is idempotent: nothing appears twice after several reloads."
  (nuggets-tests--with-clean-hook
    (add-hook 'nuggets-tests--sample-hook #'md-table-wrap-mode)
    (nuggets-reload 'md-table-wrap)
    (nuggets-reload 'md-table-wrap)
    (should (equal nuggets-tests--sample-hook '(md-table-wrap-mode)))))

(ert-deftest nuggets-test-reload-does-not-invent-registrations ()
  "A hook the feature was never on stays empty."
  (nuggets-tests--with-clean-hook
    (nuggets-reload 'md-table-wrap)
    (should-not nuggets-tests--sample-hook)))

(ert-deftest nuggets-test-reload-restores-mode-hook-registration ()
  "The documented setup -- the mode on `markdown-ts-mode-hook' -- survives."
  (let ((present (memq #'md-table-wrap-mode markdown-ts-mode-hook)))
    (unwind-protect
        (progn
          (add-hook 'markdown-ts-mode-hook #'md-table-wrap-mode)
          (nuggets-reload 'md-table-wrap)
          (should (memq #'md-table-wrap-mode markdown-ts-mode-hook)))
      (unless present
        (remove-hook 'markdown-ts-mode-hook #'md-table-wrap-mode)))))

;;;; Reloading the loader itself
;;
;; `nuggets-reload' excludes `nuggets', since unloading it would remove
;; the functions doing the unloading.  A plain `load' of its own source is both
;; safe and sufficient here -- there is no `defcustom' or stateful `defvar' to
;; reset, only functions to redefine.

(ert-deftest nuggets-test-reload-loader-restores-a-clobbered-definition ()
  "A redefined function is put back by reloading the loader."
  (let ((original (symbol-function 'nuggets--hook-like-p)))
    (unwind-protect
        (progn
          (fset 'nuggets--hook-like-p (lambda (&rest _) 'clobbered))
          (should (eq (nuggets--hook-like-p 'x nil) 'clobbered))
          (nuggets-reload-loader)
          (should-not (eq (nuggets--hook-like-p 'foo-hook '(a)) 'clobbered))
          (should (nuggets--hook-like-p 'foo-hook '(a))))
      (unless (eq (symbol-function 'nuggets--hook-like-p) original)
        (fset 'nuggets--hook-like-p original)))))

(ert-deftest nuggets-test-reload-loader-does-not-grow-load-path ()
  "Its top-level `load-path' setup is idempotent, so reloading is repeatable."
  (nuggets-reload-loader)
  (let ((before (length load-path)))
    (nuggets-reload-loader)
    (nuggets-reload-loader)
    (should (= (length load-path) before))
    (should (= (length load-path)
               (length (delete-dups (copy-sequence load-path)))))))

(ert-deftest nuggets-test-reload-loader-keeps-hook-registrations ()
  "Nothing is unloaded, so hooks are not swept in the first place."
  (nuggets-tests--with-clean-hook
    (add-hook 'nuggets-tests--sample-hook #'md-table-wrap-mode)
    (nuggets-reload-loader)
    (should (memq #'md-table-wrap-mode nuggets-tests--sample-hook))))

(ert-deftest nuggets-test-reload-loader-keeps-extensions-loaded ()
  "Reloading the loader does not disturb the extensions it loaded."
  (nuggets-reload-loader)
  (should (featurep 'md-table-wrap))
  (should (memq 'md-table-wrap (nuggets-loaded-features))))

(ert-deftest nuggets-test-reload-loader-reports-missing-source ()
  "A loader that cannot find itself says so rather than failing obscurely."
  (let ((nuggets-directory (expand-file-name "no-such-dir/" temporary-file-directory)))
    (should-error (nuggets-reload-loader) :type 'user-error)))

(provide 'nuggets-tests)

;;; nuggets-tests.el ends here
