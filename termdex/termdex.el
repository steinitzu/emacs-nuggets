;;; termdex.el --- Directory-aware handling for many vterms -*- lexical-binding: t; -*-

;; Author: Steinthor Palsson
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: terminals, convenience

;;; Commentary:

;; An index of every live terminal, and commands that reach one by directory.
;;
;; A terminal belongs to wherever it is *now*: `cd' somewhere else and it is a
;; terminal of that directory.  That is the whole idea, and it is why the
;; commands here do not tie a terminal to the project it was born in.
;;
;;   `termdex-here'          reach a terminal for this directory, or make one
;;   `termdex-here-idle'     the same, but never land in a busy terminal
;;   `termdex-project-root'  reach a terminal at this project's root
;;   `termdex-project-root-idle'  ... that is not busy
;;   `termdex-new'           always a new terminal
;;   `termdex-last'          back to the last terminal you were in
;;   `termdex-switch'        completing-read over every terminal
;;   `termdex-switch-project'  ... restricted to this project
;;   `termdex-list'          a dashboard of all of them
;;   `termdex-indicator-mode'  a terminal count in the mode line
;;
;; Three facts about a terminal make all of that work: where it is, whether it
;; is busy, and what it is running.  All three come from /proc, asked of the
;; terminal's *current shell* rather than of the process vterm started -- a
;; `sudo -i' or a plain `bash' inside a terminal is a different process, whose
;; directory the outer shell does not follow.  See DESIGN.md; the rules there
;; were validated against real terminals before any of this was written.
;;
;; vterm's own shell-side integration (`vterm_prompt_end' in a shell rc) is
;; used where it is strictly better -- a shell across an ssh, whose directory
;; is not a local path at all -- and ignored otherwise, since it says nothing
;; about busy state and is not loaded inside a nested shell.
;;
;; Usage:
;;
;;   (require 'termdex)
;;   (keymap-global-set "C-c t" #'termdex-here)

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'project)
(require 'tabulated-list)

(declare-function vterm "vterm" (&optional arg))
(declare-function vterm-send-string "vterm" (string &optional paste-p))
(defvar vterm--process)
(defvar vterm-buffer-name-string)

(defgroup termdex nil
  "Directory-aware handling for many vterms."
  :group 'terminals
  :prefix "termdex-")

(defcustom termdex-cd-on-ancestor-match t
  "Whether to follow you down when reusing a terminal from a parent directory.

When `termdex-here' reuses a terminal whose directory is an ancestor of
the one you are in, it sends a `cd' so the terminal comes with you.  With
this nil the terminal is reused where it stands.

Never applies to a busy terminal: there is no prompt to read the `cd',
and the text would go to whatever is running.  See
`termdex-cd-on-ancestor-match' handling in `termdex--reuse'."
  :type 'boolean)

(defcustom termdex-shell-names
  '("bash" "zsh" "sh" "dash" "fish" "ksh" "ksh93" "mksh" "tcsh" "csh")
  "Process names that count as a shell when looking for a terminal's cwd.

A foreground process on this list is descended into, so a shell started
inside a terminal becomes the terminal's current shell.  Anything else
is not, which is what stops `make' spawning a compiler from being
mistaken for one."
  :type '(repeat string))

(defcustom termdex-buffer-name-string "*term %s*"
  "Format for naming terminals that termdex creates, or nil.

Set buffer-locally as `vterm-buffer-name-string', so a terminal is named
after the title its shell reports and follows it as it changes.  Nil
leaves vterm's naming alone.

Terminals started any other way are never renamed."
  :type '(choice (const :tag "Leave vterm's naming alone" nil)
                 (string :tag "Format string")))

(defvar-local termdex-exclude nil
  "Non-nil to keep this terminal out of termdex's commands.

Set buffer-locally, by whatever created the terminal.  A terminal
someone else drives -- an agent session, a build console, a REPL that
lives in a window of its own -- is a terminal you want to reach the way
its owner intends, not by walking into it looking for a shell prompt.

Excluded terminals are still terminals: one is left out of matching and
switching, but its own directory is still read from it, so a command run
from inside it starts from the right place.")

(defcustom termdex-exclude-functions nil
  "Predicates deciding which terminals termdex leaves alone.

Each is called with a buffer and may return non-nil to exclude it, as an
alternative to `termdex-exclude' for terminals you do not create
yourself.  For instance, to leave a coding agent's session terminals
alone:

  (add-to-list \\='termdex-exclude-functions
               (lambda (buffer)
                 (buffer-local-value \\='my-agent-session-p buffer)))"
  :type '(repeat function))

(defcustom termdex-list-refresh-seconds 2
  "How often the `termdex-list' dashboard re-probes, in seconds.

The timer only does work while the dashboard is displayed in some
window, so a dashboard left buried costs nothing."
  :type 'number)

(defconst termdex--walk-limit 32
  "How deep to descend a terminal's process tree before giving up.
A cap rather than a real limit: nothing legitimate nests this far, and
redisplay must not be held up by a pathological tree.")


;;;; Reading /proc
;;
;; Everything below answers a question about *one* pid.  The interesting part
;; -- which pid to ask -- is `termdex--current-shell', further down.

(defun termdex--proc-contents (pid file)
  "Return the contents of /proc/PID/FILE, or nil if it cannot be read.
A terminal can exit between listing it and probing it, so an unreadable
file is an ordinary outcome rather than an error."
  (let ((path (format "/proc/%d/%s" pid file)))
    (ignore-errors
      (with-temp-buffer
        (insert-file-contents-literally path)
        (buffer-string)))))

(defun termdex--stat (pid)
  "Return (PGRP . TPGID) for PID, or nil.

The fields are read from after the last `)' in /proc/PID/stat: a process
name can contain spaces and parentheses, so splitting the whole line on
whitespace would shift every field after it.  Past that point, `pgrp' is
the third field and `tpgid' the sixth."
  (when-let* ((stat (termdex--proc-contents pid "stat"))
              (close (cl-position ?\) stat :from-end t))
              (fields (split-string (substring stat (+ close 2)) nil t))
              ((> (length fields) 5)))
    (cons (string-to-number (nth 2 fields))
          (string-to-number (nth 5 fields)))))

(defun termdex--pgrp (pid)
  "Return PID's process group, or nil."
  (car (termdex--stat pid)))

(defun termdex--tpgid (pid)
  "Return the process group that owns PID's terminal, or nil."
  (cdr (termdex--stat pid)))

(defun termdex--comm (pid)
  "Return PID's command name, or nil."
  (when-let* ((comm (termdex--proc-contents pid "comm")))
    (string-trim comm)))

(defun termdex--cmdline (pid)
  "Return PID's command line as a list of arguments, or nil."
  (when-let* ((raw (termdex--proc-contents pid "cmdline")))
    (split-string raw "\0" t)))

(defun termdex--children (pid)
  "Return PID's immediate children, as a list of pids."
  (when-let* ((children (termdex--proc-contents
                         pid (format "task/%d/children" pid))))
    (mapcar #'string-to-number (split-string children nil t))))

(defun termdex--cwd (pid)
  "Return PID's working directory as a directory name, or nil.

Read as a symlink rather than followed, so a deleted directory -- which
the kernel reports as \"/path (deleted)\" -- is rejected instead of
resolving to something else."
  (when-let* ((target (file-symlink-p (format "/proc/%d/cwd" pid)))
              ((not (string-suffix-p " (deleted)" target))))
    (file-name-as-directory target)))


;;;; Which process to ask
;;
;; The pid vterm started is the pty leader, and it is not necessarily the shell
;; you are typing at.  Run `sudo -i', `ssh', or plain `bash' and the leader's
;; cwd freezes where it stood while its `tpgid' reads permanently busy -- both
;; facts wrong, and "permanently busy" would make `termdex-here-idle' spawn a
;; terminal every time.

(defun termdex--foreground-path (leader)
  "Return the pids from LEADER down to the group owning its terminal.

Descends only towards that group, so a background job's subtree is never
entered -- a shell suspended in the background is not the shell you are
typing at.  Falls back to just LEADER when the group cannot be found,
which is what happens if the terminal exits mid-walk."
  (let ((tpgid (termdex--tpgid leader)))
    (or (when tpgid
          (letrec ((walk
                    (lambda (pid depth)
                      (cond
                       ((>= depth termdex--walk-limit) nil)
                       ((eql (termdex--pgrp pid) tpgid) (list pid))
                       (t (seq-some
                           (lambda (child)
                             (when-let* ((tail (funcall walk child (1+ depth))))
                               (cons pid tail)))
                           (termdex--children pid)))))))
            (funcall walk leader 0)))
        (list leader))))

(defconst termdex--command-option-regexp "\\`-[a-zA-Z]*c"
  "Regexp matching a shell's -c option, bundled with other short options or not.
`--norc' and friends do not match: the character after the leading dash
must begin a run of short options.")

(defun termdex--interactive-shell-p (pid)
  "Non-nil when PID is a shell someone could be typing at.

Being named `bash' is not enough.  A shell script's process is also
called `bash' -- that is what a `#!' line runs -- and so is `bash -c'.
Descending into one of those would report the terminal as sitting idle
at a prompt for as long as the script ran, which is exactly backwards.

The test is the command line: an interactive shell is invoked with
options only, while running a script or a command string means an
argument that is not an option, or `-c'."
  (and (member (termdex--comm pid) termdex-shell-names)
       (let ((args (cdr (termdex--cmdline pid))))
         (and (seq-every-p (lambda (arg) (string-prefix-p "-" arg)) args)
              (not (seq-some (lambda (arg)
                               (string-match-p termdex--command-option-regexp arg))
                             args))))))

(defun termdex--current-shell (leader)
  "Return the pid of the shell you are typing at in LEADER's terminal.

The deepest shell between LEADER and the foreground process group.  With
a `sleep' running inside a nested `bash', the path is
leader -> bash -> sleep and the answer is the bash: `sleep' is not a
shell, and the nested bash is deeper than the leader.  With `make'
running in the leader the path stops at `make', so the answer is the
leader -- a compiler `make' spawns is inside the foreground group and is
never even looked at."
  (or (car (last (seq-filter #'termdex--interactive-shell-p
                             (termdex--foreground-path leader))))
      leader))

(defun termdex--foreground-commands (leader shell)
  "Return the names of what SHELL is running in LEADER's terminal.
Nil when the shell is at its prompt.  A pipeline puts several processes
in the foreground group, and all of them are named."
  (when-let* ((tpgid (termdex--tpgid leader)))
    (unless (eql (termdex--pgrp shell) tpgid)
      (seq-filter #'identity
                  (mapcar (lambda (pid)
                            (when (eql (termdex--pgrp pid) tpgid)
                              (termdex--comm pid)))
                          (termdex--children shell))))))


;;;; Terminals

(cl-defstruct (termdex-terminal (:constructor termdex--terminal)
                                (:copier nil))
  "A live terminal, as it was at the moment it was probed.
Records go stale the instant they are made -- a terminal can `cd' or
finish a job -- so they are built on demand and thrown away, never
cached."
  buffer
  (directory nil :documentation "Where the terminal is now, or nil if unknown.")
  (busy nil :documentation "Non-nil when something is running; `unknown' when unknowable.")
  (command nil :documentation "What is running, as a string, or nil.")
  (remote nil :documentation "Non-nil when the terminal's shell is not local."))

(defun termdex--vterm-buffer-p (buffer)
  "Non-nil when BUFFER is a vterm with a live process."
  (with-current-buffer buffer
    (and (derived-mode-p 'vterm-mode)
         (boundp 'vterm--process)
         (process-live-p vterm--process))))

(defun termdex--probe (buffer)
  "Return a `termdex-terminal' describing BUFFER.

A remote terminal is described by `default-directory', which vterm's
shell-side integration keeps up to date and which is the only source
that can see across an ssh at all; its busy state is unknowable and is
reported as such.  A local one is probed through /proc, which needs no
cooperation from the shell."
  (with-current-buffer buffer
    (if (file-remote-p default-directory)
        (termdex--terminal :buffer buffer
                           :directory default-directory
                           :busy 'unknown
                           :remote t)
      (let* ((leader (process-id vterm--process))
             (shell (termdex--current-shell leader))
             (commands (termdex--foreground-commands leader shell)))
        (termdex--terminal
         :buffer buffer
         :directory (termdex--cwd shell)
         :busy (and commands t)
         :command (when commands (string-join commands "|")))))))

(defun termdex--excluded-p (buffer)
  "Non-nil when BUFFER is a terminal termdex should leave alone.
See `termdex-exclude' and `termdex-exclude-functions'."
  (or (buffer-local-value 'termdex-exclude buffer)
      (seq-some (lambda (predicate) (funcall predicate buffer))
                termdex-exclude-functions)))

(defun termdex--candidate-p (buffer)
  "Non-nil when BUFFER is a terminal termdex may send you to.

Deliberately not the same question as `termdex--vterm-buffer-p'.  That
one asks whether a buffer is a terminal at all, and an excluded terminal
still is one: its directory is read from it like any other, so running a
command from inside one starts where it actually is rather than falling
back to a `default-directory' that never moved."
  (and (termdex--vterm-buffer-p buffer)
       (not (termdex--excluded-p buffer))))

(defun termdex-terminals (&optional include-excluded)
  "Return every live terminal, most recently used first.

Terminals excluded by `termdex-exclude' or `termdex-exclude-functions'
are left out unless INCLUDE-EXCLUDED is non-nil.

The order is `buffer-list''s, which Emacs already maintains as
most-recently-used.  Nothing here is cached: this is the whole of
termdex's state, and it is rebuilt every time it is asked for."
  (mapcar #'termdex--probe
          (seq-filter (if include-excluded
                          #'termdex--vterm-buffer-p
                        #'termdex--candidate-p)
                      (buffer-list))))

(defun termdex-terminal-name (terminal)
  "Return the buffer name of TERMINAL."
  (buffer-name (termdex-terminal-buffer terminal)))


;;;; Directories and matching

(defun termdex--canonical (directory)
  "Return DIRECTORY in the form terminal directories are compared in.

The kernel reports an already-resolved path in /proc, while a buffer's
`default-directory' may have reached the same place through a symlink.
Both sides are resolved so the two can be compared at all."
  (when directory
    (file-name-as-directory (file-truename directory))))

(defun termdex-current-directory ()
  "Return the directory the current buffer is in, canonically.

In a terminal that means the directory its shell is in, which is not
`default-directory': without vterm's shell-side integration that never
moves, and even with it, it does not follow a `cd' typed into a nested
shell that never loaded the snippet."
  (termdex--canonical
   (if (termdex--vterm-buffer-p (current-buffer))
       (or (termdex-terminal-directory (termdex--probe (current-buffer)))
           default-directory)
     default-directory)))

(defun termdex--project-root (directory)
  "Return DIRECTORY's project root, canonically, or nil.

Nil disables ancestor matching, which is the point: with no root there
is nothing to stop a terminal sitting in your home directory from
matching every directory under it."
  (when directory
    (when-let* ((project (let ((default-directory directory))
                           (project-current nil directory))))
      (termdex--canonical (project-root project)))))

(defun termdex--match (directory &optional require-idle)
  "Return the best terminal for DIRECTORY, or nil.

A terminal matches when its directory is DIRECTORY itself or an ancestor
of it, no higher than the project root.  The best match is the deepest,
and among equally deep ones the most recently used.

Both rules fall out of one comparison.  A terminal's directory is a
prefix of DIRECTORY exactly when it is DIRECTORY or an ancestor, and the
longest such prefix is DIRECTORY itself -- so sorting by length puts an
exact match first without needing a case of its own.  The sort is
stable, so most-recently-used order survives it.

With REQUIRE-IDLE, a busy terminal is not a match.  Neither is a remote
one, whose busy state cannot be established."
  (let* ((root (termdex--project-root directory))
         ;; With no project, a terminal must be *at* DIRECTORY: this bound
         ;; admits only prefixes of DIRECTORY that DIRECTORY is a prefix of.
         (limit (or root directory))
         (candidates
          (seq-filter
           (lambda (terminal)
             (let ((dir (termdex-terminal-directory terminal)))
               (and dir
                    (string-prefix-p dir directory)
                    (string-prefix-p limit dir)
                    (not (and require-idle (termdex-terminal-busy terminal))))))
           (termdex-terminals))))
    (car (seq-sort-by (lambda (terminal)
                        (length (termdex-terminal-directory terminal)))
                      #'> candidates))))


;;;; Reaching a terminal

(defun termdex--display (buffer)
  "Show BUFFER and select it, wherever it already is.
A terminal in another frame is reached by going to that frame rather
than by opening a second window on it."
  (when-let* ((window (display-buffer
                       buffer
                       '((display-buffer-reuse-window display-buffer-same-window)
                         (reusable-frames . t)))))
    (select-frame-set-input-focus (window-frame window))
    (select-window window))
  buffer)

(defun termdex--send-cd (terminal directory)
  "Send DIRECTORY as a `cd' to TERMINAL, if that is safe and wanted.

Refused for a busy terminal even when `termdex-cd-on-ancestor-match' is
on.  A busy terminal has no prompt to read the line; it would arrive as
input to whatever is running, which might be a REPL, a pager, or a
confirmation prompt.  Returns non-nil when something was sent.

The line lands in shell history.  Suppressing that depends on
shell-specific settings, so it is accepted rather than worked around."
  (when (and termdex-cd-on-ancestor-match
             (not (termdex-terminal-busy terminal))
             (not (equal (termdex-terminal-directory terminal) directory)))
    (with-current-buffer (termdex-terminal-buffer terminal)
      (vterm-send-string
       (format "cd %s\n" (shell-quote-argument (directory-file-name directory)))))
    t))

(defun termdex--create (directory)
  "Return a new terminal in DIRECTORY, displayed and selected."
  (require 'vterm)
  (let* ((default-directory (file-name-as-directory directory))
         (buffer (save-window-excursion
                   (vterm (format "*term %s*"
                                  (file-name-nondirectory
                                   (directory-file-name directory)))))))
    (when termdex-buffer-name-string
      (with-current-buffer buffer
        ;; Buffer-local: a terminal termdex made is named after its title,
        ;; without changing how terminals started any other way are named.
        (setq-local vterm-buffer-name-string termdex-buffer-name-string)))
    (termdex--display buffer)))

(defun termdex--reach (require-idle &optional at-project-root)
  "Reach a terminal for the current directory, or make one.
REQUIRE-IDLE excludes busy terminals from the search.

AT-PROJECT-ROOT makes the target the current directory's project root
rather than the directory itself; with no project it changes nothing.
A terminal already at the root is then an exact match -- no `cd' is
sent -- and one below the root is no match at all."
  (let* ((directory (termdex-current-directory))
         (directory (or (and at-project-root (termdex--project-root directory))
                        directory))
         (terminal (termdex--match directory require-idle)))
    (if terminal
        (progn (termdex--send-cd terminal directory)
               (termdex--display (termdex-terminal-buffer terminal)))
      (termdex--create directory))))

;;;###autoload
(defun termdex-here ()
  "Go to a terminal for this directory, making one if there is none.

Reuses a terminal already in this directory, or the nearest one in a
parent directory up to the project root, most recently used first.  A
busy terminal is still a match -- this is \"take me to the terminal for
here\", whatever it happens to be doing.  Use `termdex-here-idle' when
you want a prompt to type at.

When the match came from a parent directory and is idle, it is sent a
`cd' so it follows you down; see `termdex-cd-on-ancestor-match'."
  (interactive)
  (termdex--reach nil))

;;;###autoload
(defun termdex-here-idle ()
  "Go to an idle terminal for this directory, making one if there is none.
As `termdex-here', except that a terminal with something running in it
does not count as a match, so you always arrive at a prompt."
  (interactive)
  (termdex--reach t))

;;;###autoload
(defun termdex-project-root ()
  "Go to a terminal at this project's root, making one if there is none.

As `termdex-here', except the directory looked for is the project root
of where you are, not the directory itself -- \"take me to the terminal
of this project\".  A terminal that has since moved *below* the root is
not a match; you arrive at the root or in a fresh terminal there.

Outside a project there is no root, so this is exactly `termdex-here'."
  (interactive)
  (termdex--reach nil t))

;;;###autoload
(defun termdex-project-root-idle ()
  "Go to an idle terminal at this project's root, making one if needed.
As `termdex-project-root', except that a terminal with something running
in it does not count as a match, so you always arrive at a prompt."
  (interactive)
  (termdex--reach t t))

;;;###autoload
(defun termdex-new ()
  "Make a new terminal in this directory, without looking for one."
  (interactive)
  (termdex--create (termdex-current-directory)))


;;;; Switching

;;;###autoload
(defun termdex-last ()
  "Go to the last terminal you were in, unconditionally.

No directory matching, no prompt, no regard for busy state: the most
recently used terminal, wherever it is and whatever it is doing.  From
inside a terminal, the most recent *other* one, so invoking this twice
toggles between your two most recent terminals.

Terminals excluded by `termdex-exclude' or `termdex-exclude-functions'
are never the answer, as everywhere else.  With no terminal to go to
at all, this falls back to `termdex-here': a keystroke meaning \"take
me to a terminal\" should produce one, and with nothing to jump back
to, the terminal for where you are is the most useful answer."
  (interactive)
  (let ((buffer (seq-find (lambda (buffer)
                            (and (not (eq buffer (current-buffer)))
                                 (termdex--candidate-p buffer)))
                          (buffer-list))))
    (if buffer
        (termdex--display buffer)
      (termdex-here))))

(defun termdex--describe (terminal)
  "Return (DIRECTORY . STATE) describing TERMINAL for display."
  (cons (or (when-let* ((dir (termdex-terminal-directory terminal)))
              (abbreviate-file-name (directory-file-name dir)))
            "?")
        (cond ((eq (termdex-terminal-busy terminal) 'unknown) "remote")
              ((termdex-terminal-busy terminal)
               (or (termdex-terminal-command terminal) "busy"))
              (t "idle"))))

(defun termdex--completion-table (terminals)
  "Return a completion table over TERMINALS, keyed by buffer name.

Buffer names are unique, which makes them usable as candidate keys, and
they are what you already recognise a terminal by.

The table refuses to be sorted.  Order carries meaning here -- it is
most-recently-used -- and it is what makes repeated `RET' toggle between
two terminals the way \\[switch-to-buffer] does."
  (let ((annotations
         (mapcar (lambda (terminal)
                   (let ((described (termdex--describe terminal)))
                     (cons (termdex-terminal-name terminal)
                           (format "  %s  [%s]" (car described) (cdr described)))))
                 terminals)))
    (lambda (string predicate action)
      (if (eq action 'metadata)
          `(metadata
            (category . buffer)
            (annotation-function
             . ,(lambda (candidate) (alist-get candidate annotations nil nil #'equal)))
            (display-sort-function . identity)
            (cycle-sort-function . identity))
        (complete-with-action action (mapcar #'car annotations) string predicate)))))

(defun termdex--read (prompt terminals)
  "Read one of TERMINALS with PROMPT, and return its buffer.

The current buffer is left out and the rest are offered most recently
used first, so the obvious answer is the one in front of you.  That is
also what makes this toggle: switching updates most-recently-used order,
so the terminal you just left becomes the next default, and `RET' `RET'
goes back and forth.

The first candidate is passed as the default as well as being first in
the list.  Completion frameworks disagree about which of the two an
immediate `RET' takes -- the built-in UI returns the default, Vertico
returns the first candidate -- and making them the same makes the
question moot."
  (let* ((offered (seq-remove (lambda (terminal)
                                (eq (termdex-terminal-buffer terminal)
                                    (current-buffer)))
                              terminals))
         (default (when offered (termdex-terminal-name (car offered)))))
    (unless offered
      (user-error "No other terminal"))
    (get-buffer (completing-read (format-prompt prompt default)
                                 (termdex--completion-table offered)
                                 nil t nil nil default))))

;;;###autoload
(defun termdex-switch ()
  "Switch to a terminal, choosing from every live one.
With no input, `RET' goes to the most recent other terminal; pressing it
again comes back, as \\[switch-to-buffer] does."
  (interactive)
  (termdex--display (termdex--read "Terminal" (termdex-terminals))))

;;;###autoload
(defun termdex-switch-project ()
  "Switch to a terminal inside the current project.
Outside a project there is nothing to restrict to, so this offers every
terminal and says so."
  (interactive)
  (let* ((root (termdex--project-root (termdex-current-directory)))
         (terminals
          (if root
              (seq-filter (lambda (terminal)
                            (when-let* ((dir (termdex-terminal-directory terminal)))
                              (string-prefix-p root dir)))
                          (termdex-terminals))
            (termdex-terminals))))
    (termdex--display
     (termdex--read (if root
                        (format "Terminal in %s"
                                (file-name-nondirectory (directory-file-name root)))
                      "Terminal (no project)")
                    terminals))))


;;;; Dashboard

(defvar termdex-list-buffer-name "*Terminals*"
  "Name of the `termdex-list' buffer.")

(defvar termdex--list-timer nil
  "Timer refreshing the dashboard, or nil.
The only state termdex keeps, and the only thing
`termdex-unload-function' has to clean up.")

(defvar-keymap termdex-list-mode-map
  :doc "Keymap for `termdex-list-mode'."
  "RET" #'termdex-list-switch
  "o"   #'termdex-list-switch-other-window
  "k"   #'termdex-list-kill
  "+"   #'termdex-list-new
  "g"   #'termdex-list-refresh)

(define-derived-mode termdex-list-mode tabulated-list-mode "Termdex"
  "Major mode for the terminal dashboard.

\\{termdex-list-mode-map}"
  (setq tabulated-list-format
        [("Directory" 40 t) ("State" 8 t) ("Process" 14 t) ("Buffer" 30 t)]
        tabulated-list-padding 1)
  (tabulated-list-init-header))

(defvar-local termdex--list-include-excluded nil
  "Whether this dashboard was asked to show excluded terminals too.
Kept buffer-locally so the refresh timer redraws what was asked for
rather than reverting to the default on its first tick.")

(defun termdex--list-entries ()
  "Return `tabulated-list-entries' for every terminal."
  (mapcar
   (lambda (terminal)
     (let* ((described (termdex--describe terminal))
            (busy (termdex-terminal-busy terminal)))
       (list (termdex-terminal-buffer terminal)
             (vector (car described)
                     (cond ((eq busy 'unknown) "remote")
                           (busy "busy")
                           (t "idle"))
                     (or (termdex-terminal-command terminal) "")
                     (termdex-terminal-name terminal)))))
   (termdex-terminals termdex--list-include-excluded)))

(defun termdex-list-refresh ()
  "Re-probe every terminal and redraw the dashboard."
  (interactive)
  (when (derived-mode-p 'termdex-list-mode)
    (setq tabulated-list-entries (termdex--list-entries))
    (tabulated-list-print t)))

(defun termdex--list-tick ()
  "Refresh the dashboard, but only when it is on screen.

A dashboard buried behind other buffers costs nothing, which is what
makes a timer acceptable here at all.  The timer cancels itself once the
buffer is gone."
  (let ((buffer (get-buffer termdex-list-buffer-name)))
    (if (not (buffer-live-p buffer))
        (termdex--list-stop-timer)
      (when (get-buffer-window buffer t)
        (with-current-buffer buffer
          (termdex-list-refresh))))))

(defun termdex--list-stop-timer ()
  "Cancel the dashboard refresh timer."
  (when termdex--list-timer
    (cancel-timer termdex--list-timer)
    (setq termdex--list-timer nil)))

(defun termdex--list-start-timer ()
  "Start the dashboard refresh timer, replacing any previous one."
  (termdex--list-stop-timer)
  (when (and termdex-list-refresh-seconds (> termdex-list-refresh-seconds 0))
    (setq termdex--list-timer
          (run-at-time termdex-list-refresh-seconds termdex-list-refresh-seconds
                       #'termdex--list-tick))))

(defun termdex-list--terminal-at-point ()
  "Return the terminal buffer on the current dashboard line."
  (or (tabulated-list-get-id)
      (user-error "No terminal on this line")))

(defun termdex-list-switch ()
  "Go to the terminal on this line."
  (interactive)
  (termdex--display (termdex-list--terminal-at-point)))

(defun termdex-list-switch-other-window ()
  "Show the terminal on this line in another window."
  (interactive)
  (switch-to-buffer-other-window (termdex-list--terminal-at-point)))

(defun termdex-list-kill ()
  "Kill the terminal on this line, confirming when it is busy."
  (interactive)
  (let* ((buffer (termdex-list--terminal-at-point))
         (terminal (termdex--probe buffer)))
    (when (or (not (termdex-terminal-busy terminal))
              (yes-or-no-p (format "%s is running %s; kill it? "
                                   (buffer-name buffer)
                                   (or (termdex-terminal-command terminal) "something"))))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buffer))
      (termdex-list-refresh))))

(defun termdex-list-new ()
  "Make a new terminal in the directory of the terminal on this line."
  (interactive)
  (let ((directory (termdex-terminal-directory
                    (termdex--probe (termdex-list--terminal-at-point)))))
    (unless directory
      (user-error "That terminal's directory is unknown"))
    (termdex--create directory)))

;;;###autoload
(defun termdex-list (&optional include-excluded)
  "Show a dashboard of every live terminal.

With a prefix argument, INCLUDE-EXCLUDED, also list the terminals
`termdex-exclude' and `termdex-exclude-functions' keep out of the other
commands -- an overview of everything, rather than of what termdex will
send you to."
  (interactive "P")
  (let ((buffer (get-buffer-create termdex-list-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'termdex-list-mode)
        (termdex-list-mode))
      (setq termdex--list-include-excluded (and include-excluded t))
      (termdex-list-refresh))
    (termdex--list-start-timer)
    (pop-to-buffer buffer)))

;;;; Mode-line indicator

(defcustom termdex-indicator-glyph "💻"
  "Glyph shown before the terminal count in the mode line.
Any string works: plain ASCII (\">_\") for a TTY whose fonts cannot
show the emoji, or a terminal icon glyph with a Nerd Font installed."
  :type 'string)

(defvar-keymap termdex-indicator-map
  :doc "Keymap on the mode-line indicator."
  "<mode-line> <mouse-1>" #'termdex-list)

(defun termdex--indicator ()
  "Return the mode-line indicator string, or nil with no terminals.

Runs at every mode-line redisplay of every window, so it may count
terminals -- major mode, live process, exclusions -- but never probe
them: nothing here is allowed to touch /proc.  Zero terminals returns
nil rather than a \"0\", so sessions without terminals carry no
indicator at all."
  (let ((count (seq-count #'termdex--candidate-p (buffer-list))))
    (when (> count 0)
      (concat " "
              (propertize (format "%s %d" termdex-indicator-glyph count)
                          'help-echo "Terminals\nmouse-1: dashboard (termdex-list)"
                          'mouse-face 'mode-line-highlight
                          'local-map termdex-indicator-map)))))

(defvar termdex--indicator-construct '(:eval (termdex--indicator))
  "The construct `termdex-indicator-mode' puts in `global-mode-string'.
Held in a variable so disabling the mode can find and remove exactly
what enabling it added.")
;; An `:eval' reached through a symbol is only evaluated if the symbol
;; is marked risky.
(put 'termdex--indicator-construct 'risky-local-variable t)

;;;###autoload
(define-minor-mode termdex-indicator-mode
  "Show a terminal count in the mode line.

A glyph (`termdex-indicator-glyph') and the number of live terminals,
in every window's mode line.  Terminals excluded by `termdex-exclude'
or `termdex-exclude-functions' are not counted, so the number is the
population `termdex-switch' offers.  With no terminals at all the
indicator disappears entirely.

\\`mouse-1' on the indicator opens the `termdex-list' dashboard."
  :global t
  (if termdex-indicator-mode
      (progn
        ;; The construct symbol must never end up first: the renderer reads a
        ;; list whose car is a symbol as the conditional (SYMBOL THEN ELSE),
        ;; which with no THEN displays as *invalid*.  Seeding "" keeps the
        ;; list's car a string; `display-time-mode' does the same.
        (unless global-mode-string
          (setq global-mode-string '("")))
        (add-to-list 'global-mode-string 'termdex--indicator-construct t))
    (setq global-mode-string
          (delq 'termdex--indicator-construct global-mode-string))))

(defun termdex-unload-function ()
  "Undo what leaves termdex-owned state outside this package's symbols.
The dashboard timer would call a function about to be unbound and
signal on every tick; the indicator would do the same from every mode
line.  Returning nil leaves the rest of the unloading to
`unload-feature'."
  (termdex--list-stop-timer)
  (when termdex-indicator-mode
    (termdex-indicator-mode -1))
  nil)

(provide 'termdex)

;;; termdex.el ends here
