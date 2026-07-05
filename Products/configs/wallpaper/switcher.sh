#!/usr/bin/env bash
# Icarus Dynamic Wallpaper Switcher

WALLPAPER_DIR="/usr/share/backgrounds/icarus/references"

if [[ ! -d "$WALLPAPER_DIR" ]]; then
    echo "Error: Wallpaper directory not found at $WALLPAPER_DIR"
    exit 1
fi

# Build Rofi menu with image previews
menu_items=""
for file in "$WALLPAPER_DIR"/*; do
    if [[ -f "$file" ]]; then
        filename=$(basename "$file")
        menu_items+="${filename}\0icon\x1f${file}\n"
    fi
done

# Show rofi menu
selected=$(echo -en "$menu_items" | rofi -dmenu -i -replace -config ~/.config/rofi/wallpaper.rasi -p "Select Wallpaper")

if [[ -n "$selected" ]]; then
    full_path="$WALLPAPER_DIR/$selected"
    
    if [[ -f "$full_path" ]]; then
        # 1. Update wallpaper daemon
        killall swaybg 2>/dev/null
        swaybg -i "$full_path" -m fill &
        
        # 2. Persist the current wallpaper path (so it survives reboot)
        echo "swaybg -i \"$full_path\" -m fill &" > ~/.config/icarus/wallpaper.sh
        chmod +x ~/.config/icarus/wallpaper.sh
        
        # 3. Generate new color palette
        icarus-palette "$full_path"
        
        # 4. Reload Waybar
        killall -SIGUSR2 waybar
        
        # 5. Reload Eww Dashboard
        eww reload || true
    fi
fi
