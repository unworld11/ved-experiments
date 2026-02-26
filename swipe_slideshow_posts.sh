#!/bin/bash

# Go to @gamingarb01's profile, open their posts, and for any that are
# photo slideshows swipe through each slide before liking and moving on.
# Uses uiautomator dump + Python to locate UI elements dynamically
# (no hardcoded screen coords) so it works across device sizes.
# Usage: ./swipe_slideshow_posts.sh [number_of_posts]

ACCOUNT="gamingarb01"
POST_COUNT=${1:-10}
SLIDE_PAUSE_MIN=1   # min seconds per slide
SLIDE_PAUSE_MAX=3   # max seconds per slide
SCROLL_DELAY=2

devices=$(adb devices | awk 'NR>1 && $2=="device" {print $1}')

wake_device() {
    local device=$1
    screen=$(adb -s "$device" shell dumpsys power | grep 'Display Power' | grep -o 'state=[A-Z]*' | cut -d= -f2)
    if [ "$screen" != "ON" ]; then
        echo "[$device] Waking up screen"
        adb -s "$device" shell input keyevent KEYCODE_WAKEUP
        sleep 1
        adb -s "$device" shell input swipe 540 1800 540 900 300
        sleep 1
    fi
}

dump_ui() {
    local device=$1
    adb -s "$device" shell uiautomator dump /sdcard/ui_dump.xml > /dev/null 2>&1
    adb -s "$device" shell cat /sdcard/ui_dump.xml
}

# Returns "x y" for the first post thumbnail in the grid.
# Looks for the topmost roughly-square image in the bottom half of the screen.
# Falls back to w/6, h*0.6 if nothing is found.
get_first_post_coords() {
    local device=$1
    local sw=$2   # screen width
    local sh=$3   # screen height
    dump_ui "$device" | python3 -c "
import sys, re
xml = sys.stdin.read()
sw, sh = $sw, $sh
half_y = sh // 2
candidates = []
for node in re.findall(r'<node[^>]*>', xml):
    bounds = re.search(r'bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', node)
    if not bounds:
        continue
    x1,y1,x2,y2 = map(int, bounds.groups())
    bw, bh = x2-x1, y2-y1
    # Grid thumbnails are roughly square, >= 80px, in the bottom half
    if bw >= 80 and bh >= 80 and abs(bw-bh) < max(bw,bh)*0.4 and y1 >= half_y:
        candidates.append((y1, x1, (x1+x2)//2, (y1+y2)//2))
if candidates:
    candidates.sort()
    print(candidates[0][2], candidates[0][3])
else:
    # Fallback: first column centre, 60% down the screen
    print(sw//6, int(sh*0.60))
"
}

# Returns the total slide count from a visible counter like "1/5", else 0.
# Also prints any text/content-desc values found for debugging.
get_slide_count() {
    local device=$1
    dump_ui "$device" | python3 -c "
import sys, re
xml = sys.stdin.read()

# Check both text and content-desc for a slide counter (e.g. '1/5', '2 / 10')
counter = re.search(r'(?:text|content-desc)=\"(\d+)\s*/\s*(\d+)\"', xml)
if counter:
    print(counter.group(2))
    sys.exit()

# Dump all visible text/content-desc for debugging
texts = re.findall(r' text=\"([^\"]+)\"', xml)
descs = re.findall(r'content-desc=\"([^\"]+)\"', xml)
print(0)
print('DEBUG texts:', texts[:30], file=sys.stderr)
print('DEBUG descs:', descs[:30], file=sys.stderr)
"
}

rand_sleep() {
    local lo=$1 hi=$2
    sleep $(( RANDOM % (hi - lo + 1) + lo ))
}

run_on_device() {
    local device=$1

    size=$(adb -s "$device" shell wm size | grep -oE '[0-9]+x[0-9]+')
    w=$(echo "$size" | cut -dx -f1)
    h=$(echo "$size" | cut -dx -f2)
    cx=$((w / 2))
    cy=$((h / 2))

    # Double-tap target — centre-left to avoid sidebar like/share buttons
    dtap_x=$((w * 35 / 100))
    dtap_y=$((h * 45 / 100))

    # Swipe-left for advancing slides (right→left)
    slide_start_x=$((w * 80 / 100))
    slide_end_x=$((w * 20 / 100))

    # Swipe-up for moving to next post
    next_post_from=$((h * 40 / 100))
    next_post_to=$((h * 10 / 100))

    echo "[$device] Screen: ${w}x${h}"
    wake_device "$device"

    echo "[$device] Opening @$ACCOUNT"
    adb -s "$device" shell am start -a android.intent.action.VIEW \
        -d "https://www.tiktok.com/@$ACCOUNT"
    sleep 5

    echo "[$device] Finding first post in grid..."
    post_coords=$(get_first_post_coords "$device" "$w" "$h")
    post_x=$(echo "$post_coords" | awk '{print $1}')
    post_y=$(echo "$post_coords" | awk '{print $2}')
    echo "[$device] Tapping first post at ($post_x, $post_y)"
    adb -s "$device" shell input tap "$post_x" "$post_y"
    sleep 3

    for i in $(seq 1 "$POST_COUNT"); do
        echo "[$device] ── Post $i/$POST_COUNT ──"
        sleep 1

        slide_count=$(get_slide_count "$device")

        if [ "$slide_count" -gt 1 ] 2>/dev/null; then
            echo "[$device] Slideshow — $slide_count slides"
            rand_sleep $SLIDE_PAUSE_MIN $SLIDE_PAUSE_MAX
            for s in $(seq 2 "$slide_count"); do
                echo "[$device]   → Slide $s/$slide_count"
                adb -s "$device" shell input swipe \
                    "$slide_start_x" "$cy" "$slide_end_x" "$cy" 250
                sleep 1
                rand_sleep $SLIDE_PAUSE_MIN $SLIDE_PAUSE_MAX
            done
        else
            echo "[$device] Regular video — watching"
            sleep $SCROLL_DELAY
        fi

        echo "[$device] Liking"
        adb -s "$device" shell input tap "$dtap_x" "$dtap_y"
        sleep 0.1
        adb -s "$device" shell input tap "$dtap_x" "$dtap_y"
        sleep $SCROLL_DELAY

        echo "[$device] Next post"
        adb -s "$device" shell input swipe "$cx" "$next_post_from" "$cx" "$next_post_to" 250
        sleep $SCROLL_DELAY
    done

    echo "[$device] Done — $POST_COUNT posts processed for @$ACCOUNT"
}

for device in $devices; do
    run_on_device "$device" &
done

wait
echo "All devices done"
