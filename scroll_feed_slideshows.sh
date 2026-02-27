#!/bin/bash

# Scroll through the TikTok "For You" and "Following" feeds.
# Detects photo slideshows and swipes through each slide before
# liking, saving, and moving to the next post.
# Usage: ./scroll_feed_slideshows.sh [scrolls_per_feed]

SCROLLS=${1:-15}
MAX_SLIDES=5
SLIDE_PAUSE_MIN=1
SLIDE_PAUSE_MAX=3
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

is_slideshow() {
    local device=$1
    dump_ui "$device" | python3 -c "
import sys, re
xml = sys.stdin.read()
if re.search(r' text=\"Photo\"', xml):
    print('yes')
else:
    print('no')
"
}

save_post() {
    local device=$1
    local result
    result=$(dump_ui "$device" | python3 -c "
import sys, re
xml = sys.stdin.read()
for node in re.findall(r'<node[^>]*>', xml):
    desc = re.search(r'content-desc=\"([^\"]+)\"', node)
    bounds = re.search(r'bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', node)
    if not desc or not bounds:
        continue
    d = desc.group(1)
    if 'Favourites' in d or 'Favorites' in d or 'Favourite' in d:
        selected = re.search(r'selected=\"true\"', node)
        if selected or 'Remove' in d:
            print('already_saved')
        else:
            x1,y1,x2,y2 = map(int, bounds.groups())
            print((x1+x2)//2, (y1+y2)//2)
        break
")
    if [ "$result" = "already_saved" ]; then
        echo "[$device] Already saved — skipping"
    elif [ -n "$result" ]; then
        local bx by
        bx=$(echo "$result" | awk '{print $1}')
        by=$(echo "$result" | awk '{print $2}')
        echo "[$device] Saving post (tap $bx, $by)"
        adb -s "$device" shell input tap "$bx" "$by"
        sleep 1
    else
        echo "[$device] Save button not found — skipping"
    fi
}

tap_share() {
    local device=$1
    local w=$2 h=$3
    local result
    result=$(dump_ui "$device" | python3 -c "
import sys, re
xml = sys.stdin.read()
for node in re.findall(r'<node[^>]*>', xml):
    desc = re.search(r'content-desc=\"([^\"]+)\"', node)
    bounds = re.search(r'bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', node)
    if not desc or not bounds:
        continue
    d = desc.group(1)
    if 'Share' in d or 'share' in d:
        x1,y1,x2,y2 = map(int, bounds.groups())
        print((x1+x2)//2, (y1+y2)//2)
        break
")
    if [ -n "$result" ]; then
        local sx sy
        sx=$(echo "$result" | awk '{print $1}')
        sy=$(echo "$result" | awk '{print $2}')
        echo "[$device] Tapping Share at ($sx, $sy)"
        adb -s "$device" shell input tap "$sx" "$sy"
        sleep 1
        # Tap upper half of screen to dismiss share sheet
        local dismiss_y=$((h * 20 / 100))
        echo "[$device] Dismissing share sheet"
        adb -s "$device" shell input tap "$((w / 2))" "$dismiss_y"
        sleep 1
    else
        echo "[$device] Share button not found — skipping"
    fi
}

rand_sleep() {
    local lo=$1 hi=$2
    sleep $(( RANDOM % (hi - lo + 1) + lo ))
}

# Scroll through whichever feed is currently active.
scroll_feed() {
    local device=$1
    local feed_name=$2
    local w=$3 h=$4 cx=$5 cy=$6

    local dtap_x=$((w * 35 / 100))
    local dtap_y=$((h * 45 / 100))
    local slide_start_x=$((w * 80 / 100))
    local slide_end_x=$((w * 20 / 100))
    local swipe_from=$((h * 40 / 100))
    local swipe_to=$((h * 10 / 100))

    for i in $(seq 1 "$SCROLLS"); do
        echo "[$device] ── $feed_name $i/$SCROLLS ──"

        slideshow=$(is_slideshow "$device")

        if [ "$slideshow" = "yes" ]; then
            echo "[$device] Slideshow detected — swiping through up to $MAX_SLIDES slides"
            rand_sleep $SLIDE_PAUSE_MIN $SLIDE_PAUSE_MAX
            for s in $(seq 2 "$MAX_SLIDES"); do
                echo "[$device]   → Slide $s"
                adb -s "$device" shell input swipe \
                    "$slide_start_x" "$cy" "$slide_end_x" "$cy" 250
                sleep 1
                rand_sleep $SLIDE_PAUSE_MIN $SLIDE_PAUSE_MAX
            done

            echo "[$device] Liking"
            adb -s "$device" shell input tap "$dtap_x" "$dtap_y"
            sleep 0.1
            adb -s "$device" shell input tap "$dtap_x" "$dtap_y"
            sleep 1

            save_post "$device"

            tap_share "$device" "$w" "$h"

            adb -s "$device" shell input swipe "$cx" "$swipe_from" "$cx" "$swipe_to" 250
            sleep 1
        else
            echo "[$device] Video — skipping"
            adb -s "$device" shell input swipe "$cx" "$swipe_from" "$cx" "$swipe_to" 150
            sleep 0.1
        fi
    done
}

run_on_device() {
    local device=$1

    size=$(adb -s "$device" shell wm size | grep -oE '[0-9]+x[0-9]+')
    w=$(echo "$size" | cut -dx -f1)
    h=$(echo "$size" | cut -dx -f2)
    cx=$((w / 2))
    cy=$((h / 2))

    echo "[$device] Screen: ${w}x${h}"
    wake_device "$device"

    # --- For You feed (TikTok opens here by default) ---
    echo "[$device] ═══ For You feed ═══"
    adb -s "$device" shell am start -a android.intent.action.VIEW \
        -d "snssdk1233://feed?refer=web" > /dev/null 2>&1
    sleep 4
    scroll_feed "$device" "For You" "$w" "$h" "$cx" "$cy"

    # --- Following feed (swipe right on the top bar to switch from FYP) ---
    echo "[$device] ═══ Following feed ═══"
    local top_y=$((h * 5 / 100))
    adb -s "$device" shell input swipe "$((w * 70 / 100))" "$top_y" "$((w * 20 / 100))" "$top_y" 300
    sleep 3
    scroll_feed "$device" "Following" "$w" "$h" "$cx" "$cy"

    echo "[$device] All feeds done"
}

for device in $devices; do
    run_on_device "$device" &
done

wait
echo "All devices done"
