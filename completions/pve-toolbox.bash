# shellcheck shell=bash
# Guest modules such as komodo-periphery use dynamic module/tag discovery.
#
# bash completion for pve-toolbox.
#
# Candidates come from `pve-toolbox _complete`, so a module dropped into
# modules/ is completable immediately - no names are listed here. The
# launcher is invoked as COMP_WORDS[0], so completing ./pve-toolbox in a
# checkout asks that checkout rather than whatever is on PATH.

_pve_toolbox_candidates() { # _pve_toolbox_candidates <target> [args...]
    "${COMP_WORDS[0]}" _complete "$@" 2>/dev/null
}

_pve_toolbox() {
    local cur prev prev2 i word cmd="" arg1="" nargs=0 candidates used c
    local out=()

    cur=${COMP_WORDS[COMP_CWORD]}
    prev=""; prev2=""
    ((COMP_CWORD < 1)) || prev=${COMP_WORDS[COMP_CWORD - 1]}
    ((COMP_CWORD < 2)) || prev2=${COMP_WORDS[COMP_CWORD - 2]}

    # The first non-flag word after the program name is the command; the
    # rest are its arguments. Flags are accepted anywhere, so they cannot
    # simply be counted by position. '=' is in COMP_WORDBREAKS, so bash hands
    # over --color=never as the three words '--color', '=' and 'never': the
    # '=' and the value after it belong to the flag, not the command line.
    for ((i = 1; i < COMP_CWORD; i++)); do
        word=${COMP_WORDS[i]}
        if [[ $word == --color && ${COMP_WORDS[i + 1]:-} == = ]]; then
            i=$((i + 2))
            continue
        fi
        [[ $word == -* || $word == = ]] && continue
        if [[ -z $cmd ]]; then
            cmd=$word
        else
            nargs=$((nargs + 1))
            [[ $nargs -gt 1 ]] || arg1=$word
        fi
    done

    # --color's value is not read from the command table: it is the same
    # three words for every command. In the split form readline replaces
    # only the text after the '=', so the candidates are the bare values; a
    # lone '=' is the word bash reports when nothing follows it yet.
    if [[ $cur == = && $prev == --color ]]; then
        mapfile -t COMPREPLY < <(compgen -W 'auto always never' -- "")
        return
    fi
    if [[ $prev == = && $prev2 == --color ]]; then
        mapfile -t COMPREPLY < <(compgen -W 'auto always never' -- "$cur")
        return
    fi
    # The joined form, for a shell whose COMP_WORDBREAKS lacks '='.
    if [[ $cur == --color=* ]]; then
        mapfile -t COMPREPLY < <(compgen -W '--color=auto --color=always --color=never' -- "$cur")
        return
    fi
    if [[ $cur == -* ]]; then
        mapfile -t COMPREPLY < <(compgen -W "$(_pve_toolbox_candidates flags "$cmd")" -- "$cur")
        # A lone --color= wants its value next, not a space. compopt only
        # works inside a completion bash is running.
        if [[ ${#COMPREPLY[@]} -eq 1 && ${COMPREPLY[0]} == *= ]]; then
            compopt -o nospace 2>/dev/null || true
        fi
        return
    fi

    case $cmd in
        "")        candidates=$(_pve_toolbox_candidates commands) ;;
        help)      # takes a single optional command name
                   [[ $nargs -eq 0 ]] || return
                   candidates=$(_pve_toolbox_candidates commands) ;;
        list)      # takes a single optional tag
                   [[ $nargs -eq 0 ]] || return
                   candidates=$(_pve_toolbox_candidates tags) ;;
        install|update|check|status)
                   candidates=$(_pve_toolbox_candidates modules) ;;
        config)    # config show <module>: 'show', then a single module name
                   case $nargs in
                       0) candidates=show ;;
                       1) [[ $arg1 == show ]] || return
                          candidates=$(_pve_toolbox_candidates modules) ;;
                       *) return ;;
                   esac ;;
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
