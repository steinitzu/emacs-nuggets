;;; termdex-tests.el --- Tests for termdex -*- lexical-binding: t; -*-

;;; Commentary:

;; Driven against real vterms running real shells: a terminal is started, text
;; is typed into it, and the assertions are about what /proc then says.  There
;; is nothing to usefully mock here -- the whole package is a claim about what
;; a process tree looks like, and only a real one can refute it.
;;
;; The suite skips itself when vterm is not installed (`make deps' builds it),
;; so the rest of the collection's tests still run.
;;
;; Nothing waits a fixed number of seconds.  A shell takes as long as it takes
;; to reach its prompt, and a fixed wait is a test that fails on a loaded
;; machine; every wait here polls for the condition it actually needs.

;;; Code:

(require 'ert)
(require 'termdex)

(defconst termdex-tests--available (require 'vterm nil t)
  "Whether vterm could be loaded at all.")

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

(defun termdex-tests--settle (buffer)
  "Give BUFFER's shell a chance to act on anything sent to it.

For asserting that something did *not* happen.  Waiting out the full
timeout to prove a negative would make the suite mostly sleep, so this
waits a shell round trip instead -- long enough that the same wait is
comfortably sufficient when the thing is supposed to happen, which the
positive tests demonstrate it is."
  (let ((deadline (time-add nil 2)))
    (while (time-less-p nil deadline)
      (accept-process-output (buffer-local-value 'vterm--process buffer) 0.05))))

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
  (with-current-buffer buffer (vterm-send-string string)))

(defun termdex-tests--terminal (directory)
  "Start a terminal in DIRECTORY and wait for its shell to settle there."
  (let* ((default-directory (file-name-as-directory directory))
         (buffer (save-window-excursion
                   (vterm (generate-new-buffer-name "*termdex-test*")))))
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
hang a batch run, so the query functions are suppressed."
  (declare (indent 0) (debug t))
  `(let ((before (buffer-list)))
     (unwind-protect (progn ,@body)
       (termdex--list-stop-timer)
       (dolist (buffer (buffer-list))
         (unless (memq buffer before)
           (when (buffer-live-p buffer)
             (let ((kill-buffer-query-functions nil))
               (kill-buffer buffer))))))))

(defmacro termdex-tests--deftest (name &rest body)
  "Define test NAME, skipped when vterm is unavailable."
  (declare (indent 1) (debug (symbolp body)))
  `(ert-deftest ,name ()
     (skip-unless termdex-tests--available)
     (termdex-tests--with-terminals ,@body)))


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
                           (termdex--current-shell
                            (process-id (buffer-local-value 'vterm--process buffer)))))))
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
  (skip-unless termdex-tests--available)
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
      (should (termdex--vterm-buffer-p excluded))
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
      (with-current-buffer buffer
        (vterm-send-string "PS1='$ '; printf '\\033]0;chosen-title\\007'\n"))
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
        (let ((kill-buffer-query-functions nil))
          (kill-buffer second)))
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

;;; termdex-tests.el ends here
