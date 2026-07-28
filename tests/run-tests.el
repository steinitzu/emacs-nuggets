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
      ;; A debugger prompt in a TTY frame would hang the run forever.
      debug-on-error nil)

(defconst md-table-align-tests--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defconst md-table-align-tests--root
  (expand-file-name ".." md-table-align-tests--dir))

(require 'treesit)
(setq treesit-extra-load-path
      (list (expand-file-name ".test-env/tree-sitter" md-table-align-tests--root)))

(add-to-list 'load-path (expand-file-name "md-table-align" md-table-align-tests--root))

(defun md-table-align-tests--finish (exit)
  "Write the run transcript to the log file and quit with EXIT."
  (with-current-buffer (messages-buffer)
    (let ((inhibit-read-only t))
      (write-region (point-min) (point-max)
                    (expand-file-name ".last-run.log" md-table-align-tests--dir)
                    nil 'quiet)))
  (kill-emacs exit))

(let ((exit 1))
  (unwind-protect
      (progn
        (load (expand-file-name "md-table-align-tests.el" md-table-align-tests--dir) nil t)
        (let ((stats (ert-run-tests-batch)))
          (setq exit (if (and (zerop (ert-stats-completed-unexpected stats))
                              (> (ert-stats-total stats) 0))
                         0 1))
          (message "RESULT: %s" (if (zerop exit) "PASS" "FAIL"))))
    (md-table-align-tests--finish exit)))

;;; run-tests.el ends here
