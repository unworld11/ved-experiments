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

    # TikTok like button: right side of screen (~92% width), ~60% height
    like_x=$((w * 92 / 100))
    like_y=$((h * 60 / 100))

    echo "[$device] Screen: ${w}x${h} — Like button at ($like_x, $like_y)"

    echo "[$device] Opening TikTok #slideshow search"
    adb -s "$device" shell am start -a android.intent.action.VIEW \
        -d "snssdk1233://search?keyword=%23slideshow"
    sleep 4

    # Scroll once in the grid
    echo "[$device] Scrolling grid once"
    adb -s "$device" shell input swipe $cx $((h * 3 / 4)) $cx $((h / 4)) 400
    sleep 2

    # Tap first video (top-left cell of the grid)
    tap_x=$((w / 6))
    tap_y=$((h / 4))
    echo "[$device] Tapping first grid item at ($tap_x, $tap_y)"
    adb -s "$device" shell input tap $tap_x $tap_y
    sleep 3

    # Like loop
    for i in $(seq 1 $LIKE_COUNT); do
        echo "[$device] Post $i/$LIKE_COUNT — liking at ($like_x, $like_y)"
        adb -s "$device" shell input tap "$like_x" "$like_y"
        sleep $SCROLL_DELAY

        # Swipe up to next video
        adb -s "$device" shell input swipe $cx $((h * 3 / 4)) $cx $((h / 4)) 400
        sleep $SCROLL_DELAY
    done

    echo "[$device] Done — liked $LIKE_COUNT posts"
}

for device in $devices; do
    run_on_device "$device" &
done

wait
echo "All devices done"
