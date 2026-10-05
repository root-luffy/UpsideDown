#!/usr/bin/env bash
# One-click installer for UpsideDown on Linux.
#
#   1. Installs ddcutil with your package manager if it's missing.
#   2. Makes sure your user can reach the monitor over I2C (DDC/CI).
#   3. Detects which input this PC is on and which inputs the monitor supports.
#   4. Test-flips to the other computer so you can confirm the right input.
#   5. Installs `upsidedown` to ~/.local/bin and binds it to a keyboard shortcut.
#
# Examples:
#   ./install.sh                             # interactive, detects everything
#   ./install.sh --other 18 --no-test        # you already know the other input code
#   ./install.sh --hotkey "<Control><Alt>m"  # use Ctrl+Alt+M instead of Ctrl+F12
#   ./install.sh --this-pc 15 --other 17     # set both inputs yourself

set -euo pipefail

THIS_PC=""
OTHER=""
BUS=""
HOTKEY="<Control>F12"
NO_TEST=""

usage() { sed -n '2,14s/^# \{0,1\}//p' "$0"; exit "${1:-0}"; }

while (( $# )); do
    case "$1" in
        --this-pc) THIS_PC="${2:?}"; shift 2 ;;
        --other)   OTHER="${2:?}"; shift 2 ;;
        --bus)     BUS="${2:?}"; shift 2 ;;
        --hotkey)  HOTKEY="${2:?}"; shift 2 ;;
        --no-test) NO_TEST=1; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/upsidedown"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/upsidedown"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
UDEV_RULE=/etc/udev/rules.d/60-upsidedown-i2c.rules

if [[ -t 1 ]]; then
    C_STEP=$'\e[36m' C_OK=$'\e[32m' C_WARN=$'\e[33m' C_FAIL=$'\e[31m' C_DIM=$'\e[90m' C_TITLE=$'\e[35m' C_OFF=$'\e[0m'
else
    C_STEP="" C_OK="" C_WARN="" C_FAIL="" C_DIM="" C_TITLE="" C_OFF=""
fi
step() { printf '\n%s> %s%s\n' "$C_STEP" "$1" "$C_OFF"; }
ok()   { printf '  %s%s%s\n' "$C_OK" "$1" "$C_OFF"; }
warn() { printf '  %s%s%s\n' "$C_WARN" "$1" "$C_OFF"; }
fail() { printf '\n  %s%s%s\n\n' "$C_FAIL" "$1" "$C_OFF" >&2; exit 1; }
ask()  { local a; read -r -p "  $1 " a || fail "No answer, stopping."; printf '%s' "$a"; }

if [[ $EUID -eq 0 ]]; then
    fail "Run this as your normal user, not root. It will ask for sudo when it needs it."
fi

# Common MCCS input codes. Manufacturers don't always follow them, which is why
# the installer test-flips before saving.
input_label() {
    local name=""
    case "$1" in
        1) name="VGA 1" ;; 2) name="VGA 2" ;; 3) name="DVI 1" ;; 4) name="DVI 2" ;;
        15) name="DisplayPort 1" ;; 16) name="DisplayPort 2" ;;
        17) name="HDMI 1" ;; 18) name="HDMI 2" ;; 27) name="USB-C" ;;
    esac
    if [[ -n $name ]]; then echo "$1  (usually $name)"; else echo "$1"; fi
}

printf '\n  %sU P S I D E   D O W N%s\n' "$C_TITLE" "$C_OFF"
printf '  %sone key. two computers. one monitor.%s\n' "$C_DIM" "$C_OFF"

# --- 1. ddcutil -------------------------------------------------------------

step "Checking for ddcutil"

if ! command -v ddcutil >/dev/null; then
    if   command -v pacman  >/dev/null; then pm=(sudo pacman -S --needed --noconfirm ddcutil)
    elif command -v apt-get >/dev/null; then pm=(sudo apt-get install -y ddcutil)
    elif command -v dnf     >/dev/null; then pm=(sudo dnf install -y ddcutil)
    elif command -v zypper  >/dev/null; then pm=(sudo zypper --non-interactive install ddcutil)
    elif command -v xbps-install >/dev/null; then pm=(sudo xbps-install -y ddcutil)
    elif command -v emerge  >/dev/null; then pm=(sudo emerge --noreplace app-misc/ddcutil)
    else fail "ddcutil is missing. Install it with your package manager and run this again."
    fi
    warn "Not found. Installing it: ${pm[*]}"
    if ! "${pm[@]}"; then
        # A stale package list makes pacman ask mirrors for a version they've already deleted (404).
        [[ ${pm[1]} == pacman ]] && warn "On Arch, a 404 means your package list is out of date: run 'sudo pacman -Syu ddcutil' and try again."
        fail "ddcutil install did not finish. Install it yourself and run this again."
    fi
    command -v ddcutil >/dev/null || fail "ddcutil still isn't on your PATH."
fi
ok "Found $(ddcutil --version 2>/dev/null | head -n 1)"

# --- 2. Monitor detection ---------------------------------------------------

step "Talking to your monitor (DDC/CI)"

# Prints "bus<TAB>model<TAB>id" for each display ddcutil can talk to, where id is
# ddcutil's "maker:model:serial". The switcher uses the id to find the monitor again
# if its bus number changes.
detect() {
    ddcutil detect --terse 2>/dev/null | awk '
        /^Display [0-9]+/ { inside = 1; bus = ""; next }
        /^[^ \t]/         { inside = 0 }
        inside && /I2C bus:/ { bus = $NF; sub(/.*i2c-/, "", bus) }
        inside && /Monitor:/ {
            sub(/^[ \t]*Monitor:[ \t]*/, ""); n = split($0, p, ":")
            model = (n >= 2 && p[2] != "") ? p[2] : $0
            if (bus != "") print bus "\t" model "\t" $0
        }'
}

# Load i2c-dev and give the logged-in user access to /dev/i2c-*.
fix_i2c_access() {
    if ! compgen -G "/dev/i2c-*" >/dev/null; then
        warn "Loading the i2c-dev kernel module (needs sudo)..."
        sudo modprobe i2c-dev
        echo i2c-dev | sudo tee /etc/modules-load.d/i2c-dev.conf >/dev/null
    fi
    local dev
    for dev in /dev/i2c-*; do
        if [[ -e $dev && ! ( -r $dev && -w $dev ) ]]; then
            warn "Giving your user access to the monitor's I2C bus (needs sudo)..."
            echo 'SUBSYSTEM=="i2c-dev", KERNEL=="i2c-[0-9]*", TAG+="uaccess"' | sudo tee "$UDEV_RULE" >/dev/null
            sudo udevadm control --reload-rules
            sudo udevadm trigger --subsystem-match=i2c-dev --action=add
            sudo udevadm settle || true
            break
        fi
    done
}

if [[ -z $BUS ]]; then
    mapfile -t displays < <(detect)
    if (( ${#displays[@]} == 0 )); then
        fix_i2c_access
        mapfile -t displays < <(detect)
    fi
    if (( ${#displays[@]} == 0 )); then
        fail "No monitor answered. Turn on 'DDC/CI' in the monitor's on-screen menu (usually under System or Other settings) and run this again. Run 'ddcutil detect' to see why."
    fi

    pick=1
    if (( ${#displays[@]} > 1 )); then
        echo "  Found more than one monitor:"
        for i in "${!displays[@]}"; do
            IFS=$'\t' read -r b m _ <<<"${displays[i]}"
            printf '  [%d] %s  (I2C bus %s)\n' $(( i + 1 )) "$m" "$b"
        done
        while :; do
            pick=$(ask "Which one should UpsideDown flip? [1-${#displays[@]}]")
            [[ $pick =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#displays[@]} )) && break
        done
    fi
    IFS=$'\t' read -r BUS model MONITOR_ID <<<"${displays[pick-1]}"
    ok "Monitor: $model (I2C bus $BUS)"
else
    MONITOR_ID=$(detect | awk -F '\t' -v b="$BUS" '$1 == b { print $3; exit }')
    ok "Monitor: I2C bus $BUS"
fi

FAST=()
ddcutil --help 2>/dev/null | grep -q -- --skip-ddc-checks && FAST=(--skip-ddc-checks)
ddc() { ddcutil --bus "$BUS" "${FAST[@]}" "$@"; }

get_input() {
    local out hex
    for _ in 1 2 3 4 5; do
        out=$(ddc --terse getvcp 60 2>/dev/null) || true
        hex=${out##*x}
        if [[ $out == *x* && $hex =~ ^[0-9a-fA-F]+$ ]]; then
            echo $(( 0x$hex & 0xFF ))
            return 0
        fi
        sleep 0.1
    done
    return 1
}

set_input() {
    for _ in 1 2 3; do
        ddc --noverify setvcp 60 "$1" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    return 1
}

# Input codes from the monitor's capabilities string, e.g. "60(0F 11 12)".
supported_inputs() {
    local caps codes
    caps=$(ddc --verbose capabilities 2>/dev/null) || return 1
    codes=$(grep -oE '(^|[^0-9A-Fa-f])60 ?\([0-9A-Fa-f ]+\)' <<<"$caps" | head -n 1 | sed -E 's/.*\(([^)]*)\).*/\1/')
    [[ -n $codes ]] || return 1
    for c in $codes; do echo $(( 16#$c )); done
}

test_flip() {
    echo
    echo "  Switching the monitor to input $1 for 8 seconds..."
    echo "  Watch the screen: does your other computer appear?"
    sleep 2
    set_input "$1" || true
    sleep 8
    set_input "$2" || true
    sleep 3
    [[ $(ask "Did your other computer show up? [y/n]") =~ ^[[:space:]]*[yY] ]]
}

if [[ -z $THIS_PC ]]; then
    THIS_PC=$(get_input) ||
        fail "Your monitor didn't answer. Turn on 'DDC/CI' in the monitor's on-screen menu (usually under System or Other settings) and run this again."
fi
ok "This PC is on input $(input_label "$THIS_PC")"

if [[ -z $OTHER ]]; then
    if mapfile -t supported < <(supported_inputs) && (( ${#supported[@]} )); then
        ok "Monitor inputs: ${supported[*]}"
    else
        warn "Monitor didn't list its inputs; trying the common ones."
        supported=(17 18 15 16 27 3 1)
    fi
    candidates=()
    for c in "${supported[@]}"; do [[ $c != "$THIS_PC" ]] && candidates+=("$c"); done

    step "Which input is your other computer on?"
    echo "  Make sure the other computer is on and awake."

    while [[ -z $OTHER ]]; do
        for i in "${!candidates[@]}"; do
            printf '  [%d] input %s\n' $(( i + 1 )) "$(input_label "${candidates[i]}")"
        done
        pick=$(ask "Pick a number (or type an input code)")
        [[ $pick =~ ^[0-9]+$ ]] || continue
        code=$(( 10#$pick ))
        if (( code >= 1 && code <= ${#candidates[@]} )); then code=${candidates[code-1]}; fi
        (( code > 0 )) || continue

        if [[ -n $NO_TEST ]] || test_flip "$code" "$THIS_PC"; then
            OTHER=$code
        else
            warn "No problem, try another input."
        fi
    done
fi
ok "Other computer is on input $(input_label "$OTHER")"

# --- 3. Install -------------------------------------------------------------

step "Installing to $BIN"

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$APP_DIR"
install -m 755 "$HERE/src/upsidedown.sh" "$BIN"

cat > "$CONFIG_DIR/config.ini" <<EOF
; UpsideDown settings. The installer fills these in for you.
; Changes apply the next time you press the hotkey.

[UpsideDown]
; Input code (DDC/CI VCP 0x60, decimal) of the input this PC is plugged into.
ThisPC=$THIS_PC

; Input code of the other computer (Mac, laptop, console...).
Other=$OTHER

; I2C bus of the monitor to flip (the N in /dev/i2c-N, see 'ddcutil detect').
Bus=$BUS

; The monitor's identity (maker:model:serial). If its bus number changes after a
; driver or kernel update, UpsideDown finds it again by this and updates Bus.
Monitor=$MONITOR_ID
EOF

cat > "$APP_DIR/upsidedown.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=UpsideDown
Comment=Flip the monitor to your other computer
Exec=$BIN flip
Icon=video-display
Terminal=false
Categories=Utility;
EOF
ok "Files copied"
ok "Settings: $CONFIG_DIR/config.ini"

# --- 4. Keyboard shortcut ---------------------------------------------------

step "Setting up the $HOTKEY shortcut"

GNOME_SCHEMA=org.gnome.settings-daemon.plugins.media-keys
GNOME_PATH=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/upsidedown/
desktop="${XDG_CURRENT_DESKTOP:-}"
bound=""

if [[ $desktop =~ GNOME|Unity ]] && command -v gsettings >/dev/null &&
   gsettings list-keys "$GNOME_SCHEMA" >/dev/null 2>&1; then
    list=$(gsettings get "$GNOME_SCHEMA" custom-keybindings)
    if [[ $list != *"'$GNOME_PATH'"* ]]; then
        if [[ $list == *"[]"* ]]; then list="['$GNOME_PATH']"; else list="${list%]}, '$GNOME_PATH']"; fi
        gsettings set "$GNOME_SCHEMA" custom-keybindings "$list"
    fi
    gsettings set "$GNOME_SCHEMA.custom-keybinding:$GNOME_PATH" name 'UpsideDown'
    gsettings set "$GNOME_SCHEMA.custom-keybinding:$GNOME_PATH" command "$BIN flip"
    gsettings set "$GNOME_SCHEMA.custom-keybinding:$GNOME_PATH" binding "$HOTKEY"
    bound="GNOME Settings > Keyboard > Custom Shortcuts"
elif [[ $desktop =~ XFCE ]] && command -v xfconf-query >/dev/null; then
    xfconf-query -c xfce4-keyboard-shortcuts -p "/commands/custom/${HOTKEY//<Control>/<Primary>}" \
        -n -t string -s "$BIN flip"
    bound="Xfce Settings > Keyboard > Application Shortcuts"
fi

if [[ -n $bound ]]; then
    ok "Bound in $bound"
else
    warn "Your desktop (${desktop:-unknown}) can't be set up automatically."
    warn "Add a keyboard shortcut in its settings that runs:"
    echo
    echo "      $BIN flip"
    echo
    warn "KDE: System Settings > Keyboard > Shortcuts > Add New > Command or Script."
    warn "Sway/i3: bindsym Ctrl+F12 exec $BIN flip"
    warn "Hyprland: bind = CTRL, F12, exec, $BIN flip"
fi

key_text=$(sed -e 's/<Control>/Ctrl+/g; s/<Primary>/Ctrl+/g; s/<Ctrl>/Ctrl+/g' \
               -e 's/<Alt>/Alt+/g; s/<Shift>/Shift+/g; s/<Super>/Super+/g' <<<"$HOTKEY")
echo
if [[ -n $bound ]]; then
    printf '  %sDone! Press %s to flip your monitor.%s\n' "$C_OK" "$key_text" "$C_OFF"
else
    printf '  %sDone! Once the shortcut is added, press it to flip your monitor.%s\n' "$C_OK" "$C_OFF"
fi
printf '  %sYou can also run "upsidedown" in a terminal, or open UpsideDown from your app menu.%s\n\n' "$C_DIM" "$C_OFF"
