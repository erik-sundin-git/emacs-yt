# Copyright (C) 2026 Erik Sundin
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Every target runs the flake's Emacs ($YT_EMACS), never a host Emacs, in
# an isolated HOME/XDG environment (scripts/isolated).  Run targets inside
# `nix develop', or through `nix run .#test -- TARGET'.
#
# Run a subset of tests with: make test SELECTOR='"yt-test-.*"'

ifneq ($(filter-out clean,$(or $(MAKECMDGOALS),all)),)
override EMACS := $(YT_EMACS)
ifeq ($(strip $(EMACS)),)
$(error YT_EMACS is unset: run inside `nix develop', or use `nix run .#test')
endif
ifeq ($(filter /nix/store/%,$(EMACS)),)
$(error YT_EMACS=$(EMACS) is not a Nix store path; refusing to use a host Emacs)
endif
endif

SRCS     := $(filter-out %-autoloads.el,$(wildcard yt*.el))
TESTS    := $(wildcard test/*-tests.el)
SELECTOR ?= t
BATCH     = sh scripts/isolated $(EMACS) -Q --batch -L . -L test \
            --eval '(setq load-prefer-newer t)'

.PHONY: all compile native checkdoc lint test clean

all: compile checkdoc lint test

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(SRCS)

native:
	$(BATCH) --eval '(startup-redirect-eln-cache (expand-file-name ".eln-cache"))' \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-native-compile $(SRCS)

checkdoc:
	$(BATCH) -l scripts/checkdoc-batch.el $(SRCS)

lint:
	$(BATCH) --eval '(require (quote package-lint))' \
	  --eval '(setq package-lint-main-file "yt.el")' \
	  -f package-lint-batch-and-exit $(SRCS)

test:
	$(BATCH) -l ert $(addprefix -l ,$(TESTS)) \
	  --eval '(ert-run-tests-batch-and-exit $(SELECTOR))'

clean:
	rm -f *.elc test/*.elc
	rm -rf .eln-cache
