# emacs-tools

A collection of Emacs extensions, distributed as a single installable package.

## Repository conventions

### Layout

- Each extension lives in **its own folder** at the repo root (e.g. `md-table-align/`).
- The whole library is installable as a package by loading this directory (each
  extension folder is added to `load-path`).
- Repo root holds shared docs (`README.md`, `CLAUDE.md`) and the loader.
- `tests/` holds the suite. `hacks/` is untracked local scratch for one-off
  debug scripts — gitignored, and excluded from `load-path` by the loader via
  `emacs-tools-non-extension-directories`.
- `docs/` holds cross-session notes: open questions, decisions deferred, and
  findings worth not re-deriving. One file per question. These are working
  notes, distinct from `README.md` (for users) and `DESIGN.md` (per extension,
  for what was built and why). The loader ignores it — a directory with no
  `.el` files is never treated as an extension.

### Workflow

- **Solo developer project.** Commit as you go, directly to `main`.
- **No `Co-Authored-By: Claude` attributions** in commit messages. No
  "Generated with Claude Code" footers either.
- Commit granularly: design doc, implementation, tests, docs can each be their
  own commit.

### Design first

- Write a **planning and design doc before any implementation**. It lives in the
  extension's folder as `DESIGN.md`.
- After implementing, **validate the implementation against the design doc** and
  record any deviations (update the doc; note why it changed).

### Testing

- Tests matter. **Integration and e2e tests are more valuable than mocked unit
  tests** — prioritize them.
- For Emacs extensions this means: run a real Emacs (batch or `--eval` driven),
  in a real buffer, with real mode activation, and assert on real buffer/display
  state. Avoid stubbing Emacs internals.
- Tests use ERT and are runnable via `make test` from the repo root. The runner
  loads every `tests/*-tests.el`, so a new extension just adds a file.
- An Emacs is installed and available for testing; install any dependencies the
  test environment needs.

### Live reloading

The user iterates in a running Emacs. `M-x emacs-tools-reload` unloads a feature
and reloads its `.el`, resetting state a plain `load` keeps — `defcustom`
defaults, overlays, hooks, and stale `.elc` files.

Consequences when changing an extension:

- Changing the **meaning or units** of an existing `defcustom` is a trap: a
  session (or a user's config) holding the old value has it silently
  reinterpreted. Rename the variable instead, so stale bindings go inert.
- An extension that installs overlays, hooks or `jit-lock` handlers should
  define `FEATURE-unload-function` to tear them down.

### Documentation

- Update `README.md` for anything an end user should know: new packages, changed
  install instructions, new commands/keybindings, behavior changes.
- Each extension folder gets its own `README.md` section or file when it has
  meaningful user-facing surface area.

## Environment notes

- Emacs 31.0.90 is installed.
- `markdown-ts-mode` ships built-in with Emacs 31 (`lisp/textmodes/`).
