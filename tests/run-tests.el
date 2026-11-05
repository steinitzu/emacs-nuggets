;;; run-tests.el --- ERT driver for a TTY frame -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded by run-tests.sh inside an Emacs holding a real TTY frame.  Because
;; this is not batch mode, `message' output lands in *Messages* rather than on
;; stdout, so the run is transcribed to tests/.last-run.log at the end.
;;
;; Nothing here may block: an unhandled error or a prompt would leave Emacs
;; sitting in its command loop until the test timeout.

;;; Code:

(require 'ert)

(setq inhibit-startup-screen t
      make-backup-files nil
      auto-save-default nil
      confirm-kill-emacs nil
      ;; `load' prefers a `.elc' over a newer `.el' by default, so a stale
      ;; artefact left by `make compile' would be tested in place of the source
      ;; -- silently, and the suite would pass while asserting on old code.
      load-prefer-newer t
      ;; A debugger prompt in a TTY frame would hang the run forever.
      debug-on-error nil)

(defconst run-tests--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defconst run-tests--root
  (expand-file-name ".." run-tests--dir))

(require 'treesit)
(setq treesit-extra-load-path
      (list (expand-file-name ".test-env/tree-sitter" run-tests--root)))

;; Third-party packages the suite drives for real -- `vterm' and `ghostel',
;; termdex's two backends.  Kept in the test environment rather than taken from
;; the user's own package directory, so a run neither depends on nor disturbs
;; what they have installed.  Tests that need one skip when it is absent.
(require 'package)
(setq package-user-dir (expand-file-name ".test-env/elpa" run-tests--root))
(package-initialize)

;; Load extensions the way an end user does -- through the collection loader --
;; so `make test' also exercises the install path.
(add-to-list 'load-path run-tests--root)
(require 'emacs-tools)

;; Suites require shared helpers, so the directory must be on `load-path'.
(add-to-list 'load-path run-tests--dir)

(defun run-tests--elc-files ()
  (directory-files-recursively run-tests--root "\\.elc\\'" nil
                               (lambda (d) (not (string-match-p "/\\.test-env\\'" d)))))

(defconst run-tests--elc-before (run-tests--elc-files)
  "`.elc' files present before the run.  `emacs-tools-reload' compiles,
so the reload tests write some; those the run made, it removes.")

(defun run-tests--finish (exit)
  "Write the run transcript to the log file and quit with EXIT."
  (dolist (f (run-tests--elc-files))
    (unless (member f run-tests--elc-before) (delete-file f)))
  (with-current-buffer (messages-buffer)
    (let ((inhibit-read-only t))
      (write-region (point-min) (point-max)
                    (expand-file-name ".last-run.log" run-tests--dir)
                    nil 'quiet)))
  (kill-emacs exit))

(let ((exit 1))
  (unwind-protect
      (progn
        ;; This file matches "-tests.el" too; loading it would recurse.
        (dolist (file (directory-files run-tests--dir t "-tests\\.el\\'"))
          (unless (equal (file-name-nondirectory file) "run-tests.el")
            (load file nil t)))
        (let ((stats (ert-run-tests-batch)))
          (setq exit (if (and (zerop (ert-stats-completed-unexpected stats))
                              (> (ert-stats-total stats) 0))
                         0 1))
          (message "RESULT: %s" (if (zerop exit) "PASS" "FAIL"))))
    (run-tests--finish exit)))

;;; run-tests.el ends here
