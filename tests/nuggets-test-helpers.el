;;; nuggets-test-helpers.el --- Fixtures shared by the test suites -*- lexical-binding: t; -*-

;;; Commentary:

;; Buffer and frame scaffolding more than one suite needs.  Not a suite
;; itself: `run-tests.el' loads `*-tests.el' files only, and each suite
;; that wants these requires this file.

;;; Code:

(require 'markdown-ts-mode)

(defmacro nuggets-test-with-buffer (text &rest body)
  "Display TEXT in a `markdown-ts-mode' buffer in a live window, then run BODY."
  (declare (indent 1) (debug t))
  `(let ((buf (generate-new-buffer "*nuggets-test*")))
     (unwind-protect
         (progn
           (switch-to-buffer buf)
           (insert ,text)
           (goto-char (point-min))
           (markdown-ts-mode)
           (set-buffer-modified-p nil)
           (redisplay t)
           ,@body)
       (kill-buffer buf))))

(defmacro nuggets-test-with-read-only-text (text &rest body)
  "Run BODY over TEXT with every character carrying a `read-only' property.
This is how a chat or transcript UI locks down what it has printed,
rather than with `buffer-read-only'."
  (declare (indent 1) (debug t))
  `(nuggets-test-with-buffer ,text
     (let ((inhibit-read-only t))
       (put-text-property (point-min) (point-max) 'read-only t))
     ;; Applying the property is itself a modification; the fixture's own
     ;; setup must not be what a `buffer-modified-p' assertion sees.
     (set-buffer-modified-p nil)
     ,@body))

(defmacro nuggets-test-with-frame-width (width &rest body)
  "Run BODY with the frame WIDTH columns wide, then restore it."
  (declare (indent 1) (debug t))
  `(let ((original (frame-width)))
     (unwind-protect
         (progn (set-frame-width nil ,width) (redisplay t) ,@body)
       (set-frame-width nil original)
       (redisplay t))))

(provide 'nuggets-test-helpers)

;;; nuggets-test-helpers.el ends here
