#!/bin/bash

set -euo pipefail

# Scrape likes, comments, shares, and views for a TikTok post.
#
# Phase 1 (device): Opens the post URL on Android → UI dump → likes/comments/shares.
# Phase 2 (web):    Fetches the post page via ZenRows → parses embedded JSON → views.
#
# Requires:
#   - ZENROWS_API_KEY env var (or pass --no-views to skip)
#   - ADB with a connected Android device
#
# Usage: ./get_post_metrics.sh <post_url> [device_id] [--debug] [--no-views]

DEBUG=false
NO_VIEWS=false
POST_URL=""
DEVICE_ID=""

for arg in "$@"; do
    case "$arg" in
        --debug) DEBUG=true ;;
        --no-views) NO_VIEWS=true ;;
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
    echo "Usage: $0 <post_url> [device_id] [--debug] [--no-views]" >&2
    exit 1
fi

if [ -z "$DEVICE_ID" ]; then
    DEVICE_ID=$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')
fi

if [ -z "$DEVICE_ID" ]; then
    echo "No connected Android device found" >&2
    exit 1
fi

# --- Resolve short URLs (vm.tiktok.com / vt.tiktok.com) ---
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

# --- Phase 1: open post on device, extract likes/comments/shares ---
adb -s "$DEVICE_ID" shell am start -a android.intent.action.VIEW -d "$POST_URL" >/dev/null
sleep 6

POST_XML=$(mktemp)
VIEWS_HTML=$(mktemp)
trap 'rm -f "$POST_XML" "$VIEWS_HTML"' EXIT

dump_ui "$DEVICE_ID" "$POST_XML"

# --- Phase 2: fetch post page via ZenRows for view count ---
if [ "$NO_VIEWS" = false ]; then
    if [ -z "${ZENROWS_API_KEY:-}" ]; then
        echo "[warn] ZENROWS_API_KEY not set — skipping view count. Use --no-views to silence." >&2
    else
        ENCODED_URL=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$RESOLVED_URL")
        HTTP_CODE=$(curl -s -o "$VIEWS_HTML" -w '%{http_code}' \
            "https://api.zenrows.com/v1/?apikey=${ZENROWS_API_KEY}&url=${ENCODED_URL}&js_render=true&premium_proxy=true&wait=5000" \
            2>/dev/null || echo "000")

        if [ "$DEBUG" = true ]; then
            echo "[debug] ZenRows HTTP status: $HTTP_CODE" >&2
            echo "[debug] ZenRows response size: $(wc -c < "$VIEWS_HTML") bytes" >&2
        fi

        if [ "$HTTP_CODE" != "200" ]; then
            echo "[warn] ZenRows returned HTTP $HTTP_CODE — views may be unavailable" >&2
        fi
    fi
fi

# --- Parse everything ---
python3 - "$POST_XML" "$VIEWS_HTML" "$RESOLVED_URL" "$DEVICE_ID" "$DEBUG" <<'PY'
import json
import re
import sys
from xml.etree import ElementTree

post_xml_path = sys.argv[1]
views_html_path = sys.argv[2]
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
        if desc or text:
            short_cls = cls.split(".")[-1] if cls else ""
            rid_short = rid.split("/")[-1] if rid else ""
            print(
                f"  {short_cls:<20} rid={rid_short:<25} desc={desc:<50} text={text:<25} bounds={bounds}",
                file=sys.stderr,
            )
    print(f"=== END UI DUMP ({label}) ===", file=sys.stderr)


# =====================================================================
# Phase 1 — likes / comments / shares from the device UI dump
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
# Phase 2 — views from ZenRows HTML (embedded JSON)
# =====================================================================

try:
    html = open(views_html_path).read()
except Exception:
    html = ""

if html:
    view_count = None

    # Strategy 1: __UNIVERSAL_DATA_FOR_REHYDRATION__ JSON blob
    rehydration_match = re.search(
        r'<script[^>]*id="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>(.*?)</script>',
        html,
        re.DOTALL,
    )
    if rehydration_match:
        try:
            blob = json.loads(rehydration_match.group(1))
            # Walk the nested structure to find statsV2 or stats with playCount
            blob_str = json.dumps(blob)
            play_match = re.search(r'"playCount"\s*:\s*(\d+)', blob_str)
            if play_match:
                view_count = int(play_match.group(1))
                if debug:
                    print(f"  [views] views={view_count} from __UNIVERSAL_DATA_FOR_REHYDRATION__", file=sys.stderr)
        except json.JSONDecodeError as e:
            if debug:
                print(f"  [views] JSON parse error in rehydration blob: {e}", file=sys.stderr)

    # Strategy 2: search raw HTML for playCount in any script tag
    if view_count is None:
        play_match = re.search(r'"playCount"\s*:\s*(\d+)', html)
        if play_match:
            view_count = int(play_match.group(1))
            if debug:
                print(f"  [views] views={view_count} from raw HTML playCount", file=sys.stderr)

    # Strategy 3: og:video meta tag or similar
    if view_count is None:
        og_match = re.search(r'<meta[^>]*property="og:description"[^>]*content="([^"]*)"', html)
        if og_match:
            desc = og_match.group(1)
            v = re.search(r"([\d.,]+[KMB]?)\s+(?:views|plays)", desc, re.IGNORECASE)
            if v:
                view_count = parse_count(v.group(1))
                if debug:
                    print(f"  [views] views={view_count} from og:description", file=sys.stderr)

    if view_count is not None:
        metrics["views"] = view_count
    elif debug:
        print("  [views] could not find playCount in ZenRows HTML", file=sys.stderr)
        print(f"  [views] HTML length: {len(html)} chars", file=sys.stderr)

elif debug:
    print("  [views] no ZenRows HTML available", file=sys.stderr)


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
