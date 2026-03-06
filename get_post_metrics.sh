#!/bin/bash

set -euo pipefail

# Scrape likes, comments, shares, and views for a TikTok post.
#
# Phase 1: Opens the post URL → dumps UI → extracts likes/comments/shares.
# Phase 2: Opens the creator's profile → dumps UI → finds the video in the
#           grid by video ID → extracts the view count.
#
# Usage: ./get_post_metrics.sh <post_url> [device_id] [--debug]

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

# --- Resolve short URLs (vm.tiktok.com) to full URLs ---
RESOLVED_URL="$POST_URL"
if echo "$POST_URL" | grep -qE 'vm\.tiktok\.com|vt\.tiktok\.com'; then
    RESOLVED_URL=$(curl -Ls -o /dev/null -w '%{url_effective}' "$POST_URL" 2>/dev/null || echo "$POST_URL")
    if [ "$DEBUG" = true ]; then
        echo "[debug] Resolved short URL → $RESOLVED_URL" >&2
    fi
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

# --- Phase 1: open post, extract likes/comments/shares ---
adb -s "$DEVICE_ID" shell am start -a android.intent.action.VIEW -d "$POST_URL" >/dev/null
sleep 6

POST_XML=$(mktemp)
trap 'rm -f "$POST_XML" "${PROFILE_XML:-}"' EXIT

dump_ui "$DEVICE_ID" "$POST_XML"

# --- Phase 2: open profile, extract views ---
PROFILE_XML=$(mktemp)

# Parse username from the resolved URL  (https://www.tiktok.com/@user/video/123...)
USERNAME=$(echo "$RESOLVED_URL" | grep -oE '/@[^/]+' | head -1 | tr -d '/@')

if [ -n "$USERNAME" ]; then
    if [ "$DEBUG" = true ]; then
        echo "[debug] Navigating to profile: @$USERNAME" >&2
    fi
    adb -s "$DEVICE_ID" shell am start -a android.intent.action.VIEW \
        -d "https://www.tiktok.com/@$USERNAME" >/dev/null
    sleep 5
    dump_ui "$DEVICE_ID" "$PROFILE_XML"
else
    if [ "$DEBUG" = true ]; then
        echo "[debug] Could not parse username from URL, skipping profile phase" >&2
    fi
    PROFILE_XML=""
fi

# --- Parse both dumps ---
python3 - "$POST_XML" "${PROFILE_XML:-}" "$RESOLVED_URL" "$DEVICE_ID" "$DEBUG" <<'PY'
import json
import re
import sys
from xml.etree import ElementTree

post_xml_path = sys.argv[1]
profile_xml_path = sys.argv[2]
post_url = sys.argv[3]
device_id = sys.argv[4]
debug = sys.argv[5] == "true"

# --- Shared helpers ---

INLINE_COUNT = re.compile(r"([\d.,]+\s*[KMBkmb]?)")

SUFFIX_MULTIPLIERS = {"K": 1_000, "M": 1_000_000, "B": 1_000_000_000}


def parse_count(raw):
    if not raw:
        return None
    cleaned = raw.strip().replace(",", "").upper()
    if not cleaned:
        return None
    suffix = cleaned[-1]
    mult = SUFFIX_MULTIPLIERS.get(suffix)
    try:
        if mult is None:
            return int(float(cleaned))
        return int(float(cleaned[:-1]) * mult)
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


def dump_tree(root, label):
    print(f"=== UI DUMP ({label}) ===", file=sys.stderr)
    for node in root.iter("node"):
        cls = node.attrib.get("class", "")
        desc = node.attrib.get("content-desc", "")
        text = node.attrib.get("text", "")
        rid = node.attrib.get("resource-id", "")
        bounds = node.attrib.get("bounds", "")
        if desc or text or (rid and "cover" in rid):
            short_cls = cls.split(".")[-1] if cls else ""
            rid_short = rid.split("/")[-1] if rid else ""
            print(
                f"  {short_cls:<20} rid={rid_short:<25} desc={desc:<50} text={text:<25} bounds={bounds}",
                file=sys.stderr,
            )
    print(f"=== END UI DUMP ({label}) ===", file=sys.stderr)


# =====================================================================
# Phase 1 — likes / comments / shares from the post page
# =====================================================================

tree = ElementTree.parse(post_xml_path)
root = tree.getroot()
parent_map = {child: parent for parent in root.iter("node") for child in parent}

if debug:
    dump_tree(root, "post page")

METRIC_KEYWORDS = {
    "likes": re.compile(r"\blike", re.IGNORECASE),
    "comments": re.compile(r"\bcomment", re.IGNORECASE),
    "shares": re.compile(r"\bshare", re.IGNORECASE),
}

INLINE_METRIC_PATTERNS = {
    "likes": re.compile(r"(?P<count>[\d.,]+\s*[KMBkmb]?)\s+likes?\b", re.IGNORECASE),
    "comments": re.compile(r"(?P<count>[\d.,]+\s*[KMBkmb]?)\s+comments?\b", re.IGNORECASE),
    "shares": re.compile(r"(?P<count>[\d.,]+\s*[KMBkmb]?)\s+shares?\b", re.IGNORECASE),
}

metrics = {"likes": None, "comments": None, "shares": None, "views": None}

# Pass 1: inline counts
for node in root.iter("node"):
    for attr_name in ("content-desc", "text"):
        payload = node.attrib.get(attr_name, "").strip()
        if not payload:
            continue
        for name, pat in INLINE_METRIC_PATTERNS.items():
            if metrics[name] is not None:
                continue
            m = pat.search(payload)
            if m:
                c = parse_count(m.group("count"))
                if c is not None:
                    metrics[name] = c
                    if debug:
                        print(f"  [pass1] {name}={c} from '{payload}'", file=sys.stderr)

# Pass 2: tree-walk for missing metrics
if any(metrics[k] is None for k in ("likes", "comments", "shares")):
    for node in root.iter("node"):
        desc = node.attrib.get("content-desc", "").strip()
        text = node.attrib.get("text", "").strip()
        for name, kw in METRIC_KEYWORDS.items():
            if metrics[name] is not None:
                continue
            payload = None
            if desc and kw.search(desc):
                payload = desc
            elif text and kw.search(text):
                payload = text
            else:
                continue
            count = find_count_in_children(node)
            if count is None:
                count = find_count_in_siblings(node, parent_map)
            if count is None:
                count = find_count_in_parent(node, parent_map)
            if count is not None:
                metrics[name] = count
                if debug:
                    print(f"  [pass2] {name}={count} from tree near '{payload}'", file=sys.stderr)


# =====================================================================
# Phase 2 — views from the profile page grid
# =====================================================================

# Extract the video ID from the URL (the numeric segment after /video/)
video_id = None
vid_match = re.search(r"/video/(\d+)", post_url)
if vid_match:
    video_id = vid_match.group(1)

if profile_xml_path and video_id:
    try:
        ptree = ElementTree.parse(profile_xml_path)
        proot = ptree.getroot()
        pparent_map = {child: parent for parent in proot.iter("node") for child in parent}

        if debug:
            dump_tree(proot, "profile page")

        # Strategy 1: look for any node whose resource-id or content-desc
        # contains the video ID, then grab the view count from its subtree.
        found_via_id = False
        for node in proot.iter("node"):
            rid = node.attrib.get("resource-id", "")
            desc = node.attrib.get("content-desc", "")
            if video_id not in rid and video_id not in desc:
                continue

            if debug:
                print(f"  [views] matched video_id in node rid='{rid}' desc='{desc}'", file=sys.stderr)

            # Walk up to the grid item container (up to 4 levels)
            container = node
            for _ in range(4):
                parent = pparent_map.get(container)
                if parent is None:
                    break
                container = parent

            # Find view count in the container's descendants
            for child in container.iter("node"):
                for attr in ("text", "content-desc"):
                    val = child.attrib.get(attr, "").strip()
                    if not val:
                        continue
                    if INLINE_COUNT.fullmatch(val):
                        c = parse_count(val)
                        if c is not None:
                            metrics["views"] = c
                            found_via_id = True
                            if debug:
                                print(f"  [views] views={c} from '{val}' in container", file=sys.stderr)
                            break
                    # Also match "X views" pattern
                    vm = re.search(r"([\d.,]+\s*[KMBkmb]?)\s+views?\b", val, re.IGNORECASE)
                    if vm:
                        c = parse_count(vm.group(1))
                        if c is not None:
                            metrics["views"] = c
                            found_via_id = True
                            if debug:
                                print(f"  [views] views={c} from '{val}' (views pattern)", file=sys.stderr)
                            break
                if found_via_id:
                    break
            if found_via_id:
                break

        # Strategy 2: if video ID wasn't in the tree, look for "X views"
        # anywhere on the profile page (less precise but a usable fallback).
        if metrics["views"] is None:
            for node in proot.iter("node"):
                for attr in ("content-desc", "text"):
                    val = node.attrib.get(attr, "").strip()
                    if not val:
                        continue
                    vm = re.search(r"([\d.,]+\s*[KMBkmb]?)\s+views?\b", val, re.IGNORECASE)
                    if vm:
                        c = parse_count(vm.group(1))
                        if c is not None:
                            metrics["views"] = c
                            if debug:
                                print(f"  [views] fallback views={c} from '{val}'", file=sys.stderr)
                            break
                if metrics["views"] is not None:
                    break

    except Exception as e:
        if debug:
            print(f"  [views] error parsing profile: {e}", file=sys.stderr)

elif debug:
    if not video_id:
        print("  [views] could not parse video_id from URL, skipping", file=sys.stderr)
    if not profile_xml_path:
        print("  [views] no profile dump available, skipping", file=sys.stderr)


# =====================================================================
# Output
# =====================================================================

result = {
    "device_id": device_id,
    "post_url": post_url,
    "likes": metrics["likes"],
    "comments": metrics["comments"],
    "shares": metrics["shares"],
    "views": metrics["views"],
}

print(json.dumps(result, indent=2))
PY
