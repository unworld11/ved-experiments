#!/bin/bash

# Opens TikTok #slideshow search, scrolls grid once, taps first video,
# then keeps scrolling and liking posts.
# Usage: ./open_tiktok_slideshow.sh [number_of_posts]

LIKE_COUNT=${1:-20}
SCROLL_DELAY=2

devices=$(adb devices | awk 'NR>1 && $2=="device" {print $1}')

dump_ui() {
    local device=$1
    adb -s "$device" shell uiautomator dump /sdcard/ui_dump.xml > /dev/null 2>&1
    adb -s "$device" shell cat /sdcard/ui_dump.xml
}

get_like_coords() {
    local device=$1
    dump_ui "$device" | python3 -c "
import sys, re
xml = sys.stdin.read()
m = re.search(r'content-desc=\"Like\"[^>]*bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"', xml) or \
    re.search(r'bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"[^>]*content-desc=\"Like\"', xml)
if m:
    x1,y1,x2,y2 = map(int, m.groups())
    print(f'{(x1+x2)//2} {(y1+y2)//2}')
"
}

print_ui_dump() {
    local device=$1
    dump_ui "$device" | python3 -c "
import sys, re
xml = sys.stdin.read()
print(f'raw xml length: {len(xml)} chars')
for n in re.findall(r'<node[^>]*>', xml):
    cls  = re.search(r'class=\"([^\"]+)\"', n)
    desc = re.search(r'content-desc=\"([^\"]+)\"', n)
    text = re.search(r' text=\"([^\"]+)\"', n)
    clk  = re.search(r'clickable=\"(true|false)\"', n)
    bnd  = re.search(r'bounds=\"([^\"]+)\"', n)
    if cls and bnd:
        print(f'  class={cls.group(1).split(\".\")[-1]:<20} desc={str(desc.group(1) if desc else \"\"):<25} text={str(text.group(1) if text else \"\"):<20} clickable={clk.group(1) if clk else \"?\":<5} bounds={bnd.group(1)}')
"
}

run_on_device() {
    local device=$1

    size=$(adb -s "$device" shell wm size | grep -oE '[0-9]+x[0-9]+')
    w=$(echo "$size" | cut -dx -f1)
    h=$(echo "$size" | cut -dx -f2)
    cx=$((w / 2))
    cy=$((h / 2))

    echo "[$device] Screen: ${w}x${h}"

    echo "[$device] Opening TikTok #slideshow search"
    adb -s "$device" shell am start -a android.intent.action.VIEW \
        -d "snssdk1233://search?keyword=%23slideshow"
    sleep 4

    echo "[$device] === UI DUMP (search grid) ==="
    print_ui_dump "$device"
    echo "[$device] === END UI DUMP ==="

    # Scroll once in the grid
    echo "[$device] Scrolling grid once"
    adb -s "$device" shell input swipe $cx $((h * 3 / 4)) $cx $((h / 4)) 400
    sleep 2

    # Tap first video (top-left cell)
    tap_x=$((w / 6))
    tap_y=$((h / 4))
    echo "[$device] Tapping first grid item at ($tap_x, $tap_y)"
    adb -s "$device" shell input tap $tap_x $tap_y
    sleep 3

    echo "[$device] === UI DUMP (video player) ==="
    print_ui_dump "$device"
    echo "[$device] === END UI DUMP ==="

    # Like loop
    for i in $(seq 1 $LIKE_COUNT); do
        echo "[$device] Post $i/$LIKE_COUNT — finding Like button"

        coords=$(get_like_coords "$device")

        if [ -n "$coords" ]; then
            lx=$(echo "$coords" | awk '{print $1}')
            ly=$(echo "$coords" | awk '{print $2}')
            echo "[$device] Liking at ($lx, $ly)"
            adb -s "$device" shell input tap "$lx" "$ly"
        else
            echo "[$device] Like button not found, skipping"
        fi

        sleep $SCROLL_DELAY

        adb -s "$device" shell input swipe $cx $((h * 3 / 4)) $cx $((h / 4)) 400
        sleep $SCROLL_DELAY
    done

    echo "[$device] Done — liked $LIKE_COUNT posts"
}

for device in $devices; do
    run_on_device "$device" &
done

wait
echo "All devices done"
