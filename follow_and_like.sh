#!/bin/bash

# Follows a list of TikTok accounts and likes all their posts.
# Add more usernames to the ACCOUNTS array as needed.
# Usage: ./follow_and_like.sh [number_of_posts_to_like]

ACCOUNTS=(
    "userwealthrich"
)

LIKE_COUNT=${1:-30}
SCROLL_DELAY=2

devices=$(adb devices | awk 'NR>1 && $2=="device" {print $1}')

process_account() {
    local device=$1
    local username=$2

    size=$(adb -s "$device" shell wm size | grep -oE '[0-9]+x[0-9]+')
    w=$(echo "$size" | cut -dx -f1)
    h=$(echo "$size" | cut -dx -f2)
    cx=$((w / 2))

    # Like button: right side ~92% width, ~50% height
    like_x=$((w * 92 / 100))
    like_y=$((h * 50 / 100))

    # Swipe: left side (30%), from 40% to 10% height
    swipe_x=$((w * 30 / 100))
    swipe_from=$((h * 40 / 100))
    swipe_to=$((h * 10 / 100))

    echo "[$device] ── Processing @$username ──"

    # Open profile via deep link
    echo "[$device] Opening profile: @$username"
    adb -s "$device" shell am start -a android.intent.action.VIEW \
        -d "snssdk1233://user/profile?uniqueId=$username"
    sleep 4

    # Tap Follow button (center x, ~26% height — below avatar/stats, above tabs)
    follow_x=$cx
    follow_y=$((h * 26 / 100))
    echo "[$device] Tapping Follow at ($follow_x, $follow_y)"
    adb -s "$device" shell input tap "$follow_x" "$follow_y"
    sleep 2

    # Tap the Posts tab (first tab, left side of tab bar at ~34% height)
    posts_tab_x=$((w * 20 / 100))
    posts_tab_y=$((h * 34 / 100))
    echo "[$device] Tapping Posts tab at ($posts_tab_x, $posts_tab_y)"
    adb -s "$device" shell input tap "$posts_tab_x" "$posts_tab_y"
    sleep 2

    # Tap first post (top-left of grid, ~40% height)
    first_post_x=$((w / 6))
    first_post_y=$((h * 40 / 100))
    echo "[$device] Opening first post at ($first_post_x, $first_post_y)"
    adb -s "$device" shell input tap "$first_post_x" "$first_post_y"
    sleep 3

    # Like loop
    for i in $(seq 1 $LIKE_COUNT); do
        echo "[$device] @$username — liking post $i/$LIKE_COUNT"
        adb -s "$device" shell input tap "$like_x" "$like_y"
        sleep $SCROLL_DELAY

        adb -s "$device" shell input swipe $swipe_x $swipe_from $swipe_x $swipe_to 250
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
