#!/bin/bash

# Opens TikTok on all connected Android devices, searches #slideshow,
# and likes all posts in the feed.
# Usage: ./open_tiktok_slideshow.sh [number_of_posts]

LIKE_COUNT=${1:-20}
SCROLL_DELAY=2

devices=$(adb devices | awk 'NR>1 && $2=="device" {print $1}')

# Get center coordinates of the Like button via uiautomator dump
get_like_coords() {
    local device=$1
    adb -s "$device" shell uiautomator dump /dev/stdout 2>/dev/null | \
    python3 -c "
import sys, re
xml = sys.stdin.read()
m = re.search(r'content-desc=\"Like\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', xml) or \
    re.search(r'bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"[^>]*content-desc=\"Like\"', xml)
if m:
    x1,y1,x2,y2 = map(int, m.groups())
    print(f'{(x1+x2)//2} {(y1+y2)//2}')
"
}

run_on_device() {
    local device=$1

    # Get screen dimensions
    size=$(adb -s "$device" shell wm size | grep -oE '[0-9]+x[0-9]+')
    w=$(echo "$size" | cut -dx -f1)
    h=$(echo "$size" | cut -dx -f2)
    cx=$((w / 2))
    cy=$((h / 2))

    echo "[$device] Opening TikTok #slideshow search"
    adb -s "$device" shell am start -a android.intent.action.VIEW \
        -d "snssdk1233://search?keyword=%23slideshow"
    sleep 4

    # Tap into the first video from search grid
    echo "[$device] Opening first video"
    adb -s "$device" shell input tap $cx $((h / 3))
    sleep 2

    for i in $(seq 1 $LIKE_COUNT); do
        echo "[$device] Liking post $i/$LIKE_COUNT"

        coords=$(get_like_coords "$device")

        if [ -n "$coords" ]; then
            lx=$(echo "$coords" | awk '{print $1}')
            ly=$(echo "$coords" | awk '{print $2}')
            echo "[$device] Tapping Like at ($lx, $ly)"
            adb -s "$device" shell input tap "$lx" "$ly"
        else
            echo "[$device] Like button not found, skipping"
        fi

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
