#!/bin/bash

set -euo pipefail

# Open a TikTok post on an Android device and print its visible metrics as JSON.
# Usage: ./get_post_metrics.sh <post_url> [device_id]

POST_URL="${1:-}"
DEVICE_ID="${2:-}"

if [ -z "$POST_URL" ]; then
    echo "Usage: $0 <post_url> [device_id]" >&2
    exit 1
fi

if [ -z "$DEVICE_ID" ]; then
    DEVICE_ID=$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')
fi

if [ -z "$DEVICE_ID" ]; then
    echo "No connected Android device found" >&2
    exit 1
fi

wake_device() {
    local device=$1
    local screen
    screen=$(adb -s "$device" shell dumpsys power | awk -F= '/Display Power/ && /state=/{print $2; exit}')
    if [ "$screen" != "ON" ]; then
        adb -s "$device" shell input keyevent KEYCODE_WAKEUP
        sleep 1
    fi

    adb -s "$device" shell input swipe 540 1800 540 900 300 >/dev/null 2>&1 || true
    sleep 1
}

dump_ui() {
    local device=$1
    local output_file=$2

    adb -s "$device" shell uiautomator dump /sdcard/ui_dump.xml >/dev/null
    adb -s "$device" pull /sdcard/ui_dump.xml "$output_file" >/dev/null
}

wake_device "$DEVICE_ID"

adb -s "$DEVICE_ID" shell am start -a android.intent.action.VIEW -d "$POST_URL" >/dev/null
sleep 6

TMP_XML=$(mktemp)
trap 'rm -f "$TMP_XML"' EXIT

dump_ui "$DEVICE_ID" "$TMP_XML"

python3 - "$TMP_XML" "$POST_URL" "$DEVICE_ID" <<'PY'
import json
import re
import sys
from xml.etree import ElementTree

xml_path, post_url, device_id = sys.argv[1:4]

metric_patterns = {
    "likes": (
        re.compile(r"(?P<count>[\d.,]+(?:[KMB])?)\s+likes?\b", re.IGNORECASE),
        re.compile(r"\blikes?\b[^0-9]*(?P<count>[\d.,]+(?:[KMB])?)", re.IGNORECASE),
    ),
    "comments": (
        re.compile(r"(?P<count>[\d.,]+(?:[KMB])?)\s+comments?\b", re.IGNORECASE),
        re.compile(r"\bcomments?\b[^0-9]*(?P<count>[\d.,]+(?:[KMB])?)", re.IGNORECASE),
    ),
    "shares": (
        re.compile(r"(?P<count>[\d.,]+(?:[KMB])?)\s+shares?\b", re.IGNORECASE),
        re.compile(r"\bshares?\b[^0-9]*(?P<count>[\d.,]+(?:[KMB])?)", re.IGNORECASE),
    ),
}

suffix_multipliers = {
    "K": 1_000,
    "M": 1_000_000,
    "B": 1_000_000_000,
}


def parse_count(raw_count):
    if not raw_count:
        return None

    cleaned = raw_count.strip().replace(",", "").upper()
    if not cleaned:
        return None

    suffix = cleaned[-1]
    multiplier = suffix_multipliers.get(suffix)

    try:
        if multiplier is None:
            return int(float(cleaned))
        return int(float(cleaned[:-1]) * multiplier)
    except ValueError:
        return None


def extract_metric(text, metric_name):
    if not text:
        return None

    for pattern in metric_patterns[metric_name]:
        match = pattern.search(text)
        if not match:
            continue

        count = parse_count(match.group("count"))
        if count is not None:
            return count

    return None


tree = ElementTree.parse(xml_path)
root = tree.getroot()

payloads = []
metrics = {"likes": None, "comments": None, "shares": None}

for node in root.iter("node"):
    for attr_name in ("content-desc", "text"):
        value = node.attrib.get(attr_name)
        if value:
            payloads.append(value)

for payload in payloads:
    for metric_name in metrics:
        if metrics[metric_name] is not None:
            continue

        count = extract_metric(payload, metric_name)
        if count is not None:
            metrics[metric_name] = count

result = {
    "device_id": device_id,
    "post_url": post_url,
    "likes": metrics["likes"],
    "comments": metrics["comments"],
    "shares": metrics["shares"],
}

print(json.dumps(result, indent=2))
PY
