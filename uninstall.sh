#!/usr/bin/env bash
# Removes UpsideDown. Leaves ddcutil installed (other tools may use it).

set -u

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/upsidedown"
APP_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/applications/upsidedown.desktop"
BIN="$HOME/.local/bin/upsidedown"
UDEV_RULE=/etc/udev/rules.d/60-upsidedown-i2c.rules

GNOME_SCHEMA=org.gnome.settings-daemon.plugins.media-keys
GNOME_PATH=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/upsidedown/

if command -v gsettings >/dev/null && gsettings list-keys "$GNOME_SCHEMA" >/dev/null 2>&1; then
    list=$(gsettings get "$GNOME_SCHEMA" custom-keybindings)
    if [[ $list == *"'$GNOME_PATH'"* ]]; then
        list=$(sed -e "s#'$GNOME_PATH'##" -e 's/, ,/,/; s/\[, /[/; s/, \]/]/; s/^\[\]$/@as []/' <<<"$list")
        gsettings set "$GNOME_SCHEMA" custom-keybindings "$list"
        gsettings reset-recursively "$GNOME_SCHEMA.custom-keybinding:$GNOME_PATH"
    fi
fi

if command -v xfconf-query >/dev/null; then
    xfconf-query -c xfce4-keyboard-shortcuts -l -v 2>/dev/null |
        awk -v cmd="$BIN flip" '$1 ~ "^/commands/custom/" && substr($0, length($1) + 2) == cmd { print $1 }' |
        while read -r prop; do xfconf-query -c xfce4-keyboard-shortcuts -p "$prop" -r; done
fi

rm -f "$BIN" "$APP_FILE" "${XDG_RUNTIME_DIR:-/tmp}/upsidedown-$(id -u).last"
rm -rf "$CONFIG_DIR"

echo
echo "  UpsideDown removed. ddcutil is still installed; remove it with your package manager if you like."
if [[ -e $UDEV_RULE ]]; then
    echo "  The I2C access rule is still in place. To remove it: sudo rm $UDEV_RULE"
fi
echo "  If you added the shortcut by hand (KDE, Sway, Hyprland...), remove it there too."
