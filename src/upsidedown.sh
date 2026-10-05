#!/usr/bin/env bash
# UpsideDown - flip one monitor between two computers with a single hotkey.
# MIT License
#
# Linux version. Talks to the monitor over DDC/CI (VCP code 0x60, "Input Select")
# through ddcutil. The installer binds `upsidedown` to a desktop keyboard shortcut.
#
# Usage: upsidedown [flip | to <code> | status | config | help]

set -u

CONFIG_FILE="${UPSIDEDOWN_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/upsidedown/config.ini}"
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/upsidedown-$(id -u).last"

# ini KEY DEFAULT: read KEY=value from the config, ignoring ; comments.
ini() {
    local v
    v=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([^;]*\).*/\1/p" "$CONFIG_FILE" 2>/dev/null | tail -n 1)
    v=${v%"${v##*[![:space:]]}"}  # trim trailing spaces
    printf '%s' "${v:-$2}"
}

THIS_PC=$(ini ThisPC 15)
OTHER=$(ini Other 17)
BUS=$(ini Bus "")
MONITOR=$(ini Monitor "")

fail() {
    echo "upsidedown: $1" >&2
    # Run from a keyboard shortcut there's no terminal, so tell the desktop instead.
    if [[ ! -t 2 ]] && command -v notify-send >/dev/null; then
        notify-send -a UpsideDown "UpsideDown" "$1" 2>/dev/null
    fi
    exit 1
}

command -v ddcutil >/dev/null || fail "ddcutil is not installed. Run install.sh again."

# Talk to the configured I2C bus directly. Skipping detection and ddcutil's initial
# DDC checks (the installer already did both) cuts each call from ~1 s to ~0.1 s.
FAST=()
ddcutil --help 2>/dev/null | grep -q -- --skip-ddc-checks && FAST=(--skip-ddc-checks)

ddc() {
    if [[ -n $BUS ]]; then
        ddcutil --bus "$BUS" "${FAST[@]}" "$@"
    else
        ddcutil --display 1 "$@"
    fi
}

# The monitor's bus number can change after a driver or kernel update. Find it again
# by its identity (or, with only one monitor, take that one) and save the new bus.
# Slow (~1 s), so it only runs when the saved bus stops answering.
find_monitor() {
    local found
    found=$(ddcutil detect --terse 2>/dev/null | awk -v id="$MONITOR" '
        /^Display [0-9]+/ { inside = 1; bus = ""; next }
        /^[^ \t]/         { inside = 0 }
        inside && /I2C bus:/ { bus = $NF; sub(/.*i2c-/, "", bus) }
        inside && /Monitor:/ {
            sub(/^[ \t]*Monitor:[ \t]*/, "")
            if (bus != "") { n++; if (id == "" || $0 == id) hit = bus }
        }
        END { if (hit != "" && (id != "" || n == 1)) print hit }')
    [[ -n $found && $found != "$BUS" ]] || return 1
    BUS=$found
    [[ -f $CONFIG_FILE ]] && sed -i "s/^\([[:space:]]*Bus[[:space:]]*=\).*/\1$BUS/" "$CONFIG_FILE"
    return 0
}

read_input() {
    local out hex
    for _ in 1 2 3; do  # DDC reads fail now and then, especially right after a switch
        out=$(ddc --terse getvcp 60 2>/dev/null)
        hex=${out##*x}  # "VCP 60 SNC x0f" -> "0f"
        if [[ $out == *x* && $hex =~ ^[0-9a-fA-F]+$ ]]; then
            echo $(( 0x$hex & 0xFF ))
            return 0
        fi
        sleep 0.05
    done
    return 1
}

set_input() {
    for _ in 1 2 3; do
        ddc --noverify setvcp 60 "$1" >/dev/null 2>&1 && return 0
        sleep 0.05
    done
    return 1
}

flip() {
    local cur target
    # Assume we're on this PC when the monitor doesn't answer and we have no history.
    cur=$(read_input) || { find_monitor && cur=$(read_input); } ||
        cur=$(cat "$STATE_FILE" 2>/dev/null) || cur=$THIS_PC
    if [[ $cur == "$THIS_PC" ]]; then target=$OTHER; else target=$THIS_PC; fi
    switch_to "$target"
}

switch_to() {
    set_input "$1" || { find_monitor && set_input "$1"; } ||
        fail "Your monitor didn't answer. Is DDC/CI turned on in its on-screen menu? If you changed monitors or cables, run install.sh again."
    echo "$1" > "$STATE_FILE"
    # Some monitors drop a command mid-switch; check once more and resend.
    # Re-read the state file so a quick second flip isn't undone.
    (
        sleep 2.5
        want=$(cat "$STATE_FILE" 2>/dev/null) || exit 0
        cur=$(read_input) && [[ $cur != "$want" ]] && set_input "$want"
    ) >/dev/null 2>&1 &
    disown
}

case "${1:-flip}" in
    flip)
        flip ;;
    to)
        [[ ${2:-} =~ ^[0-9]+$ ]] || fail "usage: upsidedown to <input code>"
        switch_to "$2" ;;
    status)
        echo "Config:  $CONFIG_FILE"
        echo "This PC: input $THIS_PC"
        echo "Other:   input $OTHER"
        if [[ -n $BUS ]]; then echo "Monitor: ${MONITOR:-?} on I2C bus $BUS"; else echo "Monitor: display 1"; fi
        if cur=$(read_input); then echo "Now on:  input $cur"; else echo "Now on:  (monitor didn't answer)"; fi ;;
    config)
        exec "${VISUAL:-${EDITOR:-xdg-open}}" "$CONFIG_FILE" ;;
    -h|--help|help)
        sed -n '2,9s/^# \{0,1\}//p' "$0" ;;
    *)
        fail "unknown command '$1'. Try: upsidedown help" ;;
esac
