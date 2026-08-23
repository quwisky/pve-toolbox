#!/usr/bin/env bash
#
# The zsh completion, driven the way zsh would drive it.
#
# completions/_pve-toolbox is the only shipped file nothing else covers. It is
# zsh, so neither `bash -n` nor the linter can read it, and the bash completion
# tests in smoke.sh say nothing about it. The two are meant to offer the same
# candidates, so the cases here mirror those.
#
# Needs zsh, and skips without it. CI sets ZSH_TEST_REQUIRED=1 where zsh is
# installed, so a missing dependency there fails rather than passing quietly.
#
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

if ! command -v zsh >/dev/null 2>&1; then
    if [[ ${ZSH_TEST_REQUIRED:-0} -eq 1 ]]; then
        printf 'FAIL zsh completion test required but zsh is not installed\n' >&2
        exit 1
    fi
    printf 'skip zsh completion test, no zsh\n'
    exit 0
fi

# The completion file is autoloaded by zsh with #compdef and ends by calling
# the function it defines. Loading the body without that trailing call lets
# _pve-toolbox be invoked directly with a hand-built `words`/`CURRENT`, and
# compadd is replaced with something that prints what it was handed.
zsh -f -e -c '
cd '"$PWD"'
fail() { print -r -- "FAIL $1"; exit 1 }

eval "${$(<completions/_pve-toolbox)%%$'"'"'\n'"'"'_pve-toolbox \"\$@\"*}"

compadd() {
    # The real compadd takes -a <arrayname>; print what that array holds.
    local -a a; a=(${(P)2})
    print -r -- "${a[*]}"
}

# offers <cword> <word>... -> the candidates, space separated
offers() {
    local cur=$1; shift
    words=("$@"); CURRENT=$cur
    _pve-toolbox || print -r -- ""
}

got=$(offers 2 ./pve-toolbox "")
[[ $got == *" install "* || $got == install* ]] || fail "no commands offered: $got"
[[ $got == *ui* ]] || fail "ui missing from the commands: $got"
print "ok  zsh offers commands"

got=$(offers 3 ./pve-toolbox install "")
[[ $got == *zfs-scrub* ]] || fail "no modules offered for install: $got"
print "ok  zsh offers modules after install"

got=$(offers 4 ./pve-toolbox install zfs-scrub "")
[[ $got != *zfs-scrub* ]] || fail "re-offered a module already on the line: $got"
[[ $got == *zfs-replication* ]] || fail "dropped the modules still available: $got"
print "ok  zsh drops what is already on the line"

got=$(offers 3 ./pve-toolbox list "")
[[ $got == *storage* ]] || fail "no tags offered for list: $got"
print "ok  zsh offers tags after list"

got=$(offers 4 ./pve-toolbox list storage "")
[[ -z $got ]] || fail "list takes one tag, got: $got"
print "ok  zsh stops after one tag"

# Flags are accepted anywhere, so the command is the first non-flag word.
got=$(offers 4 ./pve-toolbox -y install "")
[[ $got == *zfs-scrub* ]] || fail "a flag before the command broke it: $got"
print "ok  zsh finds the command past a flag"

for verb in ui link self-update; do
    got=$(offers 3 ./pve-toolbox $verb "")
    [[ -z $got ]] || fail "$verb takes no arguments, got: $got"
done
print "ok  zsh offers nothing for argumentless commands"
'
