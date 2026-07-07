#!/usr/bin/env bash
# Icarus Dynamic Wallpaper Switcher
#
# Installed as /usr/local/bin/icarus-wallpaper-switch — deliberately NOT
# named icarus-wallpaper, which is the startup daemon wrapper
# (configs/wallpaper/icarus-wallpaper.sh) that picks live vs static and is
# meant to run once at session start via exec-once. This script is the
# interactive picker, bound to a keybind, invoked repeatedly.

WALLPAPER_DIR="/usr/share/backgrounds/icarus/references"

if [[ ! -d "$WALLPAPER_DIR" ]]; then
    notify-send "Wallpaper switcher" "No reference wallpapers found at $WALLPAPER_DIR" 2>/dev/null
    echo "Error: Wallpaper directory not found at $WALLPAPER_DIR"
    exit 1
fi

menu_items=""
for file in "$WALLPAPER_DIR"/*; do
    if [[ -f "$file" ]]; then
        filename=$(basename "$file")
        menu_items+="${filename}\0icon\x1f${file}\n"
    fi
done

selected=$(echo -en "$menu_items" | rofi -dmenu -i -replace -config ~/.config/rofi/wallpaper.rasi -p "Select Wallpaper")

if [[ -n "$selected" ]]; then
    full_path="$WALLPAPER_DIR/$selected"

    if [[ -f "$full_path" ]]; then
        # Kill whichever wallpaper renderer is currently active — a manual
        # selection here always means "switch to this static image", so
        # both the live (mpvpaper) and static (swaybg) paths need clearing
        # first, not just swaybg. Killing a process that isn't running is
        # a harmless no-op either way.
        killall swaybg 2>/dev/null
        killall mpvpaper 2>/dev/null

        swaybg -i "$full_path" -m fill &

        mkdir -p ~/.config/icarus
        echo "swaybg -i \"$full_path\" -m fill &" > ~/.config/icarus/wallpaper.sh
        chmod +x ~/.config/icarus/wallpaper.sh

        icarus-palette "$full_path"

        killall -SIGUSR2 waybar 2>/dev/null
        eww reload 2>/dev/null || true
    fi
fi
