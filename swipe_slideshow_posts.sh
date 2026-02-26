#!/bin/bash

# Go to @gamingarb01's profile, open their posts, and for any that are
# photo slideshows swipe through each slide before liking and moving on.
# Usage: ./swipe_slideshow_posts.sh [number_of_posts]

ACCOUNT="gamingarb01"
POST_COUNT=${1:-10}
SLIDE_PAUSE_MIN=1   # min seconds to spend reading each slide
SLIDE_PAUSE_MAX=3   # max seconds to spend reading each slide
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

# Dump the current UI hierarchy and return the total slide count if a
# slideshow counter (e.g. "1/5") is visible, otherwise echoes 0.
get_slide_count() {
    local device=$1
    local raw
    raw=$(adb -s "$device" shell uiautomator dump /dev/tty 2>/dev/null)
    # Counter appears as  text="1/5"  in the XML
    local total
    total=$(echo "$raw" | grep -oE 'text="[0-9]+/[0-9]+"' | head -1 | grep -oE '[0-9]+/[0-9]+' | cut -d/ -f2)
    echo "${total:-0}"
}

rand_sleep() {
    local lo=$1
    local hi=$2
    local span=$(( hi - lo + 1 ))
    sleep $(( RANDOM % span + lo ))
}

run_on_device() {
    local device=$1

    size=$(adb -s "$device" shell wm size | grep -oE '[0-9]+x[0-9]+')
    w=$(echo "$size" | cut -dx -f1)
    h=$(echo "$size" | cut -dx -f2)
    cx=$((w / 2))
    cy=$((h / 2))

    # Coordinates for the Posts/Videos tab (matches scroll_and_like.sh)
    posts_tab_x=210
    posts_tab_y=282

    # First post in the grid — left column centre
    first_post_x=185
    first_post_y=455

    # Double-tap target (centre-left, avoids sidebar buttons)
    dtap_x=$((w * 35 / 100))
    dtap_y=$((h * 45 / 100))

    # Swipe-left endpoints for advancing slides
    slide_start_x=$((w * 80 / 100))
    slide_end_x=$((w * 20 / 100))

    # Swipe-up endpoints for moving to the next post
    next_post_from=$((h * 40 / 100))
    next_post_to=$((h * 10 / 100))

    echo "[$device] Screen: ${w}x${h}"
    wake_device "$device"

    echo "[$device] Opening @$ACCOUNT"
    adb -s "$device" shell am start -a android.intent.action.VIEW \
        -d "https://www.tiktok.com/@$ACCOUNT"
    sleep 4

    echo "[$device] Tapping Posts tab"
    adb -s "$device" shell input tap "$posts_tab_x" "$posts_tab_y"
    sleep 2

    echo "[$device] Opening first post"
    adb -s "$device" shell input tap "$first_post_x" "$first_post_y"
    sleep 3

    for i in $(seq 1 "$POST_COUNT"); do
        echo "[$device] ── Post $i/$POST_COUNT ──"
        sleep 1

        slide_count=$(get_slide_count "$device")

        if [ "$slide_count" -gt 1 ] 2>/dev/null; then
            echo "[$device] Slideshow — $slide_count slides"
            # Already viewing slide 1; pause, then swipe through the rest
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

        # Double-tap to like
        echo "[$device] Liking"
        adb -s "$device" shell input tap "$dtap_x" "$dtap_y"
        sleep 0.1
        adb -s "$device" shell input tap "$dtap_x" "$dtap_y"
        sleep $SCROLL_DELAY

        # Swipe up to next post
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
