#!/bin/bash

# Opens TikTok #slideshow search, scrolls grid once, taps first video,
# then keeps scrolling and liking posts using coordinate-based tapping.
# Usage: ./open_tiktok_slideshow.sh [number_of_posts]

LIKE_COUNT=${1:-20}
SCROLL_DELAY=2

devices=$(adb devices | awk 'NR>1 && $2=="device" {print $1}')

wake_device() {
    local device=$1
    # Check if screen is off
    screen=$(adb -s "$device" shell dumpsys power | grep 'Display Power' | grep -o 'state=[A-Z]*' | cut -d= -f2)
    if [ "$screen" != "ON" ]; then
        echo "[$device] Waking up screen"
        adb -s "$device" shell input keyevent KEYCODE_WAKEUP
        sleep 1
    fi
    # Swipe up to dismiss lock screen
    adb -s "$device" shell input swipe 540 1800 540 900 300
    sleep 1
}

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

    # Double-tap center-left of video to like (avoids right sidebar buttons)
    dtap_x=$((w * 35 / 100))
    dtap_y=$((h * 45 / 100))

    echo "[$device] Screen: ${w}x${h}"
    echo "[$device] Grid tap: ($grid_tap_x, $grid_tap_y) | Double-tap like: ($dtap_x, $dtap_y)"

    wake_device "$device"

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

    # Like loop — double-tap to like, swipe left side to next video
    swipe_x=$((w * 30 / 100))
    for i in $(seq 1 $LIKE_COUNT); do
        echo "[$device] Post $i/$LIKE_COUNT — double-tapping to like"
        adb -s "$device" shell input tap "$dtap_x" "$dtap_y"
        sleep 0.1
        adb -s "$device" shell input tap "$dtap_x" "$dtap_y"
        sleep $SCROLL_DELAY

        # Swipe up — left side (30%), from 40% to 10% height
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
