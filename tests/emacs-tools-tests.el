;;; emacs-tools-tests.el --- Tests for the collection loader -*- lexical-binding: t; -*-

;;; Commentary:

;; Exercises `emacs-tools-reload' against a real extension in a real buffer:
;; the mode is on, the buffer is aligned, an option has been left at a stale
;; value, and the reload has to put all of that right.
;;
;; The reload genuinely unloads and re-loads `md-table-align' mid-test, so
;; these run against the same definitions everything else does.

;;; Code:

(require 'ert)
(require 'emacs-tools)
(require 'md-table-align)
(require 'md-table-align-tests)

;;;; Discovery

(ert-deftest emacs-tools-test-features-lists-extensions-only ()
  "Extension features are discoverable; infrastructure is not."
  (should (memq 'md-table-align (emacs-tools-features)))
  (should (memq 'md-table-align (emacs-tools-loaded-features)))
  ;; Unloading the loader would remove the functions doing the unloading.
  (should-not (memq 'emacs-tools (emacs-tools-features)))
  ;; The suite and the scratch directory are not extensions.
  (should-not (memq 'md-table-align-tests (emacs-tools-features)))
  (should-not (memq 'md-font-diagnose (emacs-tools-features))))

(ert-deftest emacs-tools-test-finds-minor-modes-of-a-feature ()
  "Both the buffer-local and the globalized mode are found."
  (let ((modes (emacs-tools--minor-modes 'md-table-align)))
    (should (memq 'md-table-align-mode modes))
    (should (memq 'global-md-table-align-mode modes))))

;;;; Reloading

(ert-deftest emacs-tools-test-reload-resets-stale-option-values ()
  "Reloading restores changed defaults.

`defcustom' does not reassign a variable that is already bound, so a
plain `load' leaves the old value in place -- the failure this command
exists to prevent."
  (md-table-align-tests--with-buffer md-table-align-tests--simple
    (md-table-align-mode 1)
    (let ((padding md-table-align-padding)
          (width-fn md-table-align-pixel-width-function))
      (unwind-protect
          (progn
            ;; Stand in for a session still holding an older version's values.
            (setq md-table-align-padding 7)
            (setq md-table-align-pixel-width-function #'ignore)
            (emacs-tools-reload 'md-table-align)
            (should (= md-table-align-padding 1))
            (should (eq md-table-align-pixel-width-function
                        #'md-table-align-pixel-width)))
        (setq md-table-align-padding padding)
        (setq md-table-align-pixel-width-function width-fn)))))

(ert-deftest emacs-tools-test-reload-keeps-modes-on-and-realigns ()
  "A buffer with the mode on comes back on, and correctly aligned."
  (md-table-align-tests--with-buffer md-table-align-tests--simple
    (md-table-align-mode 1)
    (redisplay t)
    (emacs-tools-reload 'md-table-align)
    (should md-table-align-mode)
    (redisplay t)
    (dolist (row (md-table-align-tests--pipe-columns))
      (should (equal row md-table-align-tests--simple-columns)))))

(ert-deftest emacs-tools-test-reload-leaves-modes-off-that-were-off ()
  "Reloading does not switch the mode on in buffers that had it off."
  (md-table-align-tests--with-buffer md-table-align-tests--simple
    (should-not (bound-and-true-p md-table-align-mode))
    (emacs-tools-reload 'md-table-align)
    (should-not (bound-and-true-p md-table-align-mode))))

(ert-deftest emacs-tools-test-reload-drops-overlays-from-old-definition ()
  "No alignment overlay outlives the reload that replaced its code."
  (md-table-align-tests--with-buffer md-table-align-tests--simple
    (md-table-align-mode 1)
    (redisplay t)
    (let ((before (seq-filter (lambda (ov) (overlay-get ov 'md-table-align))
                              (overlays-in (point-min) (point-max)))))
      (should before)
      (emacs-tools-reload 'md-table-align)
      (redisplay t)
      ;; Fresh overlays are expected; the previous objects must be gone.
      (dolist (ov before)
        (should-not (overlay-buffer ov))))))

(ert-deftest emacs-tools-test-reload-rejects-unknown-feature ()
  "An unknown feature is reported rather than silently doing nothing."
  (should-error (emacs-tools-reload 'no-such-emacs-tools-feature)
                :type 'user-error))

;;;; Unload hook

(ert-deftest emacs-tools-test-unload-function-cleans-up-overlays ()
  "`unload-feature' alone leaves no overlays behind.
`md-table-align-unload-function' switches the mode off first, so the
definitions are not stripped out from under live overlays."
  (md-table-align-tests--with-buffer md-table-align-tests--simple
    (md-table-align-mode 1)
    (redisplay t)
    (let ((buffer (current-buffer)))
      (unwind-protect
          (progn
            (unload-feature 'md-table-align t)
            (with-current-buffer buffer
              (should-not (seq-filter (lambda (ov) (overlay-get ov 'md-table-align))
                                      (overlays-in (point-min) (point-max))))))
        ;; Put the package back for the rest of the suite.
        (load (locate-file "md-table-align" load-path '(".el")) nil t)))))

(provide 'emacs-tools-tests)

;;; emacs-tools-tests.el ends here

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
    (add-hook 'emacs-tools-tests--sample-hook #'md-table-align-mode)
    (should (memq #'md-table-align-mode emacs-tools-tests--sample-hook))
    (unwind-protect
        (progn
          (unload-feature 'md-table-align t)
          (should-not (memq #'md-table-align-mode
                            emacs-tools-tests--sample-hook)))
      ;; Whatever the assertion did, put the feature back for everything else.
      (load (locate-file "md-table-align" load-path '(".el")) nil t))))

(ert-deftest emacs-tools-test-reload-keeps-global-hook-registrations ()
  "A global `add-hook' from an init file survives the reload."
  (emacs-tools-tests--with-clean-hook
    (add-hook 'emacs-tools-tests--sample-hook #'md-table-align-mode)
    (emacs-tools-reload 'md-table-align)
    (should (memq #'md-table-align-mode emacs-tools-tests--sample-hook))))

(ert-deftest emacs-tools-test-reload-preserves-hook-depth ()
  "An appended registration comes back appended, not at the front."
  (emacs-tools-tests--with-clean-hook
    (add-hook 'emacs-tools-tests--sample-hook #'md-table-align-mode 90)
    (add-hook 'emacs-tools-tests--sample-hook #'ignore)
    (should (equal emacs-tools-tests--sample-hook
                   '(ignore md-table-align-mode)))
    (emacs-tools-reload 'md-table-align)
    (should (equal emacs-tools-tests--sample-hook
                   '(ignore md-table-align-mode)))))

(ert-deftest emacs-tools-test-reload-keeps-buffer-local-hook-registrations ()
  "A buffer-local registration survives, and stays local to its buffer."
  (emacs-tools-tests--with-clean-hook
    (md-table-align-tests--with-buffer md-table-align-tests--simple
      (add-hook 'emacs-tools-tests--sample-hook #'md-table-align-mode nil t)
      (should (memq #'md-table-align-mode emacs-tools-tests--sample-hook))
      (emacs-tools-reload 'md-table-align)
      (should (memq #'md-table-align-mode emacs-tools-tests--sample-hook))
      (should (local-variable-p 'emacs-tools-tests--sample-hook))
      (should-not (memq #'md-table-align-mode
                        (default-value 'emacs-tools-tests--sample-hook))))))

(ert-deftest emacs-tools-test-reload-does-not-duplicate-registrations ()
  "Restoring is idempotent: nothing appears twice after several reloads."
  (emacs-tools-tests--with-clean-hook
    (add-hook 'emacs-tools-tests--sample-hook #'md-table-align-mode)
    (emacs-tools-reload 'md-table-align)
    (emacs-tools-reload 'md-table-align)
    (should (equal emacs-tools-tests--sample-hook '(md-table-align-mode)))))

(ert-deftest emacs-tools-test-reload-does-not-invent-registrations ()
  "A hook the feature was never on stays empty."
  (emacs-tools-tests--with-clean-hook
    (emacs-tools-reload 'md-table-align)
    (should-not emacs-tools-tests--sample-hook)))

(ert-deftest emacs-tools-test-reload-restores-mode-hook-registration ()
  "The documented setup -- the mode on `markdown-ts-mode-hook' -- survives."
  (let ((present (memq #'md-table-align-mode markdown-ts-mode-hook)))
    (unwind-protect
        (progn
          (add-hook 'markdown-ts-mode-hook #'md-table-align-mode)
          (emacs-tools-reload 'md-table-align)
          (should (memq #'md-table-align-mode markdown-ts-mode-hook)))
      (unless present
        (remove-hook 'markdown-ts-mode-hook #'md-table-align-mode)))))
