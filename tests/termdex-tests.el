;;; termdex-tests.el --- Tests for termdex -*- lexical-binding: t; -*-

;;; Commentary:

;; Driven against real terminals running real shells: a terminal is started,
;; text is typed into it, and the assertions are about what /proc then says.
;; There is nothing to usefully mock here -- the whole package is a claim about
;; what a process tree looks like, and only a real one can refute it.
;;
;; Every terminal test runs once per backend, vterm and ghostel, as NAME--vterm
;; and NAME--ghostel.  Each skips itself when its backend is not installed
;; (`make deps' installs both), so the rest of the collection's tests still
;; run.
;;
;; Nothing waits a fixed number of seconds.  A shell takes as long as it takes
;; to reach its prompt, and a fixed wait is a test that fails on a loaded
;; machine; every wait here polls for the condition it actually needs.

;;; Code:

(require 'ert)
(require 'termdex)

(defconst termdex-tests--backends
  (seq-filter (lambda (backend)
                (pcase backend
                  ('vterm (require 'vterm nil t))
                  ;; ghostel loads without its native module and fetches it
                  ;; on first use, after a prompt; a batch run cannot answer.
                  ('ghostel (and (require 'ghostel nil t)
                                 (locate-library "ghostel-module")))))
              '(vterm ghostel))
  "The backends that could be loaded, so their tests can run.")

(defvar termdex-tests--backend nil
  "The backend the running test drives.")

(defconst termdex-tests--timeout 15
  "Seconds to wait for a shell to do something before giving up.")


;;;; Helpers

(defun termdex-tests--wait (predicate)
  "Poll PREDICATE until it returns non-nil, or the timeout expires.
Returns what PREDICATE returned, so a failing wait fails the assertion
that asked for it rather than silently continuing."
  (let ((deadline (time-add nil termdex-tests--timeout))
        (result nil))
    (while (and (not result) (time-less-p nil deadline))
      (setq result (funcall predicate))
      (unless result (accept-process-output nil 0.05)))
    result))

(defun termdex-tests--directory-is (buffer directory)
  "Wait until BUFFER's terminal reports being in DIRECTORY."
  (let ((want (termdex--canonical directory)))
    (termdex-tests--wait
     (lambda () (equal (termdex-terminal-directory (termdex--probe buffer)) want)))))

(defun termdex-tests--settle (_buffer)
  "Give a terminal's shell a chance to act on anything sent to it.

For asserting that something did *not* happen.  Waiting out the full
timeout to prove a negative would make the suite mostly sleep, so this
waits a shell round trip instead -- long enough that the same wait is
comfortably sufficient when the thing is supposed to happen, which the
positive tests demonstrate it is."
  (let ((deadline (time-add nil 2)))
    (while (time-less-p nil deadline)
      (accept-process-output nil 0.05))))

(defun termdex-tests--busy (buffer &optional command)
  "Wait until BUFFER's terminal is busy, and return what it is running.

With COMMAND, wait until that is what it is running, rather than
settling for the first busy reading.  This is not impatience, it is a
race in /proc: `execve' installs the new program's argument vector
before it updates the process name, so for a moment a shell that is
starting `sleep 60' reads as command line \"sleep 60\" under the name
\"bash\".  `termdex--interactive-shell-p' sees a non-option argument and
correctly declines to call that a shell you could type at, so the probe
falls back to the shell above it and reports the child by the only name
/proc will give: \"bash\".  Measured directly, the window opens on
roughly one exec in a thousand -- and this suite polls hard enough to
have landed in it about one run in three.

Nothing can close that window from outside the kernel, and it shuts by
itself in microseconds, so the fix belongs here: wait for the command
the shell was told to run.  On timeout the last reading is returned
rather than nil, so an assertion that fails for a real reason still says
what it saw."
  (let ((last nil))
    (or (termdex-tests--wait
         (lambda ()
           (let ((terminal (termdex--probe buffer)))
             (when (termdex-terminal-busy terminal)
               (setq last (or (termdex-terminal-command terminal) t))
               (unless (and command (not (equal last command)))
                 last)))))
        last)))

(defun termdex-tests--idle (buffer)
  "Wait until BUFFER's terminal is idle."
  (termdex-tests--wait
   (lambda () (not (termdex-terminal-busy (termdex--probe buffer))))))

(defun termdex-tests--type (buffer string)
  "Type STRING into BUFFER's terminal."
  (termdex--send-string buffer string))

(defun termdex-tests--terminal (directory &optional backend)
  "Start a terminal in DIRECTORY and wait for its shell to settle there.
Of the test's backend, or BACKEND."
  (let* ((default-directory (file-name-as-directory directory))
         (buffer (termdex--start (or backend termdex-tests--backend)
                                 (generate-new-buffer-name "*termdex-test*"))))
    (should (termdex-tests--directory-is buffer directory))
    (should (termdex-tests--idle buffer))
    buffer))

(defmacro termdex-tests--with-project (root &rest body)
  "Bind ROOT to a fresh temporary project directory and run BODY.
The directory holds a .git, so `project-current' finds a root there and
ancestor matching is switched on -- without one, only exact matches
count and half of these tests would be testing nothing."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,root (file-name-as-directory (make-temp-file "termdex-" t))))
     (unwind-protect
         (progn (make-directory (expand-file-name ".git" ,root) t)
                ,@body)
       (delete-directory ,root t))))

(defmacro termdex-tests--with-terminals (&rest body)
  "Run BODY, then kill every buffer it created and stop any dashboard timer.
A live process makes `kill-buffer' ask for confirmation, which would
hang a batch run, so the kill goes through `termdex--kill'."
  (declare (indent 0) (debug t))
  `(let ((before (buffer-list)))
     (unwind-protect (progn ,@body)
       (termdex--list-stop-timer)
       (dolist (buffer (buffer-list))
         (unless (memq buffer before)
           (when (buffer-live-p buffer)
             (termdex--kill buffer)))))))

(defmacro termdex-tests--deftest (name _arglist &rest body)
  "Define NAME--vterm and NAME--ghostel, each running BODY on that backend.
Each skips when its backend cannot be loaded.  BODY may start with a
docstring, which both tests carry."
  (declare (indent 2) (doc-string 3) (debug (symbolp sexp body)))
  (let ((doc (when (stringp (car body)) (list (pop body)))))
    `(progn
       ,@(mapcar
          (lambda (backend)
            `(ert-deftest ,(intern (format "%s--%s" name backend)) ()
               ,@doc
               (skip-unless (memq ',backend termdex-tests--backends))
               (let ((termdex-tests--backend ',backend)
                     (termdex-backend ',backend))
                 (termdex-tests--with-terminals ,@body))))
          '(vterm ghostel)))))

(defmacro termdex-tests--with-cleanup (seconds &rest body)
  "Run BODY with the cleanup threshold at SECONDS and the timer off.

The mode is on by default, so the suite runs with a live sweep timer.
With the threshold turned down to a second, a sweep fired from an idle
moment could reach into a terminal another test is still using, so the
mode is switched off for the duration and put back as it was."
  (declare (indent 1) (debug (form body)))
  `(let ((termdex-tests--cleanup-was termdex-cleanup-mode)
         (termdex-cleanup-idle-seconds ,seconds)
         (termdex--cleanup-last-sweep nil))
     (unwind-protect
         (progn (termdex-cleanup-mode -1) ,@body)
       (termdex-cleanup-mode (if termdex-tests--cleanup-was 1 -1)))))

(defun termdex-tests--pause (seconds)
  "Let SECONDS of wall clock pass, pumping process output meanwhile.
The one place a fixed wait is right: what is being waited for is time
itself, since the assertion is about a terminal having been quiet for
long enough."
  (let ((deadline (time-add nil seconds)))
    (while (time-less-p nil deadline)
      (accept-process-output nil 0.05))))

(defun termdex-tests--mark (buffer)
  "Return BUFFER's activity mark, as the sweep reads it."
  (termdex--activity-mark (termdex--probe buffer)))

(defun termdex-tests--quiet (buffer)
  "Wait until BUFFER's terminal has written nothing for half a second.

A shell reaches its prompt in stages: /proc calls it idle as soon as
nothing is running, while it is still printing.  The sweep reads output
as activity and restarts the clock, so a test that sweeps before the
terminal has gone quiet is timing the shell's startup rather than its
own pause -- and every terminal survives, protected or not."
  (let ((mark nil) (since nil))
    (termdex-tests--wait
     (lambda ()
       (let ((now (termdex-tests--mark buffer)))
         (unless (equal mark now)
           (setq mark now since (current-time)))
         (time-less-p (time-add since 0.5) nil))))))

(defun termdex-tests--spoke (buffer string)
  "Type STRING into BUFFER and wait until the terminal writes something.
Returns non-nil if output arrived, which is what the sweep reads as
activity."
  (let ((before (termdex-tests--mark buffer)))
    (termdex-tests--type buffer string)
    (termdex-tests--wait
     (lambda () (not (equal before (termdex-tests--mark buffer)))))))


;;;; Probing: where a terminal is, and whether it is busy

(termdex-tests--deftest termdex-cwd-follows-a-cd ()
  "A `cd' typed into a terminal moves the terminal."
  (termdex-tests--with-project root
    (let ((child (expand-file-name "child" root))
          (buffer nil))
      (make-directory child)
      (setq buffer (termdex-tests--terminal root))
      (termdex-tests--type buffer (format "cd %s\n" child))
      (should (termdex-tests--directory-is buffer child)))))

(termdex-tests--deftest termdex-cwd-is-not-default-directory ()
  "The probe does not rely on `default-directory', which goes stale.
Without vterm's shell-side integration it never moves at all; this is
the reason the package reads /proc rather than believing the buffer."
  (termdex-tests--with-project root
    (let ((child (expand-file-name "child" root))
          (buffer nil))
      (make-directory child)
      (setq buffer (termdex-tests--terminal root))
      (termdex-tests--type buffer (format "cd %s\n" child))
      (should (termdex-tests--directory-is buffer child))
      ;; The probe found the new directory; whatever `default-directory'
      ;; says, `termdex-current-directory' must agree with the probe.
      (with-current-buffer buffer
        (should (equal (termdex-current-directory) (termdex--canonical child)))))))

(termdex-tests--deftest termdex-reports-a-running-command ()
  "A foreground job makes the terminal busy, by name, until it is stopped."
  (termdex-tests--with-project root
    (let ((buffer (termdex-tests--terminal root)))
      (termdex-tests--type buffer "sleep 60\n")
      (should (equal (termdex-tests--busy buffer "sleep") "sleep"))
      (termdex-tests--type buffer "\C-c")
      (should (termdex-tests--idle buffer)))))

(termdex-tests--deftest termdex-background-job-is-idle ()
  "A backgrounded job leaves the terminal idle: there is still a prompt."
  (termdex-tests--with-project root
    (let ((buffer (termdex-tests--terminal root)))
      (termdex-tests--type buffer "sleep 60 &\n")
      ;; Give the job time to exist before concluding anything from its
      ;; absence, or this passes for the wrong reason.
      (should (termdex-tests--wait
               (lambda () (termdex--children
                           (termdex--current-shell (termdex--leader-pid buffer))))))
      (should (termdex-tests--idle buffer)))))


;;;; Probing through a nested shell

(termdex-tests--deftest termdex-follows-a-nested-shell ()
  "A shell started inside a terminal becomes the terminal's shell.
Read from the pty leader alone, the terminal would freeze at ROOT and
report itself busy for as long as the nested shell lived."
  (termdex-tests--with-project root
    (let ((child (expand-file-name "child" root))
          (buffer nil))
      (make-directory child)
      (setq buffer (termdex-tests--terminal root))
      (termdex-tests--type buffer "bash --norc\n")
      ;; At the nested prompt: idle, despite the leader having a child.
      (should (termdex-tests--idle buffer))
      (termdex-tests--type buffer (format "cd %s\n" child))
      (should (termdex-tests--directory-is buffer child))
      ;; And a job inside the nested shell is still seen as a job.
      (termdex-tests--type buffer "sleep 60\n")
      (should (equal (termdex-tests--busy buffer "sleep") "sleep"))
      ;; The directory is still the nested shell's while that job runs.
      (should (equal (termdex-terminal-directory (termdex--probe buffer))
                     (termdex--canonical child))))))

(termdex-tests--deftest termdex-does-not-follow-a-shell-script ()
  "`bash -c' is not a shell to type at, though it is called bash.
Following it would report a running script as an idle prompt, since a
`bash -c' waiting on its own child sits in the foreground group exactly
as an interactive shell at a prompt does.

The trailing `:' matters: bash execs a lone command in place, so
`bash -c \\='sleep 60\\='' leaves no bash process at all and would test
nothing."
  (termdex-tests--with-project root
    (let ((buffer (termdex-tests--terminal root)))
      (termdex-tests--type buffer "bash -c 'sleep 60; :'\n")
      (should (termdex-tests--busy buffer))
      (should (equal (termdex-terminal-command (termdex--probe buffer)) "bash")))))

(ert-deftest termdex-interactive-shell-p-reads-command-lines ()
  "Options mean an interactive shell; an argument or -c means a script."
  (cl-letf* ((cmdlines '((1 . ("bash"))
                         (2 . ("bash" "--norc"))
                         (3 . ("-bash"))
                         (4 . ("bash" "-i"))
                         (5 . ("bash" "./deploy.sh"))
                         (6 . ("bash" "-c" "sleep 60"))
                         (7 . ("sh" "-ec" "make"))))
             ((symbol-function 'termdex--comm)
              (lambda (pid) (string-remove-prefix "-" (car (alist-get pid cmdlines)))))
             ((symbol-function 'termdex--cmdline)
              (lambda (pid) (alist-get pid cmdlines))))
    (should (termdex--interactive-shell-p 1))
    (should (termdex--interactive-shell-p 2))
    (should (termdex--interactive-shell-p 3))
    (should (termdex--interactive-shell-p 4))
    (should-not (termdex--interactive-shell-p 5))
    (should-not (termdex--interactive-shell-p 6))
    (should-not (termdex--interactive-shell-p 7))))


;;;; Matching

(termdex-tests--deftest termdex-match-prefers-the-deepest-directory ()
  "An exact match beats a parent, and a nearer parent beats a further one."
  (termdex-tests--with-project root
    (let* ((a (expand-file-name "a/" root))
           (b (expand-file-name "a/b/" root)))
      (make-directory b t)
      (let ((root-term (termdex-tests--terminal root))
            (a-term (termdex-tests--terminal a))
            (b-term (termdex-tests--terminal b)))
        (should (eq (termdex-terminal-buffer (termdex--match (termdex--canonical b)))
                    b-term))
        (should (eq (termdex-terminal-buffer (termdex--match (termdex--canonical a)))
                    a-term))
        (should (eq (termdex-terminal-buffer (termdex--match (termdex--canonical root)))
                    root-term))))))

(termdex-tests--deftest termdex-match-does-not-climb-past-the-project-root ()
  "A terminal outside the project is not a match, however near it is."
  (termdex-tests--with-project outer
    (let* ((inner (expand-file-name "inner/" outer)))
      (make-directory (expand-file-name ".git" inner) t)
      (let ((outer-term (termdex-tests--terminal outer)))
        ;; `outer' is the parent of `inner' on disk, but `inner' is its own
        ;; project, so the search must stop before reaching that terminal.
        (should-not (termdex--match (termdex--canonical inner)))
        (should (eq (termdex-terminal-buffer (termdex--match (termdex--canonical outer)))
                    outer-term))))))

(termdex-tests--deftest termdex-match-breaks-ties-by-recency ()
  "Two terminals in one directory: the most recently used wins."
  (termdex-tests--with-project root
    (let ((first (termdex-tests--terminal root))
          (second (termdex-tests--terminal root)))
      (should (eq (termdex-terminal-buffer (termdex--match (termdex--canonical root)))
                  second))
      ;; Visiting the older one makes it the most recent.
      (with-current-buffer first (buffer-list))
      (switch-to-buffer first)
      (should (eq (termdex-terminal-buffer (termdex--match (termdex--canonical root)))
                  first)))))

(termdex-tests--deftest termdex-idle-search-skips-a-busy-terminal ()
  "`termdex-here' takes a busy match; `termdex-here-idle' does not."
  (termdex-tests--with-project root
    (let ((buffer (termdex-tests--terminal root))
          (directory (termdex--canonical root)))
      (termdex-tests--type buffer "sleep 60\n")
      (should (termdex-tests--busy buffer))
      (should (eq (termdex-terminal-buffer (termdex--match directory)) buffer))
      (should-not (termdex--match directory t)))))


;;;; Reaching a terminal

(termdex-tests--deftest termdex-here-reuses-and-follows-you-down ()
  "Reusing a parent's terminal sends it a `cd', when that is switched on."
  (termdex-tests--with-project root
    (let* ((child (expand-file-name "child/" root))
           (buffer nil))
      (make-directory child t)
      (setq buffer (termdex-tests--terminal root))
      (let ((termdex-cd-on-ancestor-match t)
            (default-directory child))
        (with-temp-buffer
          (setq default-directory child)
          (save-window-excursion (termdex-here))))
      (should (termdex-tests--directory-is buffer child)))))

(termdex-tests--deftest termdex-here-leaves-a-terminal-alone-when-told-to ()
  "With `termdex-cd-on-ancestor-match' off, the terminal stays where it is."
  (termdex-tests--with-project root
    (let* ((child (expand-file-name "child/" root))
           (buffer nil))
      (make-directory child t)
      (setq buffer (termdex-tests--terminal root))
      (let ((termdex-cd-on-ancestor-match nil))
        (with-temp-buffer
          (setq default-directory child)
          (save-window-excursion (termdex-here))))
      (termdex-tests--settle buffer)
      (should (equal (termdex-terminal-directory (termdex--probe buffer))
                     (termdex--canonical root))))))

(termdex-tests--deftest termdex-never-types-into-a-busy-terminal ()
  "A busy terminal is reused as it stands: the `cd' would go to the job.

`cat' stands in for any program that reads: it is a real process, so the
terminal is genuinely busy, and anything typed at the terminal lands in
its output file.  That file staying empty is the assertion -- a `cd'
sent here would have been swallowed by the job with no other trace."
  (termdex-tests--with-project root
    (let* ((child (expand-file-name "child/" root))
           (swallowed (expand-file-name "swallowed" root))
           (buffer nil))
      (make-directory child t)
      (setq buffer (termdex-tests--terminal root))
      (termdex-tests--type buffer (format "cat > %s\n" swallowed))
      (should (equal (termdex-tests--busy buffer "cat") "cat"))
      (let ((termdex-cd-on-ancestor-match t))
        (with-temp-buffer
          (setq default-directory child)
          (save-window-excursion (termdex-here))))
      (termdex-tests--settle buffer)
      (should (termdex-terminal-busy (termdex--probe buffer)))
      ;; End the job so `cat' flushes whatever it was given, then look.
      (termdex-tests--type buffer "\C-d")
      (should (termdex-tests--idle buffer))
      (should (equal 0 (file-attribute-size (file-attributes swallowed)))))))

(termdex-tests--deftest termdex-project-root-reuses-a-root-terminal ()
  "`termdex-project-root' from a subdirectory lands at the root.
The root terminal is an exact match for the root, so no `cd' is sent
and it stays where it is."
  (termdex-tests--with-project root
    (let* ((child (expand-file-name "child/" root))
           (buffer nil)
           (reached nil))
      (make-directory child t)
      (setq buffer (termdex-tests--terminal root))
      (with-temp-buffer
        (setq default-directory child)
        (setq reached (save-window-excursion (termdex-project-root))))
      (should (eq reached buffer))
      (termdex-tests--settle buffer)
      (should (equal (termdex-terminal-directory (termdex--probe buffer))
                     (termdex--canonical root))))))

(termdex-tests--deftest termdex-project-root-creates-at-the-root ()
  "With no terminal at the root, one is made there, not here.
A terminal below the root is no match either: its directory is not a
prefix of the root, and grabbing it would drag you into whatever
subdirectory it had wandered off to."
  (termdex-tests--with-project root
    (let* ((child (expand-file-name "child/" root))
           (existing nil)
           (created nil))
      (make-directory child t)
      (setq existing (termdex-tests--terminal child))
      (with-temp-buffer
        (setq default-directory child)
        (setq created (save-window-excursion (termdex-project-root))))
      (should-not (eq created existing))
      (should (termdex-tests--directory-is created root)))))

(termdex-tests--deftest termdex-project-root-idle-skips-a-busy-root-terminal ()
  "`termdex-project-root-idle' spawns rather than land in a busy root."
  (termdex-tests--with-project root
    (let ((buffer (termdex-tests--terminal root))
          (created nil))
      (termdex-tests--type buffer "sleep 60\n")
      (should (termdex-tests--busy buffer))
      (with-temp-buffer
        (setq default-directory root)
        (setq created (save-window-excursion (termdex-project-root-idle))))
      (should-not (eq created buffer))
      (should (termdex-tests--directory-is created root)))))

(termdex-tests--deftest termdex-project-root-outside-a-project-is-here ()
  "With no project there is no root, so the current directory is used."
  (let ((directory (file-name-as-directory (make-temp-file "termdex-" t))))
    (unwind-protect
        (let ((created nil))
          (should-not (termdex--project-root (termdex--canonical directory)))
          (with-temp-buffer
            (setq default-directory directory)
            (setq created (save-window-excursion (termdex-project-root))))
          (should (termdex-tests--directory-is created directory)))
      (delete-directory directory t))))

(termdex-tests--deftest termdex-new-always-makes-a-terminal ()
  "`termdex-new' ignores a perfectly good match."
  (termdex-tests--with-project root
    (let ((existing (termdex-tests--terminal root))
          (created nil))
      (with-temp-buffer
        (setq default-directory root)
        (setq created (save-window-excursion (termdex-new))))
      (should-not (eq created existing))
      (should (termdex-tests--directory-is created root)))))


;;;; Excluded terminals
;;
;; A terminal someone else drives -- a coding agent's session, say -- is in
;; your project directory and is a perfectly good vterm, so every rule above
;; matches it.  Walking into one looking for a shell prompt is not what you
;; wanted.

(termdex-tests--deftest termdex-excluded-terminal-is-not-a-match ()
  "An excluded terminal is not matched, switched to, or listed."
  (termdex-tests--with-project root
    (let ((excluded (termdex-tests--terminal root)))
      (with-current-buffer excluded (setq-local termdex-exclude t))
      (should-not (termdex--match (termdex--canonical root)))
      (should-not (seq-find (lambda (terminal)
                              (eq (termdex-terminal-buffer terminal) excluded))
                            (termdex-terminals)))
      ;; And a new one is made rather than the excluded one being reused.
      (let ((reached (with-temp-buffer
                       (setq default-directory root)
                       (save-window-excursion (termdex-here)))))
        (should-not (eq reached excluded))))))

(termdex-tests--deftest termdex-exclusion-can-come-from-a-predicate ()
  "`termdex-exclude-functions' excludes terminals you did not create."
  (termdex-tests--with-project root
    (let* ((excluded (termdex-tests--terminal root))
           (termdex-exclude-functions
            (list (lambda (buffer) (eq buffer excluded)))))
      (should-not (termdex--match (termdex--canonical root)))
      (should (termdex--terminal-buffer-p excluded))
      (should-not (termdex--candidate-p excluded)))))

(termdex-tests--deftest termdex-excluded-terminal-still-knows-where-it-is ()
  "A command run from inside an excluded terminal starts from its directory.

Excluding it from the search must not make it invisible to the probe:
`default-directory' in a vterm does not follow a `cd', so falling back
to it would spawn the new terminal in the wrong place."
  (termdex-tests--with-project root
    (let ((child (expand-file-name "child/" root))
          (excluded nil))
      (make-directory child t)
      (setq excluded (termdex-tests--terminal root))
      (with-current-buffer excluded (setq-local termdex-exclude t))
      (termdex-tests--type excluded (format "cd %s\n" child))
      (should (termdex-tests--directory-is excluded child))
      (with-current-buffer excluded
        (should (equal (termdex-current-directory) (termdex--canonical child)))
        (let ((created (save-window-excursion (termdex-here))))
          (should-not (eq created excluded))
          (should (termdex-tests--directory-is created child)))))))

(termdex-tests--deftest termdex-list-can-show-excluded-terminals ()
  "The dashboard hides excluded terminals, and shows them on request."
  (termdex-tests--with-project root
    (let ((excluded (termdex-tests--terminal root)))
      (with-current-buffer excluded (setq-local termdex-exclude t))
      (save-window-excursion (termdex-list))
      (with-current-buffer termdex-list-buffer-name
        (should-not (assq excluded tabulated-list-entries)))
      (save-window-excursion (termdex-list t))
      (with-current-buffer termdex-list-buffer-name
        (should (assq excluded tabulated-list-entries))
        ;; The refresh timer must not quietly revert to hiding it.
        (termdex--list-tick)
        (should (assq excluded tabulated-list-entries))))))


;;;; Switching

(termdex-tests--deftest termdex-last-goes-to-the-most-recent-terminal ()
  "From a non-terminal buffer, `termdex-last' lands in the MRU terminal.
Busy state is no obstacle: this is \"put me back where I was\", whatever
that terminal is doing."
  (termdex-tests--with-project root
    (let ((older (termdex-tests--terminal root))
          (recent (termdex-tests--terminal root)))
      (termdex-tests--type recent "sleep 60\n")
      (should (termdex-tests--busy recent))
      (switch-to-buffer older)
      (switch-to-buffer recent)
      (switch-to-buffer (get-buffer-create "*termdex-test-elsewhere*"))
      (should (eq (window-buffer) (get-buffer "*termdex-test-elsewhere*")))
      (termdex-last)
      (should (eq (window-buffer) recent)))))

(termdex-tests--deftest termdex-last-toggles-between-two-terminals ()
  "From inside a terminal, `termdex-last' goes to the most recent other
one, so repeating it flips between the two most recent terminals."
  (termdex-tests--with-project root
    (let ((first (termdex-tests--terminal root))
          (second (termdex-tests--terminal root)))
      (switch-to-buffer second)
      (termdex-last)
      (should (eq (window-buffer) first))
      (termdex-last)
      (should (eq (window-buffer) second))
      (termdex-last)
      (should (eq (window-buffer) first)))))

(termdex-tests--deftest termdex-last-skips-an-excluded-terminal ()
  "An excluded terminal is never the answer, however recently it was used."
  (termdex-tests--with-project root
    (let ((wanted (termdex-tests--terminal root))
          (excluded (termdex-tests--terminal root)))
      (with-current-buffer excluded (setq-local termdex-exclude t))
      (switch-to-buffer excluded)
      (switch-to-buffer (get-buffer-create "*termdex-test-elsewhere*"))
      (termdex-last)
      (should (eq (window-buffer) wanted)))))

(termdex-tests--deftest termdex-last-falls-back-to-termdex-here ()
  "With nothing to jump to, `termdex-last' behaves as `termdex-here':
you asked for a terminal, so you get one, in the directory you are in."
  (termdex-tests--with-project root
    (let ((created nil))
      (with-temp-buffer
        (setq default-directory root)
        (setq created (save-window-excursion (termdex-last))))
      (should (termdex--terminal-buffer-p created))
      (should (termdex-tests--directory-is created root)))))

(defvar termdex-tests--offered nil
  "Candidates and default from the last stubbed `completing-read'.")

(defmacro termdex-tests--with-stubbed-read (&rest body)
  "Run BODY with `completing-read' answering with its own default.
The completion UI is not what is under test here; which candidate is put
in front of you is."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'completing-read)
              (lambda (_prompt collection &optional _p _r _i _h default &rest _)
                (setq termdex-tests--offered
                      (list :candidates (all-completions "" collection)
                            :default default))
                default)))
     ,@body))

(termdex-tests--deftest termdex-switch-offers-the-most-recent-other-terminal ()
  "The default is the terminal you would most likely want, and you are not
offered the one you are already in."
  (termdex-tests--with-project root
    (let ((first (termdex-tests--terminal root))
          (second (termdex-tests--terminal root)))
      (switch-to-buffer second)
      (termdex-tests--with-stubbed-read
        (save-window-excursion (termdex-switch)))
      (should (equal (plist-get termdex-tests--offered :default) (buffer-name first)))
      (should-not (member (buffer-name second)
                          (plist-get termdex-tests--offered :candidates))))))

(termdex-tests--deftest termdex-switch-toggles-between-two-terminals ()
  "Repeated `RET' goes back and forth, as \\[switch-to-buffer] does."
  (termdex-tests--with-project root
    (let ((first (termdex-tests--terminal root))
          (second (termdex-tests--terminal root)))
      (switch-to-buffer second)
      ;; No `save-window-excursion' here: restoring the window configuration
      ;; would undo the very switch being asserted on, and with it the
      ;; most-recently-used order the toggle is made of.
      (termdex-tests--with-stubbed-read
        (should (eq (termdex-switch) first))
        (should (eq (termdex-switch) second))
        (should (eq (termdex-switch) first))))))

(termdex-tests--deftest termdex-switch-project-restricts-to-the-project ()
  "A terminal outside the project is not offered."
  (termdex-tests--with-project root
    (termdex-tests--with-project elsewhere
      (let ((inside (termdex-tests--terminal root))
            (outside (termdex-tests--terminal elsewhere)))
        (with-temp-buffer
          (setq default-directory root)
          (termdex-tests--with-stubbed-read
            (save-window-excursion (termdex-switch-project))))
        (let ((candidates (plist-get termdex-tests--offered :candidates)))
          (should (member (buffer-name inside) candidates))
          (should-not (member (buffer-name outside) candidates)))))))


;;;; Dashboard

(termdex-tests--deftest termdex-list-shows-every-terminal-and-its-state ()
  "The dashboard lists terminals with their directory and what they run."
  (termdex-tests--with-project root
    (let ((idle (termdex-tests--terminal root))
          (busy (termdex-tests--terminal root)))
      (termdex-tests--type busy "sleep 60\n")
      (should (termdex-tests--busy busy))
      (save-window-excursion (termdex-list))
      (with-current-buffer termdex-list-buffer-name
        (let ((rows tabulated-list-entries))
          (should (assq idle rows))
          (should (assq busy rows))
          (should (equal (aref (cadr (assq busy rows)) 1) "busy"))
          (should (equal (aref (cadr (assq busy rows)) 2) "sleep"))
          (should (equal (aref (cadr (assq idle rows)) 1) "idle")))))))

(defun termdex-tests--list-cell (buffer column)
  "Return the dashboard cell for BUFFER's terminal in COLUMN.
Rebuilds the entries rather than reading the printed buffer: the cells
are what the mode prints, and one of them carries a text property the
printed line would not let us at."
  (with-current-buffer termdex-list-buffer-name
    (termdex-list-refresh)
    (aref (cadr (assq buffer tabulated-list-entries)) column)))

(termdex-tests--deftest termdex-list-shows-how-long-a-terminal-has-been-quiet ()
  "The Quiet column counts from the last sweep, and names protections.
Before any sweep there is no clock to report, which is the state every
terminal is in after a reload -- the column says so rather than showing
a zero it cannot stand behind."
  (termdex-tests--with-project root
    (let ((idle (termdex-tests--terminal root))
          (busy (termdex-tests--terminal root)))
      (termdex-tests--type busy "sleep 60\n")
      (should (equal (termdex-tests--busy busy "sleep") "sleep"))
      (should (termdex-tests--quiet idle))
      ;; A threshold no test can reach: this is about what is displayed,
      ;; and nothing here should be closed while it is being read.
      (termdex-tests--with-cleanup 1800
        (save-window-excursion (termdex-list))
        (should (equal (termdex-tests--list-cell
                        idle termdex--list-quiet-column)
                       "-"))
        (termdex-cleanup-now)
        (let ((cell (termdex-tests--list-cell idle termdex--list-quiet-column)))
          (should (string-match-p "\\`[0-9]+m [0-9][0-9]s\\'" cell))
          ;; The seconds ride along for the sort, which the printed text
          ;; would get wrong at "9m" against "10m".
          (should (numberp (get-text-property 0 'termdex-quiet cell))))
        (should (equal (termdex-tests--list-cell
                        busy termdex--list-quiet-column)
                       "busy"))))))

(termdex-tests--deftest termdex-list-does-not-start-a-terminals-clock ()
  "Looking at the dashboard must not stamp a terminal.
The dashboard re-probes twice a second while it is displayed; if that
counted as a sweep, leaving it open would decide when terminals die."
  (termdex-tests--with-project root
    (let ((buffer (termdex-tests--terminal root)))
      (termdex-tests--with-cleanup 1800
        (should-not (buffer-local-value 'termdex--cleanup-activity buffer))
        (save-window-excursion (termdex-list))
        (termdex-tests--list-cell buffer termdex--list-quiet-column)
        (should-not (buffer-local-value 'termdex--cleanup-activity buffer))))))

(ert-deftest termdex-list-sorts-the-quiet-column-by-time ()
  "The Quiet column sorts on seconds, not on the text of the cell.
Needs no terminal: this is about two entries and a predicate."
  (let ((old (list "x" (vector "" "" "" (propertize "9m 00s" 'termdex-quiet 540) "")))
        (new (list "y" (vector "" "" "" (propertize "10m 00s" 'termdex-quiet 600) "")))
        (none (list "z" (vector "" "" "" "busy" ""))))
    (should (termdex--list-quiet-lessp old new))
    (should-not (termdex--list-quiet-lessp new old))
    (should (termdex--list-quiet-lessp none old))))

(termdex-tests--deftest termdex-list-kills-a-terminal ()
  "`k' on an idle terminal kills it without asking."
  (termdex-tests--with-project root
    (let ((buffer (termdex-tests--terminal root)))
      (save-window-excursion (termdex-list))
      (with-current-buffer termdex-list-buffer-name
        (goto-char (point-min))
        (while (and (not (eq (tabulated-list-get-id) buffer)) (not (eobp)))
          (forward-line 1))
        (should (eq (tabulated-list-get-id) buffer))
        (termdex-list-kill))
      (should-not (buffer-live-p buffer)))))

(termdex-tests--deftest termdex-list-kills-a-nested-shell-without-asking ()
  "`k' on a terminal at a nested shell's prompt does not ask either.
Idle to termdex, so termdex does not confirm -- and ghostel's own query,
which thinks otherwise, must not get to."
  (termdex-tests--with-project root
    (let ((buffer (termdex-tests--terminal root)))
      (termdex-tests--type buffer "bash --norc\n")
      (should (termdex-tests--wait
               (lambda () (not (eql (termdex-terminal-shell (termdex--probe buffer))
                                    (termdex--leader-pid buffer))))))
      (should (termdex-tests--idle buffer))
      (save-window-excursion (termdex-list))
      (with-current-buffer termdex-list-buffer-name
        (goto-char (point-min))
        (while (and (not (eq (tabulated-list-get-id) buffer)) (not (eobp)))
          (forward-line 1))
        (should (eq (tabulated-list-get-id) buffer))
        (termdex-tests--never-asking
          (termdex-list-kill)))
      (should-not (buffer-live-p buffer)))))


;;;; Naming

(termdex-tests--deftest termdex-names-a-terminal-after-its-title ()
  "A terminal termdex made follows the title its shell reports.
The default bash setup puts the title escape in PS1, so it is re-sent at
every prompt and the name tracks a `cd' by itself."
  (termdex-tests--with-project root
    (let ((termdex-buffer-name-string "*term %s*")
          (buffer nil))
      (with-temp-buffer
        (setq default-directory root)
        (setq buffer (save-window-excursion (termdex-new))))
      (termdex-tests--type buffer "PS1='$ '; printf '\\033]0;chosen-title\\007'\n")
      (should (termdex-tests--wait
               (lambda () (equal (buffer-name buffer) "*term chosen-title*")))))))


;;;; Mode-line indicator
;;
;; Rendering goes through `format-mode-line' on `global-mode-string' itself,
;; starting from nil -- the state of a session where nothing else claimed it,
;; and the state that exposed a real bug: a list whose car is a symbol is the
;; conditional (SYMBOL THEN ELSE) to the renderer, and with no THEN it shows
;; `*invalid*'.  Rendering a hand-padded ("" construct) instead is how the
;; first version of these tests missed that.  Symbol indirection is still on
;; the path, which is what proves the construct symbol is marked risky, since
;; an unmarked one renders as nothing.  The suite runs in a real TTY frame,
;; so this is the display engine's own rendering.

(defmacro termdex-tests--with-indicator (&rest body)
  "Run BODY with `termdex-indicator-mode' on, over a fresh mode line.
`global-mode-string' is rebound to nil first, so BODY sees exactly what
a session where nothing else touched it would see."
  (declare (indent 0) (debug t))
  `(let ((global-mode-string nil))
     (unwind-protect
         (progn (termdex-indicator-mode 1) ,@body)
       (termdex-indicator-mode -1))))

(defun termdex-tests--indicator ()
  "Render `global-mode-string' the way a mode line would."
  (format-mode-line global-mode-string))

(defun termdex-tests--expected (count)
  "The indicator string for COUNT terminals, under the glyph in force.
Derived from `termdex-indicator-glyph' rather than hardcoded, so the
tests assert the shape of the indicator, not one default's spelling."
  (format " %s %d" termdex-indicator-glyph count))

(ert-deftest termdex-indicator-mode-installs-exactly-one-construct ()
  "The mode adds its element once, never first, and removes it again.
Never first because the renderer reads a symbol-headed list as a
conditional construct, which renders as *invalid* -- the element must
sit behind something that keeps the list's car a string.  Needs no
terminal: this is about `global-mode-string' surgery."
  (termdex-tests--with-indicator
    (should (memq 'termdex--indicator-construct global-mode-string))
    (should (equal (car global-mode-string) ""))
    (termdex-indicator-mode 1)
    (should (= 1 (seq-count (lambda (element)
                              (eq element 'termdex--indicator-construct))
                            global-mode-string)))
    (termdex-indicator-mode -1)
    (should-not (memq 'termdex--indicator-construct global-mode-string))))

(termdex-tests--deftest termdex-indicator-counts-terminals ()
  "The indicator shows the count, follows a kill, and hides at zero."
  (termdex-tests--with-project root
    (termdex-tests--with-indicator
      (should (equal (termdex-tests--indicator) ""))
      (termdex-tests--terminal root)
      (let ((second (termdex-tests--terminal root)))
        (should (equal (termdex-tests--indicator) (termdex-tests--expected 2)))
        (termdex--kill second))
      (should (equal (termdex-tests--indicator) (termdex-tests--expected 1))))))

(termdex-tests--deftest termdex-indicator-does-not-count-excluded-terminals ()
  "An excluded terminal is not in the count, matching what the commands see."
  (termdex-tests--with-project root
    (termdex-tests--with-indicator
      (termdex-tests--terminal root)
      (with-current-buffer (termdex-tests--terminal root)
        (setq-local termdex-exclude t))
      (should (equal (termdex-tests--indicator) (termdex-tests--expected 1))))))

(termdex-tests--deftest termdex-indicator-click-opens-the-dashboard ()
  "mouse-1 on the rendered indicator reaches `termdex-list'.
The binding is read back from the rendered string's `local-map', the
property a real click is dispatched through."
  (termdex-tests--with-project root
    (termdex-tests--with-indicator
      (termdex-tests--terminal root)
      (let* ((rendered (termdex-tests--indicator))
             (map (get-text-property (1- (length rendered)) 'local-map rendered))
             (binding (and map (lookup-key map (kbd "<mode-line> <mouse-1>")))))
        (should (eq binding #'termdex-list))
        (save-window-excursion
          (call-interactively binding)
          (should (derived-mode-p 'termdex-list-mode)))))))

;;;; Closing terminals that have gone quiet
;;
;; The sweep is driven directly rather than through its timer: no suite can
;; wait half an hour, and an idle timer in a run that is never idle would
;; never fire anyway.  What is turned down to a second or two is the
;; *threshold*, which is the only thing about the sweep that is slow.
;;
;; Every spared-terminal test runs its first sweep *after* the terminal has
;; finished making noise, so the second sweep sees an unmoved tick.  Otherwise
;; a terminal would be spared by its own output and the test would pass
;; without the protection it is named after ever being consulted.

(termdex-tests--deftest termdex-cleanup-closes-a-quiet-terminal ()
  "A terminal that has done nothing for long enough is closed.
The control for every test below: without this one passing, a spared
terminal proves nothing."
  (termdex-tests--with-project root
    (let ((buffer (termdex-tests--terminal root)))
      (should (termdex-tests--quiet buffer))
      (termdex-tests--with-cleanup 1
        (termdex-cleanup-now)
        (should (buffer-live-p buffer))
        (termdex-tests--pause 1.2)
        (termdex-cleanup-now)
        (should-not (buffer-live-p buffer))))))

(termdex-tests--deftest termdex-cleanup-restarts-the-clock-on-output ()
  "Output puts a terminal's idle period back to zero.
The wait after it speaks runs past the threshold on purpose: surviving
then is the clock having restarted, not the deadline not yet having
arrived."
  (termdex-tests--with-project root
    (let ((buffer (termdex-tests--terminal root)))
      (should (termdex-tests--quiet buffer))
      (termdex-tests--with-cleanup 1
        (let ((start (current-time)))
          (termdex-cleanup-now)
          (should (termdex-tests--spoke buffer "echo hello\n"))
          (while (time-less-p nil (time-add start 1.5))
            (accept-process-output nil 0.05))
          (termdex-cleanup-now)
          (should (buffer-live-p buffer)))))))

(termdex-tests--deftest termdex-cleanup-spares-the-terminals-it-must ()
  "Busy, backgrounded, displayed and excluded terminals survive a sweep.
All four in one sweep, next to a terminal with no protection at all:
the control dying is what shows the sweep ran and reached them."
  (termdex-tests--with-project root
    (let ((control (termdex-tests--terminal root))
          (busy (termdex-tests--terminal root))
          (background (termdex-tests--terminal root))
          (displayed (termdex-tests--terminal root))
          (excluded (termdex-tests--terminal root)))
      (termdex-tests--type busy "sleep 60\n")
      (should (equal (termdex-tests--busy busy "sleep") "sleep"))
      ;; A backgrounded job reads as idle -- there is still a prompt -- so
      ;; only the shell's children give it away.
      (termdex-tests--type background "sleep 60 &\n")
      (should (termdex-tests--wait
               (lambda ()
                 (termdex--children
                  (termdex-terminal-shell (termdex--probe background))))))
      (should (termdex-tests--idle background))
      (with-current-buffer excluded (setq-local termdex-exclude t))
      (save-window-excursion
        (should (display-buffer displayed))
        (should (get-buffer-window displayed t))
        (dolist (buffer (list control busy background displayed excluded))
          (should (termdex-tests--quiet buffer)))
        (termdex-tests--with-cleanup 1
          (termdex-cleanup-now)
          (termdex-tests--pause 1.2)
          (termdex-cleanup-now)))
      (should-not (buffer-live-p control))
      (should (buffer-live-p busy))
      (should (buffer-live-p background))
      (should (buffer-live-p displayed))
      (should (buffer-live-p excluded)))))

(termdex-tests--deftest termdex-cleanup-obeys-the-option-at-every-sweep ()
  "Nil closes nothing, and the option is read per sweep rather than cached.
The same terminal, already past its deadline, survives the sweep with
the option nil and is closed by the next one with it restored."
  (termdex-tests--with-project root
    (let ((buffer (termdex-tests--terminal root)))
      (should (termdex-tests--quiet buffer))
      (termdex-tests--with-cleanup 1
        (termdex-cleanup-now)
        (termdex-tests--pause 1.2)
        (setq termdex-cleanup-idle-seconds nil)
        (termdex-cleanup-now)
        (should (buffer-live-p buffer))
        (setq termdex-cleanup-idle-seconds 1)
        (termdex-cleanup-now)
        (should-not (buffer-live-p buffer))))))

(termdex-tests--deftest termdex-cleanup-sweeps-at-most-once-an-interval ()
  "The timer's entry point is rate limited; `termdex-cleanup-now' is not.
Without the limit the idle timer would sweep every few seconds while
you sat reading the screen."
  (termdex-tests--with-project root
    (let ((buffer (termdex-tests--terminal root)))
      (should (termdex-tests--quiet buffer))
      (termdex-tests--with-cleanup 1
        (termdex-cleanup-now)
        (termdex-tests--pause 1.2)
        (termdex--cleanup-maybe-sweep)
        (should (buffer-live-p buffer))
        (termdex-cleanup-now)
        (should-not (buffer-live-p buffer))))))

(defmacro termdex-tests--never-asking (&rest body)
  "Run BODY with any yes-or-no question signalling instead of waiting.
A question nobody answers would hang the run; this turns it into an
error, which the sweep demotes and so leaves the terminal alive."
  (declare (indent 0) (debug t))
  `(cl-letf (((symbol-function 'yes-or-no-p)
              (lambda (prompt) (error "Asked: %s" prompt)))
             ((symbol-function 'y-or-n-p)
              (lambda (prompt) (error "Asked: %s" prompt))))
     ,@body))

(termdex-tests--deftest termdex-cleanup-closes-a-nested-shell-without-asking ()
  "A terminal at a nested shell's prompt is closed without a question.
termdex calls it idle; ghostel's shell integration calls the nested
shell a running command and asks, from a buffer-local query, before
killing.  A kill that does not bind the query in the terminal's own
buffer asks it -- from a timer, in real use."
  (termdex-tests--with-project root
    (let ((buffer (termdex-tests--terminal root)))
      (termdex-tests--type buffer "bash --norc\n")
      (should (termdex-tests--wait
               (lambda () (not (eql (termdex-terminal-shell (termdex--probe buffer))
                                    (termdex--leader-pid buffer))))))
      (should (termdex-tests--idle buffer))
      (should (termdex-tests--quiet buffer))
      (termdex-tests--with-cleanup 1
        (termdex-tests--never-asking
          (termdex-cleanup-now)
          (termdex-tests--pause 1.2)
          (termdex-cleanup-now)))
      (should-not (buffer-live-p buffer)))))

(ert-deftest termdex-cleanup-mode-owns-exactly-one-timer ()
  "The mode installs one idle timer, never two, and removes it again.
Needs no terminal: this is about the timer list."
  (let ((was termdex-cleanup-mode))
    (unwind-protect
        (progn
          (termdex-cleanup-mode 1)
          (should (memq termdex--cleanup-timer timer-idle-list))
          (termdex-cleanup-mode 1)
          (should (= 1 (seq-count
                        (lambda (timer)
                          (eq (timer--function timer)
                              #'termdex--cleanup-maybe-sweep))
                        timer-idle-list)))
          (termdex-cleanup-mode -1)
          (should-not termdex--cleanup-timer)
          (should-not (seq-some
                       (lambda (timer)
                         (eq (timer--function timer)
                             #'termdex--cleanup-maybe-sweep))
                       timer-idle-list)))
      (termdex-cleanup-mode (if was 1 -1)))))


;;;; Backends

(ert-deftest termdex-backend-auto-prefers-ghostel ()
  "`auto' is ghostel when installed, vterm otherwise, and an error with neither.
The one place that stubs: what is installed is the input, and \"neither\"
cannot be arranged for real in a test environment that has both."
  (let ((termdex-backend 'auto))
    (cl-flet ((with-installed (libraries)
                (cl-letf (((symbol-function 'locate-library)
                           (lambda (library &rest _)
                             (and (member library libraries) library))))
                  (condition-case nil (termdex--backend)
                    (user-error 'error)))))
      (should (eq (with-installed '("ghostel" "vterm")) 'ghostel))
      (should (eq (with-installed '("ghostel")) 'ghostel))
      (should (eq (with-installed '("vterm")) 'vterm))
      (should (eq (with-installed '()) 'error))))
  (let ((termdex-backend 'vterm))
    (should (eq (termdex--backend) 'vterm))))

(ert-deftest termdex-indexes-both-kinds-whatever-the-backend ()
  "A vterm and a ghostel are both terminals, under either setting.
The option says what termdex makes; switching it must not orphan the
terminals already open."
  (skip-unless (and (memq 'vterm termdex-tests--backends)
                    (memq 'ghostel termdex-tests--backends)))
  (termdex-tests--with-terminals
    (termdex-tests--with-project root
      (let ((vterm (termdex-tests--terminal root 'vterm))
            (ghostel (termdex-tests--terminal root 'ghostel)))
        (dolist (termdex-backend '(vterm ghostel auto))
          (let ((buffers (mapcar #'termdex-terminal-buffer (termdex-terminals))))
            (should (memq vterm buffers))
            (should (memq ghostel buffers))))))))

(ert-deftest termdex-a-ghostel-running-a-program-is-not-a-terminal ()
  "`ghostel-exec' shares the mode, but runs a program, not a shell.
Indexed, a quiet one would read as an idle prompt and be closed."
  (skip-unless (memq 'ghostel termdex-tests--backends))
  (termdex-tests--with-terminals
    (let ((buffer (generate-new-buffer "*termdex-test-exec*")))
      (ghostel-exec buffer "sleep" '("60"))
      (should (termdex-tests--wait
               (lambda () (process-live-p (buffer-local-value 'ghostel--process buffer)))))
      (should-not (termdex--terminal-buffer-p buffer)))))

;;; termdex-tests.el ends here
