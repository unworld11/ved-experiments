#!/bin/bash

set -euo pipefail

# Open a TikTok post on an Android device and print its visible metrics as JSON.
# Usage: ./get_post_metrics.sh <post_url> [device_id]

DEBUG=false
POST_URL=""
DEVICE_ID=""

for arg in "$@"; do
    case "$arg" in
        --debug) DEBUG=true ;;
        *)
            if [ -z "$POST_URL" ]; then
                POST_URL="$arg"
            elif [ -z "$DEVICE_ID" ]; then
                DEVICE_ID="$arg"
            fi
            ;;
    esac
done

if [ -z "$POST_URL" ]; then
    echo "Usage: $0 <post_url> [device_id] [--debug]" >&2
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

python3 - "$TMP_XML" "$POST_URL" "$DEVICE_ID" "$DEBUG" <<'PY'
import json
import re
import sys
from xml.etree import ElementTree

xml_path, post_url, device_id, debug_flag = sys.argv[1:5]
debug = debug_flag == "true"

# TikTok button descriptions vary across versions:
#   "Like"  /  "like video"  /  "1234 likes, like video"
#   "Comment"  /  "read or add comments"  /  "34 comments, read or add comments"
#   "Share"  /  "share video"  /  "8 shares, share video"
# We match any content-desc/text containing the keyword, then try to extract a
# count from the same string first, falling back to sibling/child nodes.

METRIC_KEYWORDS = {
    "likes": re.compile(r"\blike", re.IGNORECASE),
    "comments": re.compile(r"\bcomment", re.IGNORECASE),
    "shares": re.compile(r"\bshare", re.IGNORECASE),
}

INLINE_COUNT = re.compile(r"([\d.,]+\s*[KMBkmb]?)")

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


def get_numeric_value(node):
    for attr in ("text", "content-desc"):
        val = node.attrib.get(attr, "").strip()
        if val and INLINE_COUNT.fullmatch(val):
            return val
    return None


def find_count_in_children(node):
    for child in node:
        val = get_numeric_value(child)
        if val:
            return parse_count(val)
        for grandchild in child:
            val = get_numeric_value(grandchild)
            if val:
                return parse_count(val)
    return None


def find_count_in_siblings(node, parent_map):
    parent = parent_map.get(node)
    if parent is None:
        return None
    children = list(parent)
    try:
        idx = children.index(node)
    except ValueError:
        return None
    for sibling in children[idx + 1 : idx + 3]:
        val = get_numeric_value(sibling)
        if val:
            return parse_count(val)
        count = find_count_in_children(sibling)
        if count is not None:
            return count
    # Also check preceding siblings (count might be above the icon)
    for sibling in reversed(children[max(0, idx - 2) : idx]):
        val = get_numeric_value(sibling)
        if val:
            return parse_count(val)
        count = find_count_in_children(sibling)
        if count is not None:
            return count
    return None


def find_count_in_parent(node, parent_map):
    parent = parent_map.get(node)
    if parent is None:
        return None
    count = find_count_in_children(parent)
    if count is not None:
        return count
    return find_count_in_siblings(parent, parent_map)


tree = ElementTree.parse(xml_path)
root = tree.getroot()
parent_map = {child: parent for parent in root.iter("node") for child in parent}

if debug:
    print("=== UI DUMP (elements with content-desc or text) ===", file=sys.stderr)
    for node in root.iter("node"):
        cls = node.attrib.get("class", "")
        desc = node.attrib.get("content-desc", "")
        text = node.attrib.get("text", "")
        bounds = node.attrib.get("bounds", "")
        clickable = node.attrib.get("clickable", "")
        if desc or text:
            short_cls = cls.split(".")[-1] if cls else ""
            print(
                f"  {short_cls:<20} desc={desc:<50} text={text:<25} click={clickable} bounds={bounds}",
                file=sys.stderr,
            )
    print("=== END UI DUMP ===", file=sys.stderr)

metrics = {"likes": None, "comments": None, "shares": None}

# Inline patterns that match descriptions WITH an embedded count, e.g.
#   "1234 likes, like video"  /  "34 comments, read or add comments"  /  "8 shares, share video"
INLINE_METRIC_PATTERNS = {
    "likes": re.compile(r"(?P<count>[\d.,]+\s*[KMBkmb]?)\s+likes?\b", re.IGNORECASE),
    "comments": re.compile(r"(?P<count>[\d.,]+\s*[KMBkmb]?)\s+comments?\b", re.IGNORECASE),
    "shares": re.compile(r"(?P<count>[\d.,]+\s*[KMBkmb]?)\s+shares?\b", re.IGNORECASE),
}

# --- Pass 1: reliable inline counts (count is embedded in the description) ---
for node in root.iter("node"):
    for attr_name in ("content-desc", "text"):
        payload = node.attrib.get(attr_name, "").strip()
        if not payload:
            continue

        for metric_name, pattern in INLINE_METRIC_PATTERNS.items():
            if metrics[metric_name] is not None:
                continue

            match = pattern.search(payload)
            if match:
                count = parse_count(match.group("count"))
                if count is not None:
                    metrics[metric_name] = count
                    if debug:
                        print(f"  [pass1] {metric_name}={count} from '{payload}'", file=sys.stderr)

# --- Pass 2: for still-missing metrics, find the keyword node and tree-walk ---
if any(v is None for v in metrics.values()):
    for node in root.iter("node"):
        desc = node.attrib.get("content-desc", "").strip()
        text = node.attrib.get("text", "").strip()

        for metric_name, keyword_pat in METRIC_KEYWORDS.items():
            if metrics[metric_name] is not None:
                continue

            payload = None
            if desc and keyword_pat.search(desc):
                payload = desc
            elif text and keyword_pat.search(text):
                payload = text
            else:
                continue

            count = find_count_in_children(node)
            if count is None:
                count = find_count_in_siblings(node, parent_map)
            if count is None:
                count = find_count_in_parent(node, parent_map)
            if count is not None:
                metrics[metric_name] = count
                if debug:
                    print(f"  [pass2] {metric_name}={count} from tree near '{payload}'", file=sys.stderr)

result = {
    "device_id": device_id,
    "post_url": post_url,
    "likes": metrics["likes"],
    "comments": metrics["comments"],
    "shares": metrics["shares"],
}

print(json.dumps(result, indent=2))
PY
