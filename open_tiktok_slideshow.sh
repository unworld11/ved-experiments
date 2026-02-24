#!/bin/bash

# Opens TikTok on all connected Android devices and searches for #slideshow

# Get a list of all connected device serials
devices=$(adb devices | awk 'NR>1 && $2=="device" {print $1}')

# Loop through each device and open TikTok with #slideshow search
for device in $devices; do
    echo "Opening TikTok #slideshow search on $device"
    adb -s "$device" shell am start -a android.intent.action.VIEW -d "snssdk1233://search?keyword=%23slideshow"
done
