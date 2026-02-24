#!/bin/bash

# Opens TikTok on all connected Android devices, searches #slideshow,
# dumps UI for debugging, taps first video, scrolls once.

devices=$(adb devices | awk 'NR>1 && $2=="device" {print $1}')

run_on_device() {
    local device=$1

    # Get screen dimensions
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

    # --- DEBUG: dump UI after search loads (grid view) ---
    echo "[$device] === UI DUMP (search grid) ==="
    adb -s "$device" shell uiautomator dump /dev/stdout 2>/dev/null | \
        python3 -c "
import sys, re
xml = sys.stdin.read()
# Print all clickable nodes with their desc, text, class and bounds
nodes = re.findall(r'<node[^>]*>', xml)
for n in nodes:
    cls   = re.search(r'class=\"([^\"]+)\"', n)
    desc  = re.search(r'content-desc=\"([^\"]+)\"', n)
    text  = re.search(r' text=\"([^\"]+)\"', n)
    click = re.search(r'clickable=\"(true|false)\"', n)
    bnd   = re.search(r'bounds=\"([^\"]+)\"', n)
    if cls and bnd:
        print(f'  class={cls.group(1).split(\".\")[-1]:<20} desc={str(desc.group(1) if desc else \"\"):<25} text={str(text.group(1) if text else \"\"):<20} clickable={click.group(1) if click else \"?\":<5} bounds={bnd.group(1)}')
"
    echo "[$device] === END UI DUMP ==="

    # Scroll once in the grid
    echo "[$device] Scrolling grid once"
    adb -s "$device" shell input swipe $cx $((h * 3 / 4)) $cx $((h / 4)) 400
    sleep 2

    # Tap into the first video (top-left cell of the grid)
    tap_x=$((w / 6))
    tap_y=$((h / 4))
    echo "[$device] Tapping first grid item at ($tap_x, $tap_y)"
    adb -s "$device" shell input tap $tap_x $tap_y
    sleep 3

    # --- DEBUG: dump UI after video opens (player view) ---
    echo "[$device] === UI DUMP (video player) ==="
    adb -s "$device" shell uiautomator dump /dev/stdout 2>/dev/null | \
        python3 -c "
import sys, re
xml = sys.stdin.read()
nodes = re.findall(r'<node[^>]*>', xml)
for n in nodes:
    cls   = re.search(r'class=\"([^\"]+)\"', n)
    desc  = re.search(r'content-desc=\"([^\"]+)\"', n)
    text  = re.search(r' text=\"([^\"]+)\"', n)
    click = re.search(r'clickable=\"(true|false)\"', n)
    bnd   = re.search(r'bounds=\"([^\"]+)\"', n)
    if cls and bnd:
        print(f'  class={cls.group(1).split(\".\")[-1]:<20} desc={str(desc.group(1) if desc else \"\"):<25} text={str(text.group(1) if text else \"\"):<20} clickable={click.group(1) if click else \"?\":<5} bounds={bnd.group(1)}')
"
    echo "[$device] === END UI DUMP ==="

    # Scroll once to next video
    echo "[$device] Scrolling once"
    adb -s "$device" shell input swipe $cx $((h * 3 / 4)) $cx $((h / 4)) 400
    sleep 2

    echo "[$device] Done — check UI dumps above to verify Like button location"
}

for device in $devices; do
    run_on_device "$device"
done
