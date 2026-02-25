#!/bin/bash

# Follows a list of TikTok accounts and likes all their posts.
# Add more usernames to the ACCOUNTS array as needed.
# Usage: ./follow_and_like.sh [number_of_posts_to_like]

ACCOUNTS=(
    "userwealthrich"
)

LIKE_COUNT=${1:-5}
SCROLL_DELAY=2

devices=$(adb devices | awk 'NR>1 && $2=="device" {print $1}')

dump_ui() {
    local device=$1
    local label=$2
    echo "[$device] === UI DUMP ($label) ==="
    adb -s "$device" shell uiautomator dump /sdcard/ui_dump.xml > /dev/null 2>&1
    adb -s "$device" shell cat /sdcard/ui_dump.xml | python3 -c "
import sys, re
xml = sys.stdin.read()
print(f'xml length: {len(xml)} chars')
for n in re.findall(r'<node[^>]*>', xml):
    cls  = re.search(r'class=\"([^\"]+)\"', n)
    desc = re.search(r'content-desc=\"([^\"]+)\"', n)
    text = re.search(r' text=\"([^\"]+)\"', n)
    clk  = re.search(r'clickable=\"(true|false)\"', n)
    bnd  = re.search(r'bounds=\"([^\"]+)\"', n)
    if cls and bnd:
        d = desc.group(1) if desc else ''
        t = text.group(1) if text else ''
        if d or t:
            print(f'  {cls.group(1).split(\".\")[-1]:<20} desc={d:<35} text={t:<25} click={clk.group(1) if clk else \"?\"} bounds={bnd.group(1)}')
"
    echo "[$device] === END UI DUMP ==="
}

is_already_following() {
    local device=$1
    # Check if follow button says Following/Friends/Subscribed (already followed)
    adb -s "$device" shell uiautomator dump /sdcard/ui_dump.xml > /dev/null 2>&1
    adb -s "$device" shell cat /sdcard/ui_dump.xml | python3 -c "
import sys, re
xml = sys.stdin.read()
# Look for Following/Friends/Subscribed state in any element
if re.search(r'(Following|Friends|Subscribed)', xml, re.IGNORECASE):
    print('yes')
else:
    print('no')
"
}

process_account() {
    local device=$1
    local username=$2

    size=$(adb -s "$device" shell wm size | grep -oE '[0-9]+x[0-9]+')
    w=$(echo "$size" | cut -dx -f1)
    h=$(echo "$size" | cut -dx -f2)
    cx=$((w / 2))

    # Coordinates from UI dump
    # Follow button area: center of Subscription element
    follow_x=540
    follow_y=166

    # Posts/Videos tab: center of [45,226][375,339]
    posts_tab_x=210
    posts_tab_y=282

    # First post: left column center x=185, first row center y=455
    first_post_x=185
    first_post_y=455

    # Double-tap to like: center-left of video
    dtap_x=$((w * 35 / 100))
    dtap_y=$((h * 45 / 100))

    # Swipe: left side (30%), from 40% to 10%
    swipe_x=$((w * 30 / 100))
    swipe_from=$((h * 40 / 100))
    swipe_to=$((h * 10 / 100))

    echo "[$device] ── Processing @$username ──"

    # Open profile
    echo "[$device] Opening profile: @$username"
    adb -s "$device" shell am start -a android.intent.action.VIEW \
        -d "https://www.tiktok.com/@$username"
    sleep 4

    # Follow only if not already following
    already=$(is_already_following "$device")
    if [ "$already" = "yes" ]; then
        echo "[$device] Already following @$username — skipping Follow tap"
    else
        echo "[$device] Tapping Follow at ($follow_x, $follow_y)"
        adb -s "$device" shell input tap "$follow_x" "$follow_y"
        sleep 2
    fi

    # Tap Posts/Videos tab
    echo "[$device] Tapping Posts tab at ($posts_tab_x, $posts_tab_y)"
    adb -s "$device" shell input tap "$posts_tab_x" "$posts_tab_y"
    sleep 2

    # Tap first post
    echo "[$device] Opening first post at ($first_post_x, $first_post_y)"
    adb -s "$device" shell input tap "$first_post_x" "$first_post_y"
    sleep 3

    # Like loop — double-tap to like, swipe to next
    for i in $(seq 1 $LIKE_COUNT); do
        echo "[$device] @$username — double-tapping to like post $i/$LIKE_COUNT"
        adb -s "$device" shell input tap "$dtap_x" "$dtap_y"
        sleep 0.1
        adb -s "$device" shell input tap "$dtap_x" "$dtap_y"
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
