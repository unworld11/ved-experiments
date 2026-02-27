#!/bin/bash

# Go to @gamingarb01's profile, open their posts, and for any that are
# photo slideshows swipe through each slide before liking and moving on.
# Uses uiautomator dump + Python to locate UI elements dynamically
# (no hardcoded screen coords) so it works across device sizes.
# Usage: ./swipe_slideshow_posts.sh [number_of_posts]
# Cron (every 4 hours): 0 */4 * * * /bin/bash /path/to/swipe_slideshow_posts.sh >> /path/to/cron.log 2>&1

ACCOUNTS=(
    "gamingarb01"
    "userwealthrich"
)
POST_COUNT=${1:-10}
MAX_SLIDES=5        # max slides to swipe through per slideshow
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

# Bookmark/save the current post by tapping the Favourites button.
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

# Returns "yes" if the current post is a photo slideshow, "no" otherwise.
# TikTok marks slideshows with a "Photo" label on screen.
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

    for account in "${ACCOUNTS[@]}"; do
        echo "[$device] ═══ Opening @$account ═══"
        adb -s "$device" shell am start -a android.intent.action.VIEW \
            -d "https://www.tiktok.com/@$account"
        sleep 5

        echo "[$device] Finding first post in grid..."
        post_coords=$(get_first_post_coords "$device" "$w" "$h")
        post_x=$(echo "$post_coords" | awk '{print $1}')
        post_y=$(echo "$post_coords" | awk '{print $2}')
        echo "[$device] Tapping first post at ($post_x, $post_y)"
        adb -s "$device" shell input tap "$post_x" "$post_y"
        sleep 3

        for i in $(seq 1 "$POST_COUNT"); do
            echo "[$device] ── @$account Post $i/$POST_COUNT ──"
            sleep 1

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
            else
                echo "[$device] Regular video — watching"
                sleep $SCROLL_DELAY
            fi

            echo "[$device] Liking"
            adb -s "$device" shell input tap "$dtap_x" "$dtap_y"
            sleep 0.1
            adb -s "$device" shell input tap "$dtap_x" "$dtap_y"
            sleep $SCROLL_DELAY

            save_post "$device"

            tap_share "$device" "$w" "$h"

            echo "[$device] Next post"
            adb -s "$device" shell input swipe "$cx" "$next_post_from" "$cx" "$next_post_to" 250
            sleep $SCROLL_DELAY
        done

        echo "[$device] Done with @$account — $POST_COUNT posts processed"
        sleep 2
    done
}

for device in $devices; do
    run_on_device "$device" &
done

wait
echo "All devices done"
