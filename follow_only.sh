#!/bin/bash

# Follows a list of TikTok accounts without liking or scrolling their posts.
# ACCOUNTS: @usernames — opens profile page directly then follows.
# URLS: short/video/photo links — opens URL in TikTok app then follows.
# Usage: ./follow_only.sh

ACCOUNTS=(
    "evan_argy"
    "aelus.12"
    "waste.collector"
    "mr._.javiidon"
)

# Portugal Content — short video/share links
URLS=(
    # uncomment after confirming the follow works on ACCOUNTS above
    # "https://www.tiktok.com/t/ZP89aueBj/"
    # "https://www.tiktok.com/t/ZP89ak3q1/"
    # "https://www.tiktok.com/t/ZP89auXon/"
    # "https://www.tiktok.com/t/ZP89aU8vt/"
    # "https://www.tiktok.com/t/ZP89aaPek/"
    # "https://www.tiktok.com/t/ZP89a4aRB/"
    # "https://www.tiktok.com/t/ZP89ahV8T/"
    # "https://www.tiktok.com/t/ZP897pr6e/"
    # "https://www.tiktok.com/t/ZP897W7SW/"
    # "https://www.tiktok.com/t/ZP897gj7b/"
    # "https://www.tiktok.com/t/ZP897GAnf/"
    # "https://www.tiktok.com/t/ZP897pqNb/"
    # "https://www.tiktok.com/t/ZP897Wcyf/"
    # "https://www.tiktok.com/t/ZP897mfFQ/"
    # "https://www.tiktok.com/t/ZP897b126/"
    # "https://www.tiktok.com/t/ZTh9gbWJ5/"
    # "https://www.tiktok.com/t/ZTh9gpf7b/"
    # "https://www.tiktok.com/t/ZTh9pjXUU/"
    # "https://www.tiktok.com/t/ZTh9pAHV3/"
    # "https://www.tiktok.com/t/ZTh9pFHCh/"
    # "https://www.tiktok.com/t/ZTh9p2d9k/"
    # "https://www.tiktok.com/t/ZTh9p6aJr/"
    # "https://www.tiktok.com/t/ZTh9pSNvU/"
    # "https://www.tiktok.com/t/ZTh9pmx4P/"
    # "https://www.tiktok.com/t/ZTh9pSBw8/"
    # "https://www.tiktok.com/t/ZTh9pMbmd/"
    # "https://www.tiktok.com/t/ZTh9pFkCS/"
    # "https://www.tiktok.com/t/ZTh9pAdAK/"
    # "https://www.tiktok.com/t/ZTh9pyueC/"
    # "https://www.tiktok.com/t/ZTh9p9jQ4/"
    # "https://www.tiktok.com/t/ZTh9pSyy9/"
    # "https://www.tiktok.com/t/ZTh9sssa3/"
)

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

is_already_following() {
    local device=$1
    adb -s "$device" shell uiautomator dump /sdcard/ui_dump.xml > /dev/null 2>&1
    adb -s "$device" shell cat /sdcard/ui_dump.xml | python3 -c "
import sys, re
xml = sys.stdin.read()
# 'Subscription' = not yet following. 'Following'/'Friends'/'Subscribed' = already following.
if re.search(r'\b(Following|Friends|Subscribed)\b', xml, re.IGNORECASE):
    print('yes')
else:
    print('no')
"
}

# Finds the Follow button via UI dump and prints its center coordinates.
# Returns empty string if not found or already following.
get_follow_button_coords() {
    local device=$1
    adb -s "$device" shell uiautomator dump /sdcard/ui_dump.xml > /dev/null 2>&1
    adb -s "$device" shell cat /sdcard/ui_dump.xml | python3 -c "
import sys, re
xml = sys.stdin.read()
for node in re.findall(r'<node[^>]*>', xml):
    desc  = re.search(r'content-desc=\"([^\"]+)\"', node)
    text  = re.search(r' text=\"([^\"]+)\"', node)
    bounds = re.search(r'bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', node)
    if not bounds:
        continue
    t = text.group(1) if text else ''
    # The profile stats row (following / followers / likes) shows as plain numbers.
    # The follow button is ~1cm (150px) below the bottom of that stats row.
    # This puts it well below the profile-photo overlay (id=o2p y=80-226).
    if re.match(r'^\d+[KMBkmb]?$', t):
        x1, y1, x2, y2 = map(int, bounds.groups())
        follow_y = y2 + 150   # ~1cm below the stats numbers
        follow_x = 540 - 150  # ~1cm left of center
        print(f'{follow_x} {follow_y}')
        break
"
}

dump_ui_elements() {
    local device=$1
    echo "[$device] === UI DUMP ==="
    adb -s "$device" shell uiautomator dump /sdcard/ui_dump.xml > /dev/null 2>&1
    adb -s "$device" shell cat /sdcard/ui_dump.xml | python3 -c "
import sys, re
xml = sys.stdin.read()
print(f'Total XML length: {len(xml)} chars')
print('--- ELEMENTS WITH TEXT/DESC OR CLICKABLE ---')
for node in re.findall(r'<node[^>]*>', xml):
    desc    = re.search(r'content-desc=\"([^\"]+)\"', node)
    text    = re.search(r' text=\"([^\"]+)\"', node)
    cls     = re.search(r'class=\"([^\"]+)\"', node)
    rid     = re.search(r'resource-id=\"([^\"]+)\"', node)
    clk     = re.search(r'clickable=\"(true|false)\"', node)
    bounds  = re.search(r'bounds=\"([^\"]+)\"', node)
    d = desc.group(1) if desc else ''
    t = text.group(1) if text else ''
    c = cls.group(1).split('.')[-1] if cls else ''
    r = rid.group(1).split('/')[-1] if rid else ''
    k = clk.group(1) if clk else '?'
    b = bounds.group(1) if bounds else ''
    if d or t or k == 'true':
        print(f'  {c:<22} id={r:<30} clk={k} desc={d:<35} text={t:<25} {b}')
"
    echo "[$device] === END UI DUMP ==="
}

follow_only_account() {
    local device=$1
    local username=$2

    echo "[$device] ── Following @$username ──"
    wake_device "$device"

    adb -s "$device" shell am start -a android.intent.action.VIEW \
        -d "https://www.tiktok.com/@$username"
    sleep 4

    dump_ui_elements "$device"

    already=$(is_already_following "$device")
    if [ "$already" = "yes" ]; then
        echo "[$device] Already following @$username — skipping"
    else
        coords=$(get_follow_button_coords "$device")
        if [ -n "$coords" ]; then
            x=$(echo "$coords" | awk '{print $1}')
            y=$(echo "$coords" | awk '{print $2}')
            echo "[$device] Tapping Follow at ($x, $y)"
            adb -s "$device" shell input tap "$x" "$y"
            sleep 2
        else
            echo "[$device] Follow button not found for @$username"
        fi
    fi
    echo "[$device] Done with @$username"
}

follow_from_url() {
    local device=$1
    local url=$2

    echo "[$device] ── Following from URL: $url ──"
    wake_device "$device"

    adb -s "$device" shell am start -a android.intent.action.VIEW -d "$url"
    sleep 5  # extra wait for video/redirect to load

    already=$(is_already_following "$device")
    if [ "$already" = "yes" ]; then
        echo "[$device] Already following — skipping"
    else
        coords=$(get_follow_button_coords "$device")
        if [ -n "$coords" ]; then
            x=$(echo "$coords" | awk '{print $1}')
            y=$(echo "$coords" | awk '{print $2}')
            echo "[$device] Tapping Follow at ($x, $y)"
            adb -s "$device" shell input tap "$x" "$y"
            sleep 2
        else
            echo "[$device] Follow button not found for $url"
        fi
    fi
    echo "[$device] Done with $url"
}

run_on_device() {
    local device=$1
    for username in "${ACCOUNTS[@]}"; do
        follow_only_account "$device" "$username"
        sleep 2
    done
    for url in "${URLS[@]}"; do
        follow_from_url "$device" "$url"
        sleep 2
    done
}

for device in $devices; do
    run_on_device "$device" &
done

wait
echo "All devices done"
