EMACS ?= emacs
ROOT  := $(CURDIR)
TESTENV := $(ROOT)/.test-env
GRAMMARS := $(TESTENV)/tree-sitter

# Extension directories, discovered the same way the loader discovers them:
# every subdirectory holding Lisp, minus the ones that ship nothing.  Keep this
# exclusion list in step with `emacs-tools-non-extension-directories'.
NON_EXTENSIONS := tests hacks
EXTENSIONS := $(filter-out $(addprefix $(ROOT)/,$(NON_EXTENSIONS)), \
                $(sort $(patsubst %/,%,$(dir $(wildcard $(ROOT)/*/*.el)))))
SOURCES := $(ROOT)/emacs-tools.el $(wildcard $(addsuffix /*.el,$(EXTENSIONS)))

.PHONY: test deps compile clean

## Run the test suite.
##
## Tests need a real frame so the redisplay engine actually lays text out --
## `posn-at-point' is how we assert that alignment happened.  Batch mode has no
## usable frame, so Emacs runs under a pty (via script(1)) to get a TTY frame.
test: deps
	@tests/run-tests.sh

## Build the tree-sitter grammars the tests need.
##
## Interactively, `markdown-ts-mode' offers to install these itself on first
## use.  Batch mode cannot answer that prompt, so the tests need them built up
## front.  The recipes come from `markdown-ts-mode' rather than being repeated
## here, so the test environment tracks the commit Emacs pins.
deps: $(GRAMMARS)/libtree-sitter-markdown.so

$(GRAMMARS)/libtree-sitter-markdown.so:
	@EMACS_TOOLS_GRAMMAR_DIR=$(GRAMMARS) $(EMACS) --batch -l tests/install-grammars.el

## Byte-compile everything, treating warnings as failures.
##
## Every extension is picked up automatically, so adding one needs no edit here.
compile:
	@$(EMACS) --batch -L $(ROOT) $(addprefix -L ,$(EXTENSIONS)) \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SOURCES)

clean:
	@rm -f $(ROOT)/*.elc $(ROOT)/*/*.elc tests/.last-run.log
