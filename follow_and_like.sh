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

process_account() {
    local device=$1
    local username=$2

    echo "[$device] ── Opening profile: @$username ──"
    adb -s "$device" shell am start -a android.intent.action.VIEW \
        -d "https://www.tiktok.com/@$username"
    sleep 4

    dump_ui "$device" "profile page"
}

run_on_device() {
    local device=$1
    for username in "${ACCOUNTS[@]}"; do
        process_account "$device" "$username"
    done
}

for device in $devices; do
    run_on_device "$device" &
done

wait
echo "All devices done"
