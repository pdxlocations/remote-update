#!/usr/bin/env bash
# Check and optionally update a serial Meshtastic node from GitHub.
# Usage: ./meshtastic-update-check.sh [--port /dev/ttyUSB0] [--dry-run]
set -euo pipefail

REPO='meshtastic/firmware'
PORT=''
DRY_RUN=0

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,3p' "$0"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --port) [ "$#" -ge 2 ] || die '--port requires a path'; PORT=$2; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

for program in curl python3; do
    command -v "$program" >/dev/null || die "Missing required command: $program"
done
if command -v meshtastic >/dev/null 2>&1; then
    CLI=(meshtastic)
elif python3 -m meshtastic --help >/dev/null 2>&1; then
    CLI=(python3 -m meshtastic)
else
    die "Meshtastic CLI not found. Install it: python3 -m pip install --user 'meshtastic[cli]'"
fi

if [ -z "$PORT" ]; then
    ports=()
    for device in /dev/ttyUSB* /dev/ttyACM*; do [ -c "$device" ] && ports+=("$device"); done
    case "${#ports[@]}" in
        0) die 'No USB serial port found; pass --port explicitly.' ;;
        1) PORT=${ports[0]} ;;
        *) die "Multiple serial ports found (${ports[*]}). Pass --port explicitly." ;;
    esac
fi
[ -c "$PORT" ] || die "$PORT is not a character device"

printf 'Serial port: %s\nReading connected node...\n' "$PORT"
INFO=$("${CLI[@]}" --port "$PORT" --info 2>&1) || die "Could not read node on $PORT.\n$INFO"
INSTALLED=$(printf '%s\n' "$INFO" | python3 -c '
import re,sys
s=sys.stdin.read()
m=re.search(r"firmwareVersion[\"'"'"' :]+[\"'"'"']?v?([0-9]+(?:\.[0-9A-Za-z]+)+)",s,re.I)
if not m: m=re.search(r"\bv?([0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9A-Za-z]+)?)\b",s)
if not m: raise SystemExit(1)
print(m.group(1))
') || die "Could not extract firmware version from CLI output.\n$INFO"
printf 'Installed firmware: %s\nChecking GitHub releases...\n' "$INSTALLED"

JSON=$(curl --fail --silent --show-error --location \
    --header 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$REPO/releases?per_page=100") || die 'Could not query GitHub releases.'
RELEASES=$(printf '%s' "$JSON" | python3 -c '
import json,re,sys
releases=json.load(sys.stdin)
count=0
for release in releases:
    if release.get("draft"):
        continue
    label=(release.get("name","")+" "+release.get("tag_name","")).lower()
    tag=release.get("tag_name","").lstrip("v")
    channel="alpha" if re.search(r"\balpha\b",label) else "beta" if re.search(r"\bbeta\b",label) else None
    if channel and re.match(r"^\d+\.\d+\.\d+",tag):
        print(channel+"\t"+tag)
        count+=1
        if count == 5:
            break
') || die 'GitHub returned an unexpected release response.'
[ -n "$RELEASES" ] || die 'No Alpha or Beta releases found.'

printf '\nFive most recent Alpha/Beta releases:\n'
mapfile -t OPTIONS <<< "$RELEASES"
for index in "${!OPTIONS[@]}"; do
    IFS=$'\t' read -r CHANNEL VERSION <<< "${OPTIONS[$index]}"
    printf '  %d) %-5s %s' "$((index + 1))" "$CHANNEL" "$VERSION"
    [ "$VERSION" = "$INSTALLED" ] && printf ' (installed)'
    printf '\n'
done
[ "$DRY_RUN" -eq 0 ] || { printf 'Dry run: no firmware will be downloaded or flashed.\n'; exit 0; }

while :; do
    read -r -p 'Select a release number, or [n]o: ' ANSWER
    case "${ANSWER,,}" in
        n|no|'') printf 'No update started; no firmware was downloaded.\n'; exit 0 ;;
        *[!0-9]*) printf 'Enter a listed number or n.\n' >&2 ;;
        *)
            INDEX=$((ANSWER - 1))
            if [ "$INDEX" -ge 0 ] && [ "$INDEX" -lt "${#OPTIONS[@]}" ]; then
                IFS=$'\t' read -r TARGET VERSION <<< "${OPTIONS[$INDEX]}"
                break
            fi
            printf 'Enter a listed number or n.\n' >&2
            ;;
    esac
done
printf 'Selected %s %s. The firmware download starts now.\n' "$TARGET" "$VERSION"
printf 'Do not disconnect power or serial during the update.\n'
"${CLI[@]}" --port "$PORT" --flash --firmware-version "$VERSION"
printf 'Flash command completed. Run this script again after the node reconnects to verify.\n'
