EMACS ?= emacs
ROOT  := $(CURDIR)
TESTENV := $(ROOT)/.test-env
GRAMMARS := $(TESTENV)/tree-sitter

.PHONY: test deps compile clean

## Run the test suite.
##
## Tests need a real frame so the redisplay engine actually lays text out --
## `posn-at-point' is how we assert that alignment happened.  Batch mode has no
## usable frame, so Emacs runs under a pty (via script(1)) to get a TTY frame.
test: deps
	@tests/run-tests.sh

## Build the tree-sitter grammars the tests need.
deps: $(GRAMMARS)/libtree-sitter-markdown.so

$(GRAMMARS)/libtree-sitter-markdown.so:
	@echo "Installing tree-sitter markdown grammars into $(GRAMMARS)"
	@mkdir -p $(GRAMMARS)
	@$(EMACS) --batch --eval '(progn \
	  (require (quote treesit)) \
	  (setq treesit-language-source-alist \
	    (quote ((markdown "https://github.com/tree-sitter-grammars/tree-sitter-markdown" \
	                      "split_parser" "tree-sitter-markdown/src") \
	            (markdown-inline "https://github.com/tree-sitter-grammars/tree-sitter-markdown" \
	                             "split_parser" "tree-sitter-markdown-inline/src")))) \
	  (treesit-install-language-grammar (quote markdown) "$(GRAMMARS)") \
	  (treesit-install-language-grammar (quote markdown-inline) "$(GRAMMARS)"))'

## Byte-compile everything, treating warnings as failures.
compile:
	@$(EMACS) --batch -L $(ROOT) -L $(ROOT)/md-table-align \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(ROOT)/emacs-tools.el $(ROOT)/md-table-align/*.el

clean:
	@rm -f $(ROOT)/*.elc $(ROOT)/*/*.elc tests/.last-run.log
