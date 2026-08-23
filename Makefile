SHELL := /bin/bash
# Bash only. completions/_pve-toolbox is zsh, which neither bash -n nor
# shellcheck can read.
FILES := pve-toolbox $(sort $(wildcard lib/*.sh)) $(sort $(wildcard modules/*/*.sh)) \
         completions/pve-toolbox.bash tests/smoke.sh

.PHONY: lint syntax test

lint: syntax
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed: apt install shellcheck"; exit 1; }
	shellcheck -x -S warning $(FILES)

syntax:
	@for f in $(FILES); do bash -n $$f && echo "ok  $$f"; done

test: syntax
	@./tests/smoke.sh
