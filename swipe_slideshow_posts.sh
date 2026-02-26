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
    fi
    adb -s "$device" shell input swipe 540 1800 540 900 300
    sleep 1
}

dump_ui() {
    local device=$1
    adb -s "$device" shell uiautomator dump /sdcard/ui_dump.xml > /dev/null 2>&1
    adb -s "$device" shell cat /sdcard/ui_dump.xml
}

# Returns "x y" for the Videos/Posts tab, or empty if not found.
get_videos_tab_coords() {
    local device=$1
    dump_ui "$device" | python3 -c "
import sys, re
xml = sys.stdin.read()
for node in re.findall(r'<node[^>]*>', xml):
    text   = re.search(r' text=\"([^\"]+)\"', node)
    bounds = re.search(r'bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', node)
    if not text or not bounds:
        continue
    if text.group(1) in ('Videos', 'Posts'):
        x1,y1,x2,y2 = map(int, bounds.groups())
        print((x1+x2)//2, (y1+y2)//2)
        break
"
}

# Returns "x y" for the first post in the grid (roughly square clickable
# element below the tab bar), or empty if not found.
get_first_post_coords() {
    local device=$1
    dump_ui "$device" | python3 -c "
import sys, re
xml = sys.stdin.read()
candidates = []
for node in re.findall(r'<node[^>]*>', xml):
    if 'clickable=\"true\"' not in node:
        continue
    bounds = re.search(r'bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', node)
    if not bounds:
        continue
    x1,y1,x2,y2 = map(int, bounds.groups())
    w, h = x2-x1, y2-y1
    # Grid cells are roughly square (±30%), at least 100px wide, and
    # below the profile header / tab row.
    if w >= 100 and h >= 100 and abs(w-h) < max(w,h)*0.3 and y1 > 300:
        candidates.append((y1, x1, (x1+x2)//2, (y1+y2)//2))
if candidates:
    candidates.sort()
    print(candidates[0][2], candidates[0][3])
"
}

# Returns the total slide count from a visible counter like "1/5", else 0.
get_slide_count() {
    local device=$1
    dump_ui "$device" | python3 -c "
import sys, re
xml = sys.stdin.read()
m = re.search(r' text=\"(\d+)/(\d+)\"', xml)
if m:
    print(m.group(2))
else:
    print(0)
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

    echo "[$device] Finding Videos tab..."
    tab_coords=$(get_videos_tab_coords "$device")
    if [ -z "$tab_coords" ]; then
        echo "[$device] ERROR: Could not find Videos tab in UI — aborting"
        return 1
    fi
    tab_x=$(echo "$tab_coords" | awk '{print $1}')
    tab_y=$(echo "$tab_coords" | awk '{print $2}')
    echo "[$device] Tapping Videos tab at ($tab_x, $tab_y)"
    adb -s "$device" shell input tap "$tab_x" "$tab_y"
    sleep 3

    echo "[$device] Finding first post in grid..."
    post_coords=$(get_first_post_coords "$device")
    if [ -z "$post_coords" ]; then
        echo "[$device] ERROR: Could not find first post in grid — aborting"
        return 1
    fi
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
