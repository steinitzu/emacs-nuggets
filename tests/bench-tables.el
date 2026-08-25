;;; bench-tables.el --- md-table-align performance benchmark -*- lexical-binding: t; -*-

;;; Commentary:

;; Benchmarks md-table-align against a buffer of many wide tables -- the
;; workload that produced user-visible lockups on open and window resize
;; (see docs/many-tables-open-resize-performance.md).  Run via
;; tests/run-bench.sh, which supplies a real TTY frame at a fixed size;
;; batch mode has no frame that lays text out.
;;
;; The fixture is generated, not stored: a deterministic file of the same
;; shape as the report that surfaced the problem (8 tables, several of
;; them far wider than any window), so the numbers are reproducible and
;; no real document needs committing.
;;
;; Two kinds of numbers come out:
;;
;; - Call counts (`string-pixel-width', layout and measurement passes).
;;   These are deterministic for a given fixture, frame size and code, and
;;   are the regression signal: they change only when the code's behavior
;;   changes.
;; - Wall/GC times.  Machine-dependent; comparable only across runs on the
;;   same machine, and even then only roughly.  A TTY also understates
;;   `string-pixel-width' -- in a GUI each call does real font shaping --
;;   which is exactly why the counts, not the times, are what to watch.
;;
;; The run appends nothing anywhere: it writes tests/.last-bench.log as a
;; ready-to-append Markdown section.  To record a run:
;;
;;   tests/run-bench.sh >> tests/bench-results.md

;;; Code:

(setq inhibit-startup-screen t
      make-backup-files nil
      auto-save-default nil
      create-lockfiles nil
      confirm-kill-emacs nil
      debug-on-error nil
      load-prefer-newer t)

(defconst bench--dir (file-name-directory (or load-file-name buffer-file-name)))
(defconst bench--root (expand-file-name ".." bench--dir))
(defconst bench--log (expand-file-name ".last-bench.log" bench--dir))

(require 'treesit)
(setq treesit-extra-load-path
      (list (expand-file-name ".test-env/tree-sitter" bench--root)))
(add-to-list 'load-path bench--root)
(require 'emacs-tools)
(require 'md-table-align)
(require 'markdown-ts-mode)
(require 'elp)
(require 'seq)

;;;; Fixture

(defconst bench--words
  ["platform" "permission" "delegation" "hierarchy" "membership" "override"
   "invitation" "endpoint" "migration" "listing" "baseline" "viewport"]
  "Word pool for cell text; indexed deterministically, never randomly.")

(defun bench--cell (row col len)
  "Return deterministic cell text near LEN chars for ROW, COL."
  (let ((s ""))
    (while (< (length s) len)
      (setq s (concat s (if (string-empty-p s) "" " ")
                      (aref bench--words
                            (mod (+ (* 7 row) (* 3 col) (length s))
                                 (length bench--words))))))
    (substring s 0 (min len (length s)))))

(defun bench--table (id rows cols cell-len)
  "Return a pipe table as a string.  Geometry is fixed by the arguments."
  (with-temp-buffer
    (dotimes (c cols)
      (insert "| " (format "col%d-%d" id c) " "))
    (insert "|\n")
    (dotimes (c cols)
      (insert (if (= (mod c 3) 2) "|---:" "|-----")))
    (insert "|\n")
    (dotimes (r rows)
      (dotimes (c cols)
        ;; Vary lengths so column widths differ from cell widths and the
        ;; viewport edge falls inside cells, not between them.
        (insert "| " (bench--cell r c (+ cell-len (* 5 (mod (+ r c) 4)))) " "))
      (insert "|\n"))
    (buffer-string)))

(defun bench--write-fixture (file)
  "Write the benchmark fixture to FILE; return FILE.
Eight tables: half of them wider than any plausible window (lines up to
~900 chars), half narrow, separated by prose -- the shape of the report
that surfaced the lockups."
  (with-temp-buffer
    (insert "# Benchmark fixture\n\n")
    (dotimes (i 8)
      (insert (format "## Section %d\n\n" i))
      (dotimes (p 3)
        (insert (bench--cell i p 70) ".\n\n"))
      (insert (if (= (mod i 2) 0)
                  ;; Wide: 8 columns of ~100-char cells, ~900-char lines.
                  (bench--table i 12 8 100)
                ;; Narrow: fits an ordinary window.
                (bench--table i 6 4 8)))
      (insert "\n"))
    (write-region (point-min) (point-max) file nil 'quiet))
  file)

;;;; Instrumentation

(defvar bench--spw-calls 0)
(advice-add 'string-pixel-width :around
            (lambda (fn &rest args)
              (setq bench--spw-calls (1+ bench--spw-calls))
              (apply fn args)))

(defun bench--calls (fn)
  "Return the elp call count recorded for FN."
  (let ((info (get fn elp-timer-info-property)))
    (if info (aref info 0) 0)))

(defvar bench--results nil)

(defmacro bench--scenario (label &rest body)
  "Run BODY as scenario LABEL, recording times and call counts."
  (declare (indent 1))
  `(progn
     (elp-reset-all)
     (setq bench--spw-calls 0)
     (let ((t0 (float-time))
           (gct0 gc-elapsed))
       ,@body
       (push (list ,label
                   (- (float-time) t0)
                   (- gc-elapsed gct0)
                   bench--spw-calls
                   (bench--calls 'md-table-align--layout-table)
                   (bench--calls 'md-table-align--measure-table)
                   (bench--calls 'md-table-align--split-at))
             bench--results))))

;;;; Report

(defun bench--git-rev ()
  (let ((default-directory bench--root))
    (string-trim (with-output-to-string
                   (with-current-buffer standard-output
                     (call-process "git" nil t nil
                                   "rev-parse" "--short" "HEAD"))))))

(defun bench--write-report (fixture-stats)
  (with-temp-buffer
    (insert (format "## %s — %s\n\n"
                    (format-time-string "%Y-%m-%d")
                    (bench--git-rev)))
    (insert (format "Emacs %s, frame %dx%d, fixture: %s\n\n"
                    emacs-version (frame-width) (frame-height) fixture-stats))
    (insert "| scenario | wall s | gc s | string-pixel-width"
            " | layout-table | measure passes | split-at |\n")
    (insert "|---|---|---|---|---|---|---|\n")
    (dolist (r (nreverse bench--results))
      (insert (apply #'format "| %s | %.3f | %.3f | %d | %d | %d | %d |\n" r)))
    (insert "\n")
    (write-region (point-min) (point-max) bench--log nil 'quiet)))

;;;; Run

(let ((exit 1))
  (unwind-protect
      (condition-case err
          (let* ((fixture (bench--write-fixture
                           (make-temp-file "bench-tables-" nil ".md")))
                 (stats (with-temp-buffer
                          (insert-file-contents fixture)
                          (format "%d lines, max line %d"
                                  (count-lines (point-min) (point-max))
                                  (let ((m 0))
                                    (goto-char (point-min))
                                    (while (not (eobp))
                                      (setq m (max m (- (line-end-position)
                                                        (line-beginning-position))))
                                      (forward-line 1))
                                    m)))))
            (elp-instrument-package "md-table-align")

            (bench--scenario "open"
              (find-file fixture)
              (markdown-ts-mode)
              (md-table-align-mode 1)
              (redisplay t))

            (bench--scenario "resize (3 window ops)"
              (split-window-right)
              (redisplay t)
              (delete-other-windows)
              (redisplay t)
              (split-window-right)
              (redisplay t))

            (delete-other-windows)
            (bench--scenario "page through"
              (goto-char (point-min))
              (let ((pages 0))
                (while (and (< (point) (point-max)) (< pages 40))
                  (ignore-errors (scroll-up-command))
                  (run-hooks 'post-command-hook)
                  (redisplay t)
                  (setq pages (1+ pages))
                  (when (>= (window-end nil t) (point-max))
                    (goto-char (point-max))))))

            (bench--write-report stats)
            (delete-file fixture)
            (setq exit 0))
        (error
         (write-region (format "BENCH ERROR: %S\n" err) nil bench--log nil 'quiet)))
    (kill-emacs exit)))

;;; bench-tables.el ends here
