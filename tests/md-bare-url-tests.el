;;; md-bare-url-tests.el --- Tests for md-bare-url -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Steinthor Palsson
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; These run in real buffers under a real `markdown-ts-mode' with a real
;; tree-sitter parser, displayed in a live window so `jit-lock' fontifies them
;; on its own -- the buttons asserted on are the ones upstream's own jit-lock
;; handler built, not ones a test called into being.
;;
;; The only thing stubbed is the very last step, `browse-url' and
;; `compose-mail', because a test suite must not open a browser or a mail
;; composer.  Everything between the buffer text and that boundary is real,
;; including the key lookup that decides what `RET' runs.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'treesit)
(require 'markdown-ts-mode)
(require 'md-bare-url)

;; Loaded for `url-mail-command', which `markdown-ts--make-link-button' uses
;; without requiring it -- unloaded, the mailto: branch fails with a void
;; variable rather than reaching `compose-mail'.  Loading it means these tests
;; assert on the upstream behaviour rather than on that incidental error.
(require 'url-vars)

;;;; Fixtures

(defconst md-bare-url-tests--document
  "Bare: https://example.com/foo end

Mail: someone@example.com

Tagged: [x](https://example.com/bar)

Auto: <https://example.com/baz>

Explicit: [y](mailto:someone@example.com)
"
  "One of every link shape `markdown-ts-mode' buttonizes.
Only the first is mishandled upstream; the rest are the control group.")

;; Each entry is (NAME . SEARCH-STRING), where SEARCH-STRING locates the link
;; in the fixture above.
(defconst md-bare-url-tests--bare-url '("bare URL" . "https://example.com/foo"))
(defconst md-bare-url-tests--controls
  '(("bare email" . "someone@example.com")
    ("tagged link" . "[x]")
    ("autolink" . "<https://example.com/baz>")
    ("explicit mailto" . "[y]"))
  "Links that already behave correctly and must not change.")

;;;; Helpers

(defmacro md-bare-url-tests--with-buffer (&rest body)
  "Display the fixture in a `markdown-ts-mode' window, then run BODY.
The mode is left off, and restored to off afterwards, so each test starts
from upstream's behaviour."
  (declare (indent 0) (debug t))
  `(let ((buf (generate-new-buffer "*md-bare-url-test*"))
         (was md-bare-url-mode))
     (unwind-protect
         (progn
           (md-bare-url-mode -1)
           (switch-to-buffer buf)
           (insert md-bare-url-tests--document)
           (goto-char (point-min))
           (markdown-ts-mode)
           (set-buffer-modified-p nil)
           ;; Let jit-lock run for real; buttons appear as a side effect.
           (redisplay t)
           ,@body)
       (md-bare-url-mode (if was 1 -1))
       (kill-buffer buf))))

(defun md-bare-url-tests--goto (search-string)
  "Move point inside the link located by SEARCH-STRING and return point."
  (goto-char (point-min))
  (should (search-forward search-string nil t))
  (goto-char (1+ (match-beginning 0))))

(defun md-bare-url-tests--destination (search-string)
  "Return the URL the button at SEARCH-STRING points at.
Read from `help-echo', which `markdown-ts--make-link-button' sets to the
URL it captured -- the same string its action closure will dispatch on."
  (save-excursion
    (let ((button (button-at (md-bare-url-tests--goto search-string))))
      (should button)
      (substring-no-properties (button-get button 'help-echo)))))

(defun md-bare-url-tests--follow (search-string)
  "Put point on the link at SEARCH-STRING and press RET as a user would.
Return (browse-url URL) or (compose-mail ARGS...) describing what the
command actually reached, or nil if it reached neither."
  (save-excursion
    (md-bare-url-tests--goto search-string)
    (let ((followed nil)
          (command (key-binding (kbd "RET"))))
      ;; Not an assumption worth hiding: if RET stops resolving to the button
      ;; here, every other assertion in this file is testing nothing.
      (should (eq command #'push-button))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _)
                   (setq followed (list 'browse-url (substring-no-properties url)))))
                ((symbol-function 'compose-mail)
                 (lambda (&rest args)
                   (setq followed (cons 'compose-mail
                                        (mapcar (lambda (a)
                                                  (if (stringp a)
                                                      (substring-no-properties a)
                                                    a))
                                                args))))))
        (call-interactively command))
      followed)))

(defun md-bare-url-tests--enable ()
  "Turn on `md-bare-url-mode' and let redisplay rebuild the buttons."
  (md-bare-url-mode 1)
  (should md-bare-url-mode)
  (redisplay t))

;;;; The upstream bug this package exists for
;;
;; If this test starts failing, upstream has fixed markdown-ts-mode and this
;; package can be deleted rather than repaired.

(ert-deftest md-bare-url-test-upstream-misroutes-bare-urls ()
  "With the mode off, a bare URL is buttonized as if it were an email."
  (md-bare-url-tests--with-buffer
    (should (equal (md-bare-url-tests--destination (cdr md-bare-url-tests--bare-url))
                   "mailto:https://example.com/foo"))
    (should (equal (md-bare-url-tests--follow (cdr md-bare-url-tests--bare-url))
                   '(compose-mail "https://example.com/foo")))))

(ert-deftest md-bare-url-test-upstream-handles-the-other-shapes ()
  "Every link shape other than a bare URL already points where it should."
  (md-bare-url-tests--with-buffer
    (should (equal (md-bare-url-tests--destination "[x]") "https://example.com/bar"))
    (should (equal (md-bare-url-tests--destination "<https://example.com/baz>")
                   "https://example.com/baz"))
    (should (equal (md-bare-url-tests--destination "someone@example.com")
                   "mailto:someone@example.com"))
    (should (equal (md-bare-url-tests--destination "[y]")
                   "mailto:someone@example.com"))))

;;;; The fix

(ert-deftest md-bare-url-test-bare-url-points-at-the-url ()
  "With the mode on, the bare URL's button loses the bogus mailto:."
  (md-bare-url-tests--with-buffer
    (md-bare-url-tests--enable)
    (should (equal (md-bare-url-tests--destination (cdr md-bare-url-tests--bare-url))
                   "https://example.com/foo"))))

(ert-deftest md-bare-url-test-ret-on-a-bare-url-browses ()
  "Pressing RET on a bare URL reaches `browse-url' -- the reported problem."
  (md-bare-url-tests--with-buffer
    (md-bare-url-tests--enable)
    (should (equal (md-bare-url-tests--follow (cdr md-bare-url-tests--bare-url))
                   '(browse-url "https://example.com/foo")))))

(ert-deftest md-bare-url-test-mouse-follows-a-bare-url-too ()
  "`mouse-1' and `mouse-2' reach the same button as RET."
  (md-bare-url-tests--with-buffer
    (md-bare-url-tests--enable)
    (save-excursion
      (md-bare-url-tests--goto (cdr md-bare-url-tests--bare-url))
      ;; `mouse-1' follows via button-map's <follow-link> entry, honoured by
      ;; `mouse-1-click-follows-link'.
      (should (eq (key-binding (kbd "<mouse-2>")) #'push-button))
      (should (eq (key-binding [follow-link]) 'mouse-face)))))

;;;; Non-interference

(ert-deftest md-bare-url-test-leaves-every-other-link-shape-alone ()
  "Tagged links, autolinks and both kinds of email are byte-identical."
  (md-bare-url-tests--with-buffer
    (let ((before (mapcar (lambda (link)
                            (cons (car link)
                                  (md-bare-url-tests--destination (cdr link))))
                          md-bare-url-tests--controls)))
      (md-bare-url-tests--enable)
      (dolist (link md-bare-url-tests--controls)
        (should (equal (cons (car link)
                             (md-bare-url-tests--destination (cdr link)))
                       (assoc (car link) before)))))))

(ert-deftest md-bare-url-test-bare-email-still-composes-mail ()
  "A bare email address must keep reaching the mail composer, not a browser."
  (md-bare-url-tests--with-buffer
    (md-bare-url-tests--enable)
    (should (equal (md-bare-url-tests--follow "someone@example.com")
                   '(compose-mail "someone@example.com")))))

;;;; The transform in isolation
;;
;; `md-bare-url-destination' is the one place a mistake would silently corrupt
;; a real URL, so its edges are worth pinning down directly.

(ert-deftest md-bare-url-test-destination-strips-only-a-double-scheme ()
  "Only a mailto: whose body carries its own scheme is rewritten."
  (should (equal (md-bare-url-destination "mailto:https://example.com/foo")
                 "https://example.com/foo"))
  (should (equal (md-bare-url-destination "mailto:ftp://example.com")
                 "ftp://example.com"))
  ;; Real mailto: addresses, left alone.
  (should (equal (md-bare-url-destination "mailto:someone@example.com")
                 "mailto:someone@example.com"))
  (should (equal (md-bare-url-destination "mailto:a.b+c@example.co.uk")
                 "mailto:a.b+c@example.co.uk"))
  ;; Everything that never had the prefix.
  (should (equal (md-bare-url-destination "https://example.com") "https://example.com"))
  (should (equal (md-bare-url-destination "#heading") "#heading"))
  (should (equal (md-bare-url-destination "relative/file.md") "relative/file.md"))
  (should (equal (md-bare-url-destination nil) nil)))

;;;; Reversibility
;;
;; The mode installs global advice, so `nuggets-reload' depends on it
;; coming back off cleanly.

(ert-deftest md-bare-url-test-disabling-restores-upstream-behaviour ()
  "Switching the mode off returns live buffers to upstream's destinations."
  (md-bare-url-tests--with-buffer
    (md-bare-url-tests--enable)
    (should (equal (md-bare-url-tests--destination (cdr md-bare-url-tests--bare-url))
                   "https://example.com/foo"))
    (md-bare-url-mode -1)
    (redisplay t)
    (should (equal (md-bare-url-tests--destination (cdr md-bare-url-tests--bare-url))
                   "mailto:https://example.com/foo"))
    (should-not (advice-member-p #'md-bare-url--filter-args
                                 'markdown-ts--make-link-button))))

(ert-deftest md-bare-url-test-enabling-heals-an-open-buffer ()
  "A buffer fontified before the mode was on picks the fix up regardless.
This is what `md-bare-url--reset-buffers' exists for: `jit-lock' does not
revisit a region it has already fontified."
  (md-bare-url-tests--with-buffer
    ;; Precondition: the wrong button is already built and on screen.
    (should (equal (md-bare-url-tests--destination (cdr md-bare-url-tests--bare-url))
                   "mailto:https://example.com/foo"))
    (md-bare-url-tests--enable)
    (should (equal (md-bare-url-tests--destination (cdr md-bare-url-tests--bare-url))
                   "https://example.com/foo"))))

(provide 'md-bare-url-tests)

;;; md-bare-url-tests.el ends here
