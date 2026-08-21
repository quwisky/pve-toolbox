SHELL := /bin/bash
FILES := pve-toolbox $(sort $(wildcard lib/*.sh)) $(sort $(wildcard modules/*/*.sh))

.PHONY: lint syntax test

lint: syntax
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed: apt install shellcheck"; exit 1; }
	shellcheck -x -S warning $(FILES)

syntax:
	@for f in $(FILES); do bash -n $$f && echo "ok  $$f"; done

test: syntax
	@TOOLBOX_BIN_DIR=$$(mktemp -d) TOOLBOX_STATE_DIR=$$(mktemp -d) \
	 TOOLBOX_SYSTEMD_DIR=$$(mktemp -d) TOOLBOX_CONF_DIR=$$(mktemp -d) \
	 ./pve-toolbox list >/dev/null && echo "ok  launcher smoke test"
