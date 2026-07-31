;;; md-heading-scale-tests.el --- Tests for md-heading-scale -*- lexical-binding: t; -*-

;;; Commentary:

;; These run in real buffers under a real `markdown-ts-mode' with a real
;; tree-sitter parser, fontified by real `jit-lock' in a live window.
;;
;; One thing cannot be observed here: `:height' has no effect on a terminal
;; frame, which has a single character cell size -- and the suite runs on a TTY
;; frame, since that is what `posn-at-point' needs elsewhere.  So the evidence
;; is assembled in layers, as DESIGN.md sets out:
;;
;;   1. upstream's half -- a level-N heading really carries
;;      `markdown-ts-heading-N', read back after real fontification;
;;   2. our half -- the mode installs a relative `:height' remapping on
;;      exactly those faces, in this buffer only, and removes it exactly;
;;   3. the join -- `merge-face-attribute', the display engine's own primitive
;;      for folding a relative height into an underlying one, pins what those
;;      values will do.
;;
;; Plus, where the machine can provide it, a real graphical frame whose
;; rendered line heights are measured directly.  That test skips rather than
;; fails where there is no display, as the `termdex' tests skip without vterm.

;;; Code:

(require 'ert)
(require 'face-remap)
(require 'treesit)
(require 'markdown-ts-mode)
(require 'md-heading-scale)

;;;; Fixtures

(defconst md-heading-scale-tests--document
  "# Level one

## Level two

### Level three

#### Level four

##### Level five

###### Level six

Setext heading
==============

Body text.
"
  "Every heading shape `markdown-ts-mode' fontifies, plus body text.")

(defconst md-heading-scale-tests--level-text
  '((1 . "Level one")
    (2 . "Level two")
    (3 . "Level three")
    (4 . "Level four")
    (5 . "Level five")
    (6 . "Level six"))
  "Where each level's heading text is, for locating it in the fixture.")

;;;; Helpers

(defmacro md-heading-scale-tests--with-buffer (&rest body)
  "Display the fixture in a `markdown-ts-mode' window, then run BODY.
The mode is left off to start with, so each test begins from an
unscaled buffer."
  (declare (indent 0) (debug t))
  `(let ((buf (generate-new-buffer "*md-heading-scale-test*")))
     (unwind-protect
         (progn
           (switch-to-buffer buf)
           (insert md-heading-scale-tests--document)
           (goto-char (point-min))
           (markdown-ts-mode)
           (set-buffer-modified-p nil)
           ;; Let jit-lock fontify for real.
           (redisplay t)
           ,@body)
       (kill-buffer buf))))

(defun md-heading-scale-tests--face-at (search-string)
  "Return the `face' property where SEARCH-STRING starts in this buffer."
  (save-excursion
    (goto-char (point-min))
    (should (search-forward search-string nil t))
    (get-text-property (match-beginning 0) 'face)))

(defun md-heading-scale-tests--remapping (level)
  "Return the `face-remapping-alist' entry for LEVEL's heading face, or nil."
  (assq (intern (format "markdown-ts-heading-%d" level)) face-remapping-alist))

(defun md-heading-scale-tests--singly-remapped-p (level height)
  "Non-nil when LEVEL's face is remapped to HEIGHT exactly once.
A second remapping of the same face would show up as a further element,
and would silently multiply the two -- which is what a stale cookie left
by a refresh or a reload would look like."
  (let ((face (intern (format "markdown-ts-heading-%d" level))))
    (equal (md-heading-scale-tests--remapping level)
           ;; The trailing FACE is face-remap's explicit merge with the
           ;; face's own definition, and is there for a single remapping too.
           (list face (list :height height) face))))

(defun md-heading-scale-tests--height (level)
  "Return the remapped `:height' installed for LEVEL, or nil when unscaled."
  (when-let* ((entry (md-heading-scale-tests--remapping level)))
    ;; (FACE (:height F) FACE) -- the trailing FACE is face-remap's explicit
    ;; merge with the face's own definition.
    (plist-get (cadr entry) :height)))

(defun md-heading-scale-tests--graphical-frame ()
  "Return a new graphical frame, or nil when this machine cannot make one."
  (when-let* ((display (getenv "DISPLAY")))
    (ignore-errors
      (make-frame-on-display display '((visibility . nil)
                                       (width . 80)
                                       (height . 30))))))

(defun md-heading-scale-tests--line-pixel-height (window search-string)
  "Return the rendered pixel height of the line holding SEARCH-STRING."
  (with-selected-window window
    (save-excursion
      (goto-char (point-min))
      (should (search-forward search-string nil t))
      (cdr (window-text-pixel-size window (pos-bol) (pos-eol))))))

;;;; Layer 1: what markdown-ts-mode puts on the text
;;
;; The package rests entirely on these faces reaching the right text.  If
;; upstream renames them or stops applying them per level, this is what says
;; so -- everything else would keep passing while nothing rendered any bigger.

(ert-deftest md-heading-scale-tests-each-level-carries-its-own-face ()
  "A level-N heading's text carries `markdown-ts-heading-N'."
  (md-heading-scale-tests--with-buffer
    (pcase-dolist (`(,level . ,text) md-heading-scale-tests--level-text)
      (should (equal (md-heading-scale-tests--face-at text)
                     (list (intern (format "markdown-ts-heading-%d" level))))))))

(ert-deftest md-heading-scale-tests-body-text-carries-no-heading-face ()
  "Body text is untouched, so scaling a heading face cannot reach it."
  (md-heading-scale-tests--with-buffer
    (should-not (md-heading-scale-tests--face-at "Body text."))))

(ert-deftest md-heading-scale-tests-setext-headings-inherit-level-one ()
  "Setext headings track level 1 rather than needing their own remapping.
Face remapping is followed through `:inherit' (established on a TTY
frame with `:underline'; see DESIGN.md), so remapping
`markdown-ts-setext-heading' as well would scale it twice."
  (md-heading-scale-tests--with-buffer
    (should (equal (md-heading-scale-tests--face-at "Setext heading")
                   '(markdown-ts-setext-heading))))
  (should (eq (face-attribute 'markdown-ts-setext-heading :inherit)
              'markdown-ts-heading-1))
  (should (eq (face-attribute 'markdown-ts-setext-heading :height) 'unspecified)))

;;;; Layer 2: what the mode installs

(ert-deftest md-heading-scale-tests-installs-a-remapping-per-scaled-level ()
  "Every level with a multiplier gets a relative height on its own face."
  (md-heading-scale-tests--with-buffer
    (let ((md-heading-scale-values '(2.0 1.7 1.4 1.1 1.0 1.0)))
      (md-heading-scale-mode 1)
      (should (equal (md-heading-scale-tests--height 1) 2.0))
      (should (equal (md-heading-scale-tests--height 2) 1.7))
      (should (equal (md-heading-scale-tests--height 3) 1.4))
      (should (equal (md-heading-scale-tests--height 4) 1.1))
      ;; Relative, not absolute -- this is what keeps text-scale working.
      (should (face-attribute-relative-p
               :height (md-heading-scale-tests--height 1))))))

(ert-deftest md-heading-scale-tests-a-multiplier-of-one-installs-nothing ()
  "An unscaled level is absent from `face-remapping-alist', not remapped to 1."
  (md-heading-scale-tests--with-buffer
    (let ((md-heading-scale-values '(2.0 1.7 1.4 1.1 1.0 1.0)))
      (md-heading-scale-mode 1)
      (should-not (md-heading-scale-tests--remapping 5))
      (should-not (md-heading-scale-tests--remapping 6)))))

(ert-deftest md-heading-scale-tests-a-short-list-leaves-the-rest-alone ()
  "Levels past the end of the list are not scaled."
  (md-heading-scale-tests--with-buffer
    (let ((md-heading-scale-values '(1.6)))
      (md-heading-scale-mode 1)
      (should (equal (md-heading-scale-tests--height 1) 1.6))
      (dolist (level '(2 3 4 5 6))
        (should-not (md-heading-scale-tests--remapping level))))))

(ert-deftest md-heading-scale-tests-integers-are-accepted ()
  "A multiplier written as an integer is still a relative height.
`2' and `2.0' mean the same thing to a reader; to `face-remapping-alist'
an integer `:height' is an absolute size in 1/10 pt, which would pin
headings at 0.2pt.  So the value is floated on the way in."
  (md-heading-scale-tests--with-buffer
    (let ((md-heading-scale-values '(2 1 1 1 1 1)))
      (md-heading-scale-mode 1)
      (should (equal (md-heading-scale-tests--height 1) 2.0))
      (should (face-attribute-relative-p
               :height (md-heading-scale-tests--height 1)))
      ;; And an integer 1 still means "leave this level alone".
      (should-not (md-heading-scale-tests--remapping 2)))))

(ert-deftest md-heading-scale-tests-is-buffer-local ()
  "Scaling one Markdown buffer leaves another one alone."
  (md-heading-scale-tests--with-buffer
    (md-heading-scale-mode 1)
    (should (md-heading-scale-tests--remapping 1))
    (let ((other (generate-new-buffer "*md-heading-scale-other*")))
      (unwind-protect
          (with-current-buffer other
            (insert md-heading-scale-tests--document)
            (markdown-ts-mode)
            (should-not md-heading-scale-mode)
            (should-not (md-heading-scale-tests--remapping 1)))
        (kill-buffer other)))))

(ert-deftest md-heading-scale-tests-switching-off-restores-exactly ()
  "`face-remapping-alist' comes back to the value it had, `equal'-identically."
  (md-heading-scale-tests--with-buffer
    (let ((before face-remapping-alist))
      (md-heading-scale-mode 1)
      (should-not (equal before face-remapping-alist))
      (md-heading-scale-mode -1)
      (should (equal before face-remapping-alist)))))

(ert-deftest md-heading-scale-tests-leaves-foreign-remappings-alone ()
  "A remapping from elsewhere survives untouched, and ours sits alongside it.
`mixed-pitch-mode' and `text-scale-mode' both work by remapping faces in
the same buffer; removing our cookies by identity is what keeps theirs
out of it."
  (md-heading-scale-tests--with-buffer
    ;; Stand in for text-scale-mode, which remaps `default' relatively.
    (let ((cookie (face-remap-add-relative 'default '(:height 1.2))))
      (unwind-protect
          (let ((foreign (assq 'default face-remapping-alist)))
            (should foreign)
            (md-heading-scale-mode 1)
            (should (equal (assq 'default face-remapping-alist) foreign))
            (md-heading-scale-mode -1)
            (should (equal (assq 'default face-remapping-alist) foreign))
            (should (equal face-remapping-alist (list foreign))))
        (face-remap-remove-relative cookie)))))

(ert-deftest md-heading-scale-tests-refresh-takes-up-a-changed-value ()
  "Setting `md-heading-scale-values' re-applies in live buffers."
  (md-heading-scale-tests--with-buffer
    (let ((original md-heading-scale-values))
      (unwind-protect
          (progn
            (md-heading-scale-mode 1)
            (setopt md-heading-scale-values '(3.0 1.0 1.0 1.0 1.0 1.0))
            (should (equal (md-heading-scale-tests--height 1) 3.0))
            ;; Levels that were scaled under the old value stop being.
            (should-not (md-heading-scale-tests--remapping 2))
            ;; And the old level-1 cookie is gone rather than stacked under
            ;; the new one, which would render at 2.0 x 3.0.
            (should (md-heading-scale-tests--singly-remapped-p 1 3.0)))
        (setopt md-heading-scale-values original)))))

(ert-deftest md-heading-scale-tests-refresh-skips-buffers-without-the-mode ()
  "A buffer that never had the mode on is not scaled by a refresh."
  (md-heading-scale-tests--with-buffer
    (md-heading-scale-refresh)
    (should-not face-remapping-alist)))

;;;; Layer 3: what the display engine will do with those values
;;
;; `merge-face-attribute' is the primitive that folds a relative attribute into
;; the value underneath it, so it answers "what height will this text end up
;; with" without needing a display to render on.

(ert-deftest md-heading-scale-tests-heights-multiply-and-keep-their-order ()
  "The installed multipliers scale a real height, and levels stay ordered."
  (md-heading-scale-tests--with-buffer
    (let ((md-heading-scale-values '(2.0 1.7 1.4 1.1 1.0 1.0)))
      (md-heading-scale-mode 1)
      (let ((h1 (md-heading-scale-tests--height 1))
            (h3 (md-heading-scale-tests--height 3)))
        ;; A 10pt body gives a 20pt level-1 heading.
        (should (= (merge-face-attribute :height h1 100) 200))
        (should (> (merge-face-attribute :height h1 100)
                   (merge-face-attribute :height h3 100)))
        ;; Level 5 is unscaled, so it is body height exactly.
        (should-not (md-heading-scale-tests--height 5))
        ;; Stacked on a text-scale-style relative height, the ratio holds:
        ;; scaling the buffer by 1.5 makes the heading 1.5x bigger too.
        (should (= (merge-face-attribute
                    :height h1 (merge-face-attribute :height 1.5 100))
                   300))))))

(ert-deftest md-heading-scale-tests-default-values-match-markdown-mode ()
  "The defaults are the ones `markdown-header-scaling-values' ships.
Coming from `markdown-mode', headings should look like they did."
  (should (equal md-heading-scale-values '(2.0 1.7 1.4 1.1 1.0 1.0)))
  (should (= (length md-heading-scale-values) md-heading-scale-max-level)))

;;;; Layer 4: rendered pixels, where a display can be had

(ert-deftest md-heading-scale-tests-headings-render-taller ()
  "On a graphical display, scaled headings really do occupy more pixels.

This is the only assertion that observes the actual point of the
package.  It needs a graphical frame: a terminal has one character cell
size, so `:height' changes nothing there.  Skipped when no display is
available, and when the frame cannot be measured."
  (let ((frame (md-heading-scale-tests--graphical-frame)))
    (unless frame
      (ert-skip "no graphical display to render on"))
    (unwind-protect
        (md-heading-scale-tests--with-buffer
          (let ((md-heading-scale-values '(2.0 1.7 1.4 1.1 1.0 1.0))
                (window (frame-selected-window frame)))
            (md-heading-scale-mode 1)
            (set-window-buffer window (current-buffer))
            (redisplay t)
            (let ((body (md-heading-scale-tests--line-pixel-height
                         window "Body text."))
                  (h1 (md-heading-scale-tests--line-pixel-height
                       window "Level one"))
                  (h3 (md-heading-scale-tests--line-pixel-height
                       window "Level three"))
                  (h5 (md-heading-scale-tests--line-pixel-height
                       window "Level five")))
              (unless (and (natnump body) (> body 0))
                (ert-skip "frame reports no line height to compare against"))
              (should (> h1 h3))
              (should (> h3 body))
              ;; Level 5 has no remapping, so it must match body text exactly.
              (should (= h5 body)))))
      (delete-frame frame))))

;;;; Reload

(ert-deftest md-heading-scale-tests-reload-leaves-one-set-of-remappings ()
  "`emacs-tools-reload' comes back with the mode on and nothing doubled.
The mode is switched off and on around the unload, so a buffer must not
end up holding both the old cookies and the new ones."
  (md-heading-scale-tests--with-buffer
    (md-heading-scale-mode 1)
    (let ((buffer (current-buffer))
          (scaled (length face-remapping-alist)))
      (should (> scaled 0))
      (emacs-tools-reload 'md-heading-scale)
      (with-current-buffer buffer
        (should md-heading-scale-mode)
        (should (= (length face-remapping-alist) scaled))
        ;; One remapping per face, not the old one with the new on top.
        (should (md-heading-scale-tests--singly-remapped-p
                 1 (car md-heading-scale-values)))))))

(ert-deftest md-heading-scale-tests-unloading-unscales-every-buffer ()
  "`unload-feature' leaves no buffer scaled by code that is no longer there."
  (md-heading-scale-tests--with-buffer
    (md-heading-scale-mode 1)
    (should face-remapping-alist)
    (let ((buffer (current-buffer)))
      (unwind-protect
          (progn
            (unload-feature 'md-heading-scale t)
            (with-current-buffer buffer
              (should-not face-remapping-alist)))
        ;; Put the feature back for whatever runs next.
        (load "md-heading-scale" nil t)))))

(provide 'md-heading-scale-tests)

;;; md-heading-scale-tests.el ends here
