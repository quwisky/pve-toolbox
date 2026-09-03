# shellcheck shell=bash
#
# bash completion for pve-toolbox.
#
# Candidates come from `pve-toolbox _complete`, so a module dropped into
# modules/ is completable immediately - no names are listed here. The
# launcher is invoked as COMP_WORDS[0], so completing ./pve-toolbox in a
# checkout asks that checkout rather than whatever is on PATH.

_pve_toolbox_candidates() { # _pve_toolbox_candidates <target>
    "${COMP_WORDS[0]}" _complete "$1" 2>/dev/null
}

_pve_toolbox() {
    local cur i word cmd="" nargs=0 candidates used c
    local out=()

    cur=${COMP_WORDS[COMP_CWORD]}

    # The first non-flag word after the program name is the command; the
    # rest are its arguments. Flags are accepted anywhere, so they cannot
    # simply be counted by position.
    for ((i = 1; i < COMP_CWORD; i++)); do
        word=${COMP_WORDS[i]}
        [[ $word == -* ]] && continue
        if [[ -z $cmd ]]; then cmd=$word; else nargs=$((nargs + 1)); fi
    done

    if [[ $cur == -* ]]; then
        if [[ $cmd == lxc-update ]]; then
            mapfile -t COMPREPLY < <(compgen -W '--dry-run --allow-removals --notify --help' -- "$cur")
            return
        fi
        mapfile -t COMPREPLY < <(compgen -W \
            '-y --yes -f --force --json --quiet -V --version -h --help' -- "$cur")
        return
    fi

    case $cmd in
        "")        candidates=$(_pve_toolbox_candidates commands) ;;
        list)      # takes a single optional tag
                   [[ $nargs -eq 0 ]] || return
                   candidates=$(_pve_toolbox_candidates tags) ;;
        install|update|check|status)
                   candidates=$(_pve_toolbox_candidates modules) ;;
        uninstall) candidates=$(_pve_toolbox_candidates installed) ;;
        *)         return ;;   # menu, doctor, link, self-update take nothing
    esac

    # Drop what is already on the line, so completing a second module does
    # not re-offer the first.
    used=" ${COMP_WORDS[*]:1:COMP_CWORD-1} "
    for c in $candidates; do
        [[ $used == *" $c "* ]] && continue
        out+=("$c")
    done

    mapfile -t COMPREPLY < <(compgen -W "${out[*]}" -- "$cur")
}

complete -F _pve_toolbox pve-toolbox
