SHELL := /bin/bash
# Bash only. completions/_pve-toolbox is zsh and tests/tui.exp is Tcl;
# neither bash -n nor shellcheck can read either.
FILES := pve-toolbox $(sort $(wildcard lib/*.sh)) $(sort $(wildcard modules/*/*.sh)) \
         completions/pve-toolbox.bash $(sort $(wildcard tests/*.sh))

.PHONY: lint syntax test test-tui

lint: syntax
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed: apt install shellcheck"; exit 1; }
	shellcheck -x -S warning $(FILES)

syntax:
	@for f in $(FILES); do bash -n $$f && echo "ok  $$f"; done

test: syntax
	@./tests/smoke.sh
	@./tests/tui.sh

# Split out so it can be demanded explicitly; `test` skips it when expect
# or whiptail is missing.
test-tui:
	@TUI_TEST_REQUIRED=1 ./tests/tui.sh
