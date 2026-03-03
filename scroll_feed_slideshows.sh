#!/bin/bash

# Scroll through the TikTok feed.
# Detects photo slideshows and swipes through each slide before
# liking, saving, and moving to the next post.
# Usage: ./scroll_feed_slideshows.sh [num_posts]

SCROLLS=${1:-15}
MAX_SLIDES=5

TARGET_DEVICE="RRCX800HQ2V"
devices=$(adb devices | awk 'NR>1 && $2=="device" {print $1}' | grep "$TARGET_DEVICE")

wake_device() {
    local device=$1 w=$2 h=$3
    screen=$(adb -s "$device" shell dumpsys power | grep 'Display Power' | grep -o 'state=[A-Z]*' | cut -d= -f2)
    if [ "$screen" != "ON" ]; then
        echo "[$device] Waking up screen"
        adb -s "$device" shell input keyevent KEYCODE_WAKEUP
        sleep 1
        adb -s "$device" shell input swipe "$((w/2))" "$((h*80/100))" "$((w/2))" "$((h*40/100))" 300
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
if re.search(r'(?:text|content-desc)=\"Photo\"', xml):
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
        sleep 1.5
        # Try to read post URL directly from share sheet UI (any attribute)
        local url
        url=$(dump_ui "$device" | python3 -c "
import sys, re
xml = sys.stdin.read()
m = re.search(r'\"(https?://[^\"]*tiktok[^\"]+)\"', xml)
if m:
    print(m.group(1))
" 2>/dev/null)
        if [ -z "$url" ]; then
            # Fall back: tap Copy link, then read clipboard
            local cl_result
            cl_result=$(dump_ui "$device" | python3 -c "
import sys, re
xml = sys.stdin.read()
for node in re.findall(r'<node[^>]*>', xml):
    desc = re.search(r'content-desc=\"([^\"]+)\"', node)
    text_m = re.search(r' text=\"([^\"]+)\"', node)
    bounds = re.search(r'bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', node)
    if not bounds:
        continue
    d = (desc.group(1) if desc else '') + ' ' + (text_m.group(1) if text_m else '')
    if re.search(r'[Cc]opy.{0,5}[Ll]ink', d):
        x1,y1,x2,y2 = map(int, bounds.groups())
        print((x1+x2)//2, (y1+y2)//2)
        break
" 2>/dev/null)
            if [ -n "$cl_result" ]; then
                local clx cly
                clx=$(echo "$cl_result" | awk '{print $1}')
                cly=$(echo "$cl_result" | awk '{print $2}')
                adb -s "$device" shell input tap "$clx" "$cly"
                sleep 1
                # Try cmd clipboard first (Android 10+), fall back to dumpsys
                url=$(adb -s "$device" shell cmd clipboard get-text 2>/dev/null | python3 -c "
import sys, re
m = re.search(r'https?://\S*tiktok\S*', sys.stdin.read())
if m: print(m.group())
" 2>/dev/null)
                if [ -z "$url" ]; then
                    url=$(adb -s "$device" shell dumpsys clipboard 2>/dev/null | python3 -c "
import sys, re
m = re.search(r'https?://\S*tiktok\S*', sys.stdin.read())
if m: print(m.group())
" 2>/dev/null)
                fi
            fi
        fi
        if [ -n "$url" ]; then
            echo "[$device] Slideshow URL: $url"
            echo "$url" >> "slideshow_urls_$(date +%Y%m%d).txt"
        else
            echo "[$device] Could not extract post URL"
        fi
        # Tap upper half of screen to dismiss share sheet
        local dismiss_y=$((h * 20 / 100))
        echo "[$device] Dismissing share sheet"
        adb -s "$device" shell input tap "$((w / 2))" "$dismiss_y"
        sleep 1
    else
        echo "[$device] Share button not found — skipping"
    fi
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
    local slide_y=$((h * 40 / 100))
    local swipe_from=$((h * 70 / 100))
    local swipe_to=$((h * 20 / 100))

    for i in $(seq 1 "$SCROLLS"); do
        echo "[$device] ── $feed_name $i/$SCROLLS ──"

        sleep 1
        slideshow=$(is_slideshow "$device")

        if [ "$slideshow" = "yes" ]; then
            echo "[$device] Slideshow detected — swiping through up to $MAX_SLIDES slides"
            for s in $(seq 2 "$MAX_SLIDES"); do
                echo "[$device]   → Slide $s"
                adb -s "$device" shell input swipe \
                    "$slide_start_x" "$slide_y" "$slide_end_x" "$slide_y" 400
                sleep $(( RANDOM % 2 + 1 ))
            done

            echo "[$device] Liking"
            adb -s "$device" shell input tap "$dtap_x" "$dtap_y"
            sleep 0.05
            adb -s "$device" shell input tap "$dtap_x" "$dtap_y"
            sleep 1

            save_post "$device"

            tap_share "$device" "$w" "$h"

            adb -s "$device" shell input swipe "$cx" "$swipe_from" "$cx" "$swipe_to" 300
            sleep 1
        else
            echo "[$device] Video — watching briefly"
            sleep $(( RANDOM % 3 + 3 ))
            adb -s "$device" shell input swipe "$cx" "$swipe_from" "$cx" "$swipe_to" 300
            sleep 1
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
    wake_device "$device" "$w" "$h"

    # Open TikTok feed
    adb -s "$device" shell am start -a android.intent.action.VIEW \
        -d "snssdk1233://feed?refer=web" > /dev/null 2>&1
    sleep 4
    scroll_feed "$device" "Feed" "$w" "$h" "$cx" "$cy"

    echo "[$device] Done"
}

for device in $devices; do
    run_on_device "$device" &
done

wait
echo "All devices done"
