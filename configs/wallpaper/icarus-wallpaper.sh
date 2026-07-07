#!/usr/bin/env bash
#
# configs/wallpaper/icarus-wallpaper.sh
#
# Uses the live (video) wallpaper via mpvpaper if it's actually installed
# and present, falls back to the static PNG via swaybg otherwise — e.g. if
# Layer 7's AUR bootstrap (paru, which mpvpaper depends on) didn't succeed
# on this run. swaybg is installed in Layer 5 unconditionally, so the
# fallback path never depends on anything that can fail.
#
LIVE_VIDEO="/usr/share/backgrounds/icarus/icarus-midnight-live.mp4"
STATIC_IMG="/usr/share/backgrounds/icarus/icarus-midnight.png"

if command -v mpvpaper &>/dev/null && [[ -f "$LIVE_VIDEO" ]]; then
    # Run palette generation in the background so it doesn't block startup
    (icarus-palette "$STATIC_IMG" &)
    exec mpvpaper -o "no-audio --loop-file=inf --hwdec=auto-copy --panscan=1.0" '*' "$LIVE_VIDEO"
else
    (icarus-palette "$STATIC_IMG" &)
    exec swaybg -m fill -i "$STATIC_IMG"
fi
