# shellcheck shell=bash
#
# lib/tui.sh - whiptail/dialog front end for `pve-toolbox ui`.
#
# Sourced by the launcher on demand, not at startup: nothing else needs it,
# and `_complete` should not pay for it. Defines no side effects beyond
# variable and function definitions.
#
[[ -n ${_TOOLBOX_TUI_LOADED:-} ]] && return 0
_TOOLBOX_TUI_LOADED=1

TUI_BIN="${TUI_BIN:-}"
TUI_BACKTITLE="${TUI_BACKTITLE:-pve-toolbox}"

# whiptail arrives with debconf, so it is on every Debian and every PVE host.
# dialog is accepted too: for the four widgets used here the command lines are
# the same, and some people have it instead.
tui_detect() {
    # An override that is not installed exits 127, and once a widget has run
    # that is as indistinguishable from Cancel as anything else, so check it
    # here rather than finding out silently later.
    if [[ -n $TUI_BIN ]]; then
        command -v "$TUI_BIN" >/dev/null 2>&1
        return
    fi
    local c
    for c in whiptail dialog; do
        if command -v "$c" >/dev/null 2>&1; then
            TUI_BIN=$c
            return 0
        fi
    done
    return 1
}

# --------------------------------------------------------------- geometry --

# Fit the box to the terminal rather than to the list: a host with 40 pools
# still has to be usable in an 80x24 console.
tui_size() { # tui_size <rows> -> sets TUI_H TUI_W TUI_LIST
    local rows=$1 lines cols max
    lines=$(tput lines 2>/dev/null) || lines=24
    cols=$(tput cols 2>/dev/null) || cols=80

    TUI_W=$(( cols - 8 ))
    (( TUI_W > 100 )) && TUI_W=100
    (( TUI_W < 60 )) && TUI_W=60

    # 9 lines go to the border, the prompt text and the buttons.
    max=$(( lines - 12 ))
    (( max < 3 )) && max=3
    TUI_LIST=$rows
    (( TUI_LIST > max )) && TUI_LIST=$max

    TUI_H=$(( TUI_LIST + 9 ))
    (( TUI_H > lines - 2 )) && TUI_H=$(( lines - 2 ))
    (( TUI_H < 7 )) && TUI_H=7
}

# ---------------------------------------------------------------- widgets --

# The widgets draw on stdout and put the selection on stderr, so the two are
# swapped through fd 3 to capture what was chosen without eating the screen.
tui_capture() { "$TUI_BIN" --backtitle "$TUI_BACKTITLE" "$@" 3>&1 1>&2 2>&3; }

# Exit status only, so nothing to capture - but the screen still goes to
# stderr rather than stdout. Called inside a $( ) an unredirected widget draws
# into the capture instead of onto the terminal, which leaves an invisible box
# sitting there waiting for a keypress.
tui_plain() { "$TUI_BIN" --backtitle "$TUI_BACKTITLE" "$@" 1>&2; }

tui_menu() { # tui_menu <title> <text> <tag> <item>... -> prints the tag
    local title=$1 text=$2; shift 2
    tui_size $(( $# / 2 ))
    tui_capture --title "$title" --menu "$text" \
        "$TUI_H" "$TUI_W" "$TUI_LIST" "$@"
}

tui_checklist() { # tui_checklist <title> <text> <tag> <desc> <on|off>... -> tags, one per line
    local title=$1 text=$2; shift 2
    tui_size $(( $# / 3 ))
    tui_capture --title "$title" --separate-output --checklist "$text" \
        "$TUI_H" "$TUI_W" "$TUI_LIST" "$@"
}

tui_yesno() { # tui_yesno <title> <text> - defaults to No
    tui_size 0
    tui_plain --title "$1" --defaultno --yesno "$2" "$TUI_H" "$TUI_W"
}

tui_msg() { # tui_msg <title> <text>
    tui_size 0
    tui_plain --title "$1" --msgbox "$2" "$TUI_H" "$TUI_W"
}

# Draws and returns immediately, for the pause while module_status runs.
tui_info() { # tui_info <text>
    tui_size 0
    tui_plain --infobox "$1" 7 "$TUI_W"
}

# ncurses-bin is not guaranteed just because libnewt is, so fall back to the
# escape sequence rather than leaving the widget's screen on the terminal.
tui_clear() { command clear 2>/dev/null || printf '\033[H\033[2J'; }
