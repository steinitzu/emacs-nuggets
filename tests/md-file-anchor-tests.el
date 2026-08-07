;;; md-file-anchor-tests.el --- Tests for md-file-anchor -*- lexical-binding: t; -*-

;;; Commentary:

;; These run in real buffers under a real `markdown-ts-mode' with a real
;; tree-sitter parser, displayed in a live window so `jit-lock' builds the
;; buttons on its own.  Unlike md-bare-url's suite, whose endpoint had to be
;; stubbed (a test must not open a browser), the endpoint here is `find-file'
;; on files this suite creates -- so RET is pressed for real and the
;; assertions are on `buffer-file-name', `line-number-at-pos' and the pulse
;; overlay's bounds.  `find-file' is stubbed only where a test asserts the
;; upstream misbehaviour, which would otherwise visit a junk buffer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pulse)
(require 'treesit)
(require 'markdown-ts-mode)
(require 'md-file-anchor)

;;;; Fixtures

(defconst md-file-anchor-tests--document
  "# Top

Range: [r](target.py#L392-L400)

Single: [s](target.py#L7)

GitLab: [g](target.py#L3-9)

Plain: [p](target.py)

Heading: [h](notes.md#deferred-decisions)

Missing heading: [m](notes.md#no-such-heading)

Non-markdown heading: [n](target.py#appendix)

Literal hash file: [l](weird#L5.md)

Web: [w](https://example.com/a#b)

In-buffer: [f](#top)
"
  "One link per behaviour: the handled shapes, the guard, and controls.")

(defconst md-file-anchor-tests--notes
  "# Top

text

## Deferred Decisions

body
"
  "Contents of the notes.md fixture; the slug of interest is at line 5.")

(defun md-file-anchor-tests--write-fixtures (dir)
  "Create the target files the fixture document links to, under DIR."
  (with-temp-file (expand-file-name "target.py" dir)
    (dotimes (i 500)
      (insert (format "line %d\n" (1+ i)))))
  (with-temp-file (expand-file-name "notes.md" dir)
    (insert md-file-anchor-tests--notes))
  (with-temp-file (expand-file-name "weird#L5.md" dir)
    (insert "literal hash filename\n")))

;;;; Helpers

(defmacro md-file-anchor-tests--with-buffer (&rest body)
  "Display the fixture in a `markdown-ts-mode' window, then run BODY.
Fixture files live in a fresh directory that is the buffer's
`default-directory', so relative links resolve against it -- and are
deleted afterwards, along with any buffer that visited them.  The mode
starts off and is restored afterwards.  `.md' files are mapped to
`markdown-ts-mode' for the duration, since Emacs 31 ships no such
`auto-mode-alist' entry of its own."
  (declare (indent 0) (debug t))
  `(let* ((dir (make-temp-file "md-file-anchor-tests" t))
          (buf (generate-new-buffer "*md-file-anchor-test*"))
          (was md-file-anchor-mode)
          (auto-mode-alist (cons '("\\.md\\'" . markdown-ts-mode)
                                 auto-mode-alist)))
     (unwind-protect
         (progn
           (md-file-anchor-mode -1)
           (md-file-anchor-tests--write-fixtures dir)
           (switch-to-buffer buf)
           (setq default-directory (file-name-as-directory dir))
           (insert md-file-anchor-tests--document)
           (goto-char (point-min))
           (markdown-ts-mode)
           (set-buffer-modified-p nil)
           ;; Let jit-lock run for real; buttons appear as a side effect.
           (redisplay t)
           ,@body)
       (md-file-anchor-mode (if was 1 -1))
       (dolist (open (buffer-list))
         (when-let* ((file (buffer-file-name open))
                     ((file-in-directory-p file dir)))
           (kill-buffer open)))
       (kill-buffer buf)
       (delete-directory dir t))))

(defun md-file-anchor-tests--goto (search-string)
  "Move point inside the link located by SEARCH-STRING and return point."
  (goto-char (point-min))
  (should (search-forward search-string nil t))
  (goto-char (1+ (match-beginning 0))))

(defun md-file-anchor-tests--press-ret (search-string)
  "Put point on the link at SEARCH-STRING and press RET as a user would.
Whatever `find-file' selects is left current for BODY to assert on."
  (md-file-anchor-tests--goto search-string)
  (let ((command (key-binding (kbd "RET"))))
    ;; If RET stops resolving to the button, every assertion downstream of
    ;; this helper is testing nothing.
    (should (eq command #'push-button))
    (call-interactively command)))

(defun md-file-anchor-tests--found-file (search-string)
  "Press RET on the link at SEARCH-STRING; return what `find-file' got.
The visit itself is intercepted -- this is for asserting on links whose
destination is junk that should not be visited for real."
  (let ((found nil))
    (cl-letf (((symbol-function 'find-file)
               (lambda (file &rest _) (setq found file))))
      (md-file-anchor-tests--press-ret search-string))
    found))

(defun md-file-anchor-tests--enable ()
  "Turn on `md-file-anchor-mode' and let redisplay rebuild the buttons."
  (md-file-anchor-mode 1)
  (should md-file-anchor-mode)
  (redisplay t))

(defun md-file-anchor-tests--line-pos (line where)
  "Return the position of LINE's beginning or end, WHERE being `bol' or `eol'."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line))
    (if (eq where 'bol) (line-beginning-position) (line-end-position))))

;;;; The upstream gap this package exists for
;;
;; If this test starts failing, upstream has grown fragment handling on file
;; links, and this package should be reassessed rather than repaired.

(ert-deftest md-file-anchor-test-upstream-passes-the-fragment-to-find-file ()
  "With the mode off, the anchor is treated as part of the filename."
  (md-file-anchor-tests--with-buffer
    (should (equal (md-file-anchor-tests--found-file "[r]")
                   "target.py#L392-L400"))))

;;;; The fix

(ert-deftest md-file-anchor-test-range-anchor-opens-at-first-line ()
  "RET on target.py#L392-L400 visits target.py with point on line 392."
  (md-file-anchor-tests--with-buffer
    (md-file-anchor-tests--enable)
    (md-file-anchor-tests--press-ret "[r]")
    (should (equal (file-name-nondirectory (buffer-file-name)) "target.py"))
    (should (= (line-number-at-pos) 392))
    (should (equal (buffer-substring-no-properties
                    (line-beginning-position) (line-end-position))
                   "line 392"))))

(ert-deftest md-file-anchor-test-range-anchor-highlights-the-range ()
  "The pulse overlay spans exactly lines 392..400 of the target."
  (md-file-anchor-tests--with-buffer
    (md-file-anchor-tests--enable)
    (md-file-anchor-tests--press-ret "[r]")
    (should (overlayp pulse-momentary-overlay))
    (should (= (overlay-start pulse-momentary-overlay)
               (md-file-anchor-tests--line-pos 392 'bol)))
    (should (= (overlay-end pulse-momentary-overlay)
               (md-file-anchor-tests--line-pos 400 'eol)))))

(ert-deftest md-file-anchor-test-single-line-anchor ()
  "RET on target.py#L7 lands on line 7."
  (md-file-anchor-tests--with-buffer
    (md-file-anchor-tests--enable)
    (md-file-anchor-tests--press-ret "[s]")
    (should (equal (file-name-nondirectory (buffer-file-name)) "target.py"))
    (should (= (line-number-at-pos) 7))))

(ert-deftest md-file-anchor-test-gitlab-style-range ()
  "RET on target.py#L3-9 lands on line 3 and highlights through line 9."
  (md-file-anchor-tests--with-buffer
    (md-file-anchor-tests--enable)
    (md-file-anchor-tests--press-ret "[g]")
    (should (= (line-number-at-pos) 3))
    (should (= (overlay-end pulse-momentary-overlay)
               (md-file-anchor-tests--line-pos 9 'eol)))))

(ert-deftest md-file-anchor-test-jump-pushes-the-mark ()
  "C-u C-SPC returns to where the jump landed from -- line 1 of the file."
  (md-file-anchor-tests--with-buffer
    (md-file-anchor-tests--enable)
    (md-file-anchor-tests--press-ret "[r]")
    (should (= (line-number-at-pos) 392))
    (goto-char (mark t))
    (should (= (line-number-at-pos) 1))))

(ert-deftest md-file-anchor-test-heading-anchor-lands-on-the-heading ()
  "RET on notes.md#deferred-decisions opens notes.md at that heading."
  (md-file-anchor-tests--with-buffer
    (md-file-anchor-tests--enable)
    (md-file-anchor-tests--press-ret "[h]")
    (should (equal (file-name-nondirectory (buffer-file-name)) "notes.md"))
    (should (derived-mode-p 'markdown-ts-mode))
    (should (= (line-number-at-pos) 5))
    (should (equal (buffer-substring-no-properties
                    (line-beginning-position) (line-end-position))
                   "## Deferred Decisions"))))

(ert-deftest md-file-anchor-test-missing-heading-still-opens-the-file ()
  "An unresolvable heading anchor errors, but only after the file is open."
  (md-file-anchor-tests--with-buffer
    (md-file-anchor-tests--enable)
    (should-error (md-file-anchor-tests--press-ret "[m]")
                  :type 'user-error)
    (should (equal (file-name-nondirectory (buffer-file-name)) "notes.md"))))

(ert-deftest md-file-anchor-test-heading-anchor-on-non-markdown-target ()
  "A heading anchor on a non-markdown file opens it and goes no further."
  (md-file-anchor-tests--with-buffer
    (md-file-anchor-tests--enable)
    (md-file-anchor-tests--press-ret "[n]")
    (should (equal (file-name-nondirectory (buffer-file-name)) "target.py"))
    (should (= (line-number-at-pos) 1))))

;;;; The existing-file guard

(ert-deftest md-file-anchor-test-literal-hash-filename-opens-verbatim ()
  "A link to a file whose name really contains `#' is not split."
  (md-file-anchor-tests--with-buffer
    (md-file-anchor-tests--enable)
    (md-file-anchor-tests--press-ret "[l]")
    (should (equal (file-name-nondirectory (buffer-file-name)) "weird#L5.md"))))

;;;; Non-interference

(ert-deftest md-file-anchor-test-scheme-urls-still-browse ()
  "A https URL with a fragment keeps its whole fragment and browses."
  (md-file-anchor-tests--with-buffer
    (md-file-anchor-tests--enable)
    (let ((browsed nil))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _)
                   (setq browsed (substring-no-properties url)))))
        (md-file-anchor-tests--press-ret "[w]"))
      (should (equal browsed "https://example.com/a#b")))))

(ert-deftest md-file-anchor-test-in-buffer-fragments-still-jump ()
  "A pure #fragment link is upstream's business and jumps in-buffer."
  (md-file-anchor-tests--with-buffer
    (md-file-anchor-tests--enable)
    (md-file-anchor-tests--press-ret "[f]")
    (should (eq (current-buffer) buf))
    (should (= (line-number-at-pos) 1))))

(ert-deftest md-file-anchor-test-plain-file-links-pass-through ()
  "A file link without an anchor is handled by upstream, unchanged."
  (md-file-anchor-tests--with-buffer
    (md-file-anchor-tests--enable)
    (should (equal (md-file-anchor-tests--found-file "[p]") "target.py"))))

;;;; The parsers in isolation
;;
;; Each is a seam where a mistake silently corrupts behaviour, so their
;; edges are pinned directly.

(ert-deftest md-file-anchor-test-split-at-first-hash ()
  "URLs split at the first `#'; the anchor keeps any later ones."
  (should (equal (md-file-anchor-split "a/b.py#L1") '("a/b.py" . "L1")))
  (should (equal (md-file-anchor-split "a#b#c") '("a" . "b#c")))
  (should (equal (md-file-anchor-split "a/b.py#") '("a/b.py" . "")))
  (should (equal (md-file-anchor-split "a/b.py") '("a/b.py" . nil))))

(ert-deftest md-file-anchor-test-line-range-grammar ()
  "The forge line-anchor shapes parse; near misses are heading slugs."
  (should (equal (md-file-anchor-line-range "L392") '(392 . 392)))
  (should (equal (md-file-anchor-line-range "L392-L400") '(392 . 400)))
  (should (equal (md-file-anchor-line-range "L392-400") '(392 . 400)))
  (should (equal (md-file-anchor-line-range "L392C5-L400C10") '(392 . 400)))
  ;; A reversed range is normalised rather than rejected.
  (should (equal (md-file-anchor-line-range "L400-L392") '(392 . 400)))
  ;; Heading slugs, including ones that flirt with the grammar.
  (should-not (md-file-anchor-line-range "l392"))
  (should-not (md-file-anchor-line-range "L"))
  (should-not (md-file-anchor-line-range "L392-"))
  (should-not (md-file-anchor-line-range "line-2"))
  (should-not (md-file-anchor-line-range "deferred-decisions"))
  (should-not (md-file-anchor-line-range ""))
  (should-not (md-file-anchor-line-range nil)))

;;;; Reversibility
;;
;; The mode installs global advice, so `emacs-tools-reload' depends on it
;; coming back off cleanly.

(ert-deftest md-file-anchor-test-disabling-restores-upstream-behaviour ()
  "Switching the mode off returns live buttons to upstream's action."
  (md-file-anchor-tests--with-buffer
    (md-file-anchor-tests--enable)
    (md-file-anchor-mode -1)
    (redisplay t)
    (should (equal (md-file-anchor-tests--found-file "[r]")
                   "target.py#L392-L400"))
    (should-not (advice-member-p #'md-file-anchor--make-button
                                 'markdown-ts--make-link-button))))

(ert-deftest md-file-anchor-test-enabling-heals-an-open-buffer ()
  "A buffer fontified before the mode was on picks the fix up regardless.
`jit-lock' does not revisit fontified regions on its own; this is what
`md-file-anchor--reset-buffers' exists for."
  (md-file-anchor-tests--with-buffer
    ;; Precondition: the upstream-shaped button is already built on screen.
    (should (equal (md-file-anchor-tests--found-file "[r]")
                   "target.py#L392-L400"))
    (md-file-anchor-tests--enable)
    (md-file-anchor-tests--press-ret "[r]")
    (should (equal (file-name-nondirectory (buffer-file-name)) "target.py"))
    (should (= (line-number-at-pos) 392))))

(provide 'md-file-anchor-tests)

;;; md-file-anchor-tests.el ends here
