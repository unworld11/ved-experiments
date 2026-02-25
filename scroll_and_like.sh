#!/bin/bash

# Opens each TikTok account's profile, scrolls through their posts,
# and likes each one by double-tapping the centre of the screen.
# Usage: ./scroll_and_like.sh [number_of_posts_to_like]

ACCOUNTS=(
    "gamingarb01"
    "evan_argy"
    "aelus.12"
    "waste.collector"
    "mr._.javiidon"
)

LIKE_COUNT=${1:-5}
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

process_account() {
    local device=$1
    local username=$2

    size=$(adb -s "$device" shell wm size | grep -oE '[0-9]+x[0-9]+')
    w=$(echo "$size" | cut -dx -f1)
    h=$(echo "$size" | cut -dx -f2)

    # Centre of screen for double-tap to like
    cx=$((w / 2))
    cy=$((h / 2))

    # Posts/Videos tab: center of [45,226][375,339]
    posts_tab_x=210
    posts_tab_y=282

    # First post: left column center
    first_post_x=185
    first_post_y=455

    # Swipe up to go to next post
    swipe_x=$((w / 2))
    swipe_from=$((h * 40 / 100))
    swipe_to=$((h * 10 / 100))

    echo "[$device] ── Processing @$username ──"
    wake_device "$device"

    # Open profile
    echo "[$device] Opening profile: @$username"
    adb -s "$device" shell am start -a android.intent.action.VIEW \
        -d "https://www.tiktok.com/@$username"
    sleep 4

    # Tap Posts/Videos tab
    echo "[$device] Tapping Posts tab"
    adb -s "$device" shell input tap "$posts_tab_x" "$posts_tab_y"
    sleep 2

    # Tap first post to open video player
    echo "[$device] Opening first post"
    adb -s "$device" shell input tap "$first_post_x" "$first_post_y"
    sleep 3

    # Like loop — double-tap centre to like, swipe up to next post
    for i in $(seq 1 $LIKE_COUNT); do
        echo "[$device] @$username — liking post $i/$LIKE_COUNT"
        adb -s "$device" shell input tap "$cx" "$cy"
        sleep 0.1
        adb -s "$device" shell input tap "$cx" "$cy"
        sleep $SCROLL_DELAY

        adb -s "$device" shell input swipe "$swipe_x" "$swipe_from" "$swipe_x" "$swipe_to" 250
        sleep $SCROLL_DELAY
    done

    echo "[$device] Done with @$username"
}

run_on_device() {
    local device=$1
    for username in "${ACCOUNTS[@]}"; do
        process_account "$device" "$username"
        sleep 2
    done
}

for device in $devices; do
    run_on_device "$device" &
done

wait
echo "All devices done"
