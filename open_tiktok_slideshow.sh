#!/bin/bash

# Opens TikTok #slideshow search, scrolls grid once, taps first video,
# then keeps scrolling and liking posts using coordinate-based tapping.
# Usage: ./open_tiktok_slideshow.sh [number_of_posts]

LIKE_COUNT=${1:-20}
SCROLL_DELAY=2

devices=$(adb devices | awk 'NR>1 && $2=="device" {print $1}')

run_on_device() {
    local device=$1

    size=$(adb -s "$device" shell wm size | grep -oE '[0-9]+x[0-9]+')
    w=$(echo "$size" | cut -dx -f1)
    h=$(echo "$size" | cut -dx -f2)
    cx=$((w / 2))
    cy=$((h / 2))

    # Grid: 2 columns. Left cell center x = (11+535)/2 = 273, y = (471+1546)/2 = 1008
    grid_tap_x=273
    grid_tap_y=1008

    # TikTok video player like button: right side ~92% width, ~50% height
    # Comment button is at ~60%, so stay well above it
    like_x=$((w * 92 / 100))
    like_y=$((h * 50 / 100))

    echo "[$device] Screen: ${w}x${h}"
    echo "[$device] Grid tap: ($grid_tap_x, $grid_tap_y) | Like tap: ($like_x, $like_y)"

    echo "[$device] Opening TikTok #slideshow search"
    adb -s "$device" shell am start -a android.intent.action.VIEW \
        -d "snssdk1233://search?keyword=%23slideshow"
    sleep 4

    # Scroll once in the grid
    echo "[$device] Scrolling grid once"
    adb -s "$device" shell input swipe $cx $((h * 3 / 4)) $cx $((h / 4)) 600
    sleep 2

    # Tap center of first grid cell to open video
    echo "[$device] Tapping grid cell at ($grid_tap_x, $grid_tap_y)"
    adb -s "$device" shell input tap $grid_tap_x $grid_tap_y
    sleep 3

    # Like loop
    for i in $(seq 1 $LIKE_COUNT); do
        echo "[$device] Post $i/$LIKE_COUNT — tapping like at ($like_x, $like_y)"
        adb -s "$device" shell input tap "$like_x" "$like_y"
        sleep $SCROLL_DELAY

        # Swipe up to next video — left side (30%), start at 40% height (above comment zone)
        swipe_x=$((w * 30 / 100))
        adb -s "$device" shell input swipe $swipe_x $((h * 40 / 100)) $swipe_x $((h * 10 / 100)) 250
        sleep $SCROLL_DELAY
    done

    echo "[$device] Done — $LIKE_COUNT posts processed"
}

for device in $devices; do
    run_on_device "$device" &
done

wait
echo "All devices done"
