#!/bin/bash

# =============================================================
#  TrueHD Atmos → EAC3 Atmos Converter for macOS
#  - Detects TrueHD Atmos audio tracks in an MKV file
#  - Converts each to EAC3 Atmos at 768 kbps
#  - Adds EAC3 tracks alongside originals in output MKV
#  - Output: filename_atmos_eac3.mkv (original kept)
#
#  Usage:
#    ./drop_FILE_add_atmos_eac3.sh /path/to/movie.mkv
#    Or drag a file onto the Automator app wrapper
#
#  Required tools:
#    brew install ffmpeg mkvtoolnix
# =============================================================

# ---- Colour output ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${CYAN}  $1${NC}"; }
ok()   { echo -e "${GREEN}  ✓ $1${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $1${NC}"; }
err()  { echo -e "${RED}  ✗ $1${NC}"; }
hdr()  { echo -e "\n${BOLD}  $1${NC}"; echo "  $(echo "$1" | sed 's/./-/g')"; }

SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"

# ---- Cleanup on error ----
WORKDIR=""
cleanup_on_error() {
    echo ""
    err "Something went wrong. Stopping."
    if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
        err "Temporary files preserved in: $WORKDIR"
        err "Original file is unchanged."
    fi
    read -r -p "  Press Enter to close..."
    exit 1
}
trap cleanup_on_error ERR

# ---- Tool resolution ----
resolve_tool() {
    if command -v "$1" &>/dev/null; then echo "$1"
    elif [ -f "$SCRIPTDIR/bin/$1" ]; then echo "$SCRIPTDIR/bin/$1"
    elif [ -f "$SCRIPTDIR/$1" ]; then echo "$SCRIPTDIR/$1"
    else err "$1 not found. Install via Homebrew or place in the script folder."; exit 1
    fi
}
FFMPEG=$(resolve_tool ffmpeg)
FFPROBE=$(resolve_tool ffprobe)
MKVMERGE=$(resolve_tool mkvmerge)

# ---- Argument check ----
if [ -z "$1" ]; then
    err "No file specified."
    echo "  Usage: ./drop_FILE_add_atmos_eac3.sh /path/to/movie.mkv"
    read -r -p "  Press Enter to close..."
    exit 1
fi

SOURCE="$1"
SOURCEDIR="$(dirname "$SOURCE")"
FILENAME="$(basename "$SOURCE")"
NAME="${FILENAME%.mkv}"

# ---- Validate input ----
if [ -d "$SOURCE" ]; then
    err "A folder was dropped onto this script."
    err "This script processes a single MKV file."
    read -r -p "  Press Enter to close..."
    exit 1
fi

if [ ! -f "$SOURCE" ]; then
    err "File not found: $SOURCE"
    read -r -p "  Press Enter to close..."
    exit 1
fi

WORKDIR="/tmp/dv-toolkit/${NAME}_atmos"
ATMOS_TRACKS_FILE="$WORKDIR/atmos_tracks.txt"
OUTPUT_MKV="$WORKDIR/output.mkv"
OUTPUT_FINAL="$SOURCEDIR/${NAME}_atmos_eac3.mkv"

echo ""
echo -e "${BOLD}  ================================================${NC}"
echo -e "${BOLD}  TrueHD Atmos → EAC3 Atmos Converter — macOS${NC}"
echo -e "${BOLD}  ================================================${NC}"
echo "  Source: $FILENAME"
echo ""

# ---- OneDrive / cloud storage notice ----
if echo "$SCRIPTDIR" | grep -qi "onedrive\|CloudStorage\|iCloud Drive"; then
    warn "Script is running from a cloud-synced folder."
    warn "Temporary files will be written to /tmp/dv-toolkit/ to avoid cloud sync."
    echo ""
fi

hdr "STEP 1 — Detecting TrueHD Atmos Tracks"
mkdir -p "$WORKDIR"

"$FFPROBE" -v quiet -show_streams -of json "$SOURCE" | \
    python3 -c "
import json, sys
data = json.load(sys.stdin)
audio_idx = 0
for s in data.get('streams', []):
    if s.get('codec_type') == 'audio':
        if s.get('codec_name') == 'truehd':
            title = s.get('tags', {}).get('title', '')
            lang = s.get('tags', {}).get('language', 'und')
            channels = s.get('channels', 0)
            if 'atmos' in title.lower():
                print(str(audio_idx) + '|' + lang + '|' + title + '|' + str(channels))
        audio_idx += 1
" > "$ATMOS_TRACKS_FILE"

ATMOS_COUNT=0
while IFS= read -r _LINE; do
    ((ATMOS_COUNT++)) || true
done < "$ATMOS_TRACKS_FILE"

if [ "$ATMOS_COUNT" -eq 0 ]; then
    warn "No TrueHD Atmos tracks found in this file."
    warn "Tracks must have 'Atmos' in their title tag to be detected."
    rm -rf "$WORKDIR"
    read -r -p "  Press Enter to close..."
    exit 0
fi

echo "  Found $ATMOS_COUNT TrueHD Atmos track(s):"
echo ""
while IFS='|' read -r AUDIO_IDX LANG TITLE CHANNELS; do
    echo "    Audio stream $AUDIO_IDX — $TITLE ($LANG, ${CHANNELS}ch)"
done < "$ATMOS_TRACKS_FILE"
echo ""
echo "  Output: ${NAME}_atmos_eac3.mkv"
echo "  Each TrueHD Atmos track will be converted to EAC3 Atmos and added alongside the original."
echo "  The original TrueHD track is kept."
echo ""
read -r -p "  Press Enter to continue or Ctrl+C to cancel..."
echo ""

hdr "STEP 2 — Converting to EAC3 Atmos"

declare -a EAC3_FILES
declare -a EAC3_LANGS
declare -a EAC3_TITLES
EAC3_COUNT=0

TRACK_NUM=0
while IFS='|' read -r AUDIO_IDX LANG TITLE CHANNELS; do
    ((TRACK_NUM++)) || true
    EAC3_FILE="$WORKDIR/atmos_${AUDIO_IDX}.eac3"

    if echo "$TITLE" | grep -qi "TrueHD"; then
        NEW_TITLE=$(echo "$TITLE" | sed 's/TrueHD/EAC3/g')
    else
        NEW_TITLE="${TITLE} EAC3"
    fi

    log "Track $TRACK_NUM of $ATMOS_COUNT: $TITLE → EAC3 at 768 kbps..."
    "$FFMPEG" -y -i "$SOURCE" -map "0:a:${AUDIO_IDX}" -c:a eac3 -b:a 768k "$EAC3_FILE" 2>/dev/null
    ok "Converted: $NEW_TITLE"

    EAC3_FILES[$EAC3_COUNT]="$EAC3_FILE"
    EAC3_LANGS[$EAC3_COUNT]="$LANG"
    EAC3_TITLES[$EAC3_COUNT]="$NEW_TITLE"
    ((EAC3_COUNT++)) || true
done < "$ATMOS_TRACKS_FILE"

hdr "STEP 3 — Remuxing"
log "Adding EAC3 tracks to MKV..."

MERGE_ARGS=("$MKVMERGE" -o "$OUTPUT_MKV" "$SOURCE")
IDX=0
for EAC3_FILE in "${EAC3_FILES[@]}"; do
    MERGE_ARGS+=(--language "0:${EAC3_LANGS[$IDX]}" --track-name "0:${EAC3_TITLES[$IDX]}" "$EAC3_FILE")
    ((IDX++)) || true
done

"${MERGE_ARGS[@]}"
ok "Remux complete."

hdr "STEP 4 — Finalise"

SOURCE_DEV=$(stat -f %d "$SOURCEDIR")
TMP_DEV=$(stat -f %d "$WORKDIR")

if [ "$SOURCE_DEV" = "$TMP_DEV" ]; then
    log "Moving output into place..."
    mv "$OUTPUT_MKV" "$OUTPUT_FINAL"
    ok "Done."
else
    log "Copying output to destination..."
    SRC_SIZE=$(stat -f%z "$OUTPUT_MKV")
    cp "$OUTPUT_MKV" "$OUTPUT_FINAL" &
    CP_PID=$!
    while kill -0 $CP_PID 2>/dev/null; do
        COPIED=$(stat -f%z "$OUTPUT_FINAL" 2>/dev/null || echo 0)
        PCT=$((COPIED * 100 / SRC_SIZE))
        printf "\r  %s GB / %s GB (%d%%)" \
            "$(awk "BEGIN{printf \"%.1f\", $COPIED/1073741824}")" \
            "$(awk "BEGIN{printf \"%.1f\", $SRC_SIZE/1073741824}")" \
            "$PCT"
        sleep 2
    done
    wait $CP_PID
    echo ""
    ok "Copied."
    rm "$OUTPUT_MKV"
fi

rm -rf "$WORKDIR"

OUTPUT_SIZE=$(du -sh "$OUTPUT_FINAL" | cut -f1)

echo ""
echo -e "${BOLD}  ================================================${NC}"
echo -e "${GREEN}${BOLD}  Complete.${NC}"
echo "  Output: ${NAME}_atmos_eac3.mkv ($OUTPUT_SIZE)"
echo -e "${BOLD}  ================================================${NC}"
echo ""
read -r -p "  Press Enter to close..."
echo ""
