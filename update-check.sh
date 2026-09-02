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

for program in curl python3 unzip find; do
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
HW_MODEL=$(printf '%s\n' "$INFO" | python3 -c '
import re,sys
s=sys.stdin.read()
m=re.search(r"hwModel[\"'"'"' :]+[\"'"'"']?([A-Za-z0-9_ -]+)",s,re.I)
print(m.group(1).strip() if m else "")
') || true
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
printf 'Selected %s %s. Choose the matching archive next; nothing has been downloaded yet.\n' "$TARGET" "$VERSION"
ASSETS=$(printf '%s' "$JSON" | python3 -c '
import json,sys
version=sys.argv[1]
for release in json.load(sys.stdin):
    if release.get("tag_name", "").lstrip("v") != version:
        continue
    for asset in release.get("assets", []):
        name=asset.get("name", "")
        url=asset.get("browser_download_url", "")
        if name.startswith("firmware-") and name.endswith(".zip"):
            print(name+"\t"+url)
    break
' "$VERSION") || die 'Could not read the selected release assets.'
[ -n "$ASSETS" ] || die "No firmware ZIP assets found for $VERSION."
printf '\nFirmware archives for %s:\n' "$VERSION"
mapfile -t ARCHIVES <<< "$ASSETS"
for index in "${!ARCHIVES[@]}"; do
    IFS=$'\t' read -r ARCHIVE_NAME ARCHIVE_URL <<< "${ARCHIVES[$index]}"
    printf '  %d) %s\n' "$((index + 1))" "$ARCHIVE_NAME"
done
while :; do
    read -r -p 'Select the archive for your device, or [n]o: ' ANSWER
    case "${ANSWER,,}" in
        n|no|'') printf 'No firmware was downloaded.\n'; exit 0 ;;
        *[!0-9]*) printf 'Enter a listed number or n.\n' >&2 ;;
        *)
            INDEX=$((ANSWER - 1))
            if [ "$INDEX" -ge 0 ] && [ "$INDEX" -lt "${#ARCHIVES[@]}" ]; then IFS=$'\t' read -r ARCHIVE_NAME ARCHIVE_URL <<< "${ARCHIVES[$INDEX]}"; break; fi
            printf 'Enter a listed number or n.\n' >&2 ;;
    esac
done
WORKDIR=$(mktemp -d) || die 'Could not create a temporary working directory.'
trap 'rm -rf "$WORKDIR"' EXIT
ZIP_FILE="$WORKDIR/$ARCHIVE_NAME"
printf 'Downloading %s...\n' "$ARCHIVE_NAME"
curl --fail --show-error --location --output "$ZIP_FILE" "$ARCHIVE_URL" || die 'Firmware download failed.'
unzip -q "$ZIP_FILE" -d "$WORKDIR/unpacked" || die 'Could not unpack firmware archive.'
UPDATE_SCRIPT=$(find "$WORKDIR/unpacked" -type f -name device-update.sh -print -quit)
[ -n "$UPDATE_SCRIPT" ] || die 'The archive does not contain device-update.sh.'
chmod +x "$UPDATE_SCRIPT"
MODEL_TOKEN=$(printf '%s' "$HW_MODEL" | tr '[:upper:]_' '[:lower:]-' | tr -cs '[:alnum:]-' '-')
mapfile -t BINARIES < <(find "$WORKDIR/unpacked" -type f -name '*-update.bin' | sort)
if [ -n "$MODEL_TOKEN" ]; then
    mapfile -t MATCHING_BINARIES < <(printf '%s\n' "${BINARIES[@]}" | grep -i "firmware-${MODEL_TOKEN}-" || true)
    [ "${#MATCHING_BINARIES[@]}" -gt 0 ] && BINARIES=("${MATCHING_BINARIES[@]}")
fi
[ "${#BINARIES[@]}" -gt 0 ] || die 'No update firmware binary was found in the selected archive.'
printf '\nUpdate binaries%s:\n' "${HW_MODEL:+ (filtered for $HW_MODEL)}"
for index in "${!BINARIES[@]}"; do printf '  %d) %s\n' "$((index + 1))" "$(basename "${BINARIES[$index]}")"; done
while :; do
    read -r -p 'Select the matching update binary, or [n]o: ' ANSWER
    case "${ANSWER,,}" in
        n|no|'') printf 'Download kept only temporarily; no update started.\n'; exit 0 ;;
        *[!0-9]*) printf 'Enter a listed number or n.\n' >&2 ;;
        *)
            INDEX=$((ANSWER - 1))
            if [ "$INDEX" -ge 0 ] && [ "$INDEX" -lt "${#BINARIES[@]}" ]; then FIRMWARE=${BINARIES[$INDEX]}; break; fi
            printf 'Enter a listed number or n.\n' >&2 ;;
    esac
done
printf 'Running device-update.sh with %s. Do not disconnect power or serial.\n' "$(basename "$FIRMWARE")"
"$UPDATE_SCRIPT" -p "$PORT" -f "$FIRMWARE"
printf 'Update completed. Run this script again after the node reconnects to verify.\n'
