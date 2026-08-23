SHELL := /bin/bash
FILES := pve-toolbox $(sort $(wildcard lib/*.sh)) $(sort $(wildcard modules/*/*.sh))

.PHONY: lint syntax test

lint: syntax
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed: apt install shellcheck"; exit 1; }
	shellcheck -x -S warning $(FILES)

syntax:
	@for f in $(FILES); do bash -n $$f && echo "ok  $$f"; done

test: syntax
	@set -e; \
	smoke() { \
	    TOOLBOX_BIN_DIR=$$(mktemp -d) TOOLBOX_STATE_DIR=$$(mktemp -d) \
	    TOOLBOX_SYSTEMD_DIR=$$(mktemp -d) TOOLBOX_CONF_DIR=$$(mktemp -d) \
	    "$$1" list >/dev/null; \
	}; \
	smoke ./pve-toolbox; echo "ok  launcher smoke test"; \
	d=$$(mktemp -d); ln -s "$$PWD/pve-toolbox" "$$d/pve-toolbox"; \
	trap 'rm -rf "$$d"' EXIT; \
	smoke "$$d/pve-toolbox"; echo "ok  launcher via symlink"
