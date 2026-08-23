# lib/tui.sh

The whiptail/dialog widgets behind [`pve-toolbox ui`](../getting-started.md#the-full-screen-ui).

Sourced by the launcher on demand rather than at startup — nothing else needs
it, and completion candidates should not pay for it. Like `lib/common.sh` it
defines no side effects beyond variables and functions.

Modules never source this. The widgets only ever *choose*; by the time a module
function runs, the screen has already been handed back.

## Backend

| Variable | Default |
| --- | --- |
| `TUI_BIN` | first of `whiptail`, `dialog` found on `PATH` |
| `TUI_BACKTITLE` | `pve-toolbox` |

`tui_detect`
: Exit status. Picks a backend and sets `TUI_BIN`. An explicit `TUI_BIN` is
  checked rather than trusted — see the exit-code note below for why a name
  that is not installed cannot be diagnosed after the fact.

whiptail is what debconf draws its prompts with, so a PVE host already has it.
dialog is accepted because for these four widgets the command lines are the
same.

## Widgets

`tui_menu <title> <text> <tag> <item>...`
: Prints the chosen tag. Non-zero on Cancel or Esc.

`tui_checklist <title> <text> <tag> <desc> <on|off>...`
: Prints the checked tags, one per line. Non-zero on Cancel or Esc.

`tui_yesno <title> <text>`
: Exit status, for use in `if`. Defaults to No.

`tui_msg <title> <text>` · `tui_info <text>`
: A box to acknowledge, and one that draws and returns immediately.

`tui_clear`
: Falls back to the escape sequence, because ncurses-bin is not guaranteed
  just by having libnewt.

## Geometry

`tui_size <rows>`
: Sets `TUI_H`, `TUI_W` and `TUI_LIST`.

Sized to the terminal, not to the list: a host with forty pools still has to be
usable in an 80x24 console. Width is capped at 100 and floored at 60, the list
gets whatever is left after the border, prompt and buttons, and the box height
is floored at 7 so an implausibly short terminal cannot ask for a negative one.

## Two things whiptail does

!!! warning "It draws on stdout and writes the selection to stderr"

    Capturing a choice means swapping the two, which `tui_capture` does through
    fd 3. A widget called inside a `$( )` *without* that swap draws into the
    capture instead of onto the terminal — the box is then invisible and still
    waiting for a keypress.

    `tui_plain` exists for the widgets with nothing to capture, and sends their
    screen to stderr so the mistake cannot be made twice. The launcher keeps
    only `tui_checklist` inside a capture and answers through a global.

!!! warning "It exits 1 on a terminal it cannot draw on"

    Which is also its exit code for Cancel. The two are indistinguishable once
    a widget has run, so the ui would look like it quit the instant it started.

    Both causes are therefore ruled out before the first box: `TERM` is checked
    against `dumb`, `unknown` and unset, and an explicit `TUI_BIN` is checked
    for existence — a missing one exits 127, which is no easier to tell apart.

## Tests

`tests/tui.exp` drives the real launcher through a pty and asserts on what
reaches the screen, including both cases above. It needs `expect` and
`whiptail`, and skips without them so `make test` still works anywhere. CI sets
`TUI_TEST_REQUIRED=1` in the Debian job, where a missing dependency is a
failure rather than a skip.
