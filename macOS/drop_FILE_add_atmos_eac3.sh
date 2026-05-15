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

caffeinate -i -w $$ &

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
LOCAL_SOURCE="$WORKDIR/$FILENAME"
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

hdr "STEP 1 — Detecting TrueHD Tracks"
mkdir -p "$WORKDIR"

# Output all TrueHD tracks; field 5 is 1 for Atmos, 0 for non-Atmos
# Atmos detection: ffprobe profile field (codec-level, most reliable) or title tag fallback
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
            profile = s.get('profile', '')
            is_atmos = '1' if ('atmos' in profile.lower() or 'atmos' in title.lower()) else '0'
            stream_index = s.get('index', 0)
            print(str(audio_idx) + '|' + lang + '|' + title + '|' + str(channels) + '|' + is_atmos + '|' + str(stream_index))
        audio_idx += 1
" > "$ATMOS_TRACKS_FILE"

ATMOS_COUNT=0
NON_ATMOS_COUNT=0
while IFS='|' read -r _IDX _LANG _TITLE _CH IS_ATMOS _SIDX; do
    if [ "$IS_ATMOS" == "1" ]; then
        ((ATMOS_COUNT++)) || true
    else
        ((NON_ATMOS_COUNT++)) || true
    fi
done < "$ATMOS_TRACKS_FILE"
TRUEHD_COUNT=$((ATMOS_COUNT + NON_ATMOS_COUNT))

if [ "$TRUEHD_COUNT" -eq 0 ]; then
    warn "No TrueHD tracks found in this file."
    rm -rf "$WORKDIR"
    read -r -p "  Press Enter to close..."
    exit 0
fi

# Show what was found and explain conversion intent
if [ "$ATMOS_COUNT" -gt 0 ]; then
    echo "  TrueHD Atmos track(s) — will be converted (Apple TV compatibility + size saving):"
    echo ""
    while IFS='|' read -r AUDIO_IDX LANG TITLE CHANNELS IS_ATMOS; do
        [ "$IS_ATMOS" == "1" ] && echo "    Audio stream $AUDIO_IDX — $TITLE ($LANG, ${CHANNELS}ch)"
    done < "$ATMOS_TRACKS_FILE"
    echo ""
fi

CONVERT_NON_ATMOS=0
if [ "$NON_ATMOS_COUNT" -gt 0 ]; then
    echo "  TrueHD track(s) without Atmos:"
    echo ""
    while IFS='|' read -r AUDIO_IDX LANG TITLE CHANNELS IS_ATMOS; do
        [ "$IS_ATMOS" == "0" ] && echo "    Audio stream $AUDIO_IDX — $TITLE ($LANG, ${CHANNELS}ch)"
    done < "$ATMOS_TRACKS_FILE"
    echo ""
    echo "  Converting to EAC3 at 768 kbps saves ~2–3 GB per 2-hour film."
    warn "This is lossy — purely a size saving, not a compatibility issue."
    echo ""
    read -r -p "  Convert non-Atmos TrueHD to EAC3 as well? [y/N]: " NON_ATMOS_CONV
    if [[ "$NON_ATMOS_CONV" == "y" || "$NON_ATMOS_CONV" == "Y" ]]; then
        CONVERT_NON_ATMOS=1
    fi
    echo ""
fi

if [ "$ATMOS_COUNT" -eq 0 ] && [ "$CONVERT_NON_ATMOS" == "0" ]; then
    echo "  Nothing to convert."
    rm -rf "$WORKDIR"
    read -r -p "  Press Enter to close..."
    exit 0
fi

echo ""
echo "  Add EAC3 alongside the original TrueHD, or replace it?"
echo "    [1] Add     — keep TrueHD, add EAC3 track (larger file, max compatibility)"
echo "    [2] Replace — remove TrueHD, EAC3 only (smaller file)"
echo ""
read -r -p "  Choice [1/2]: " ADD_OR_REPLACE
REPLACE_TRUEHD=0
if [ "$ADD_OR_REPLACE" == "2" ]; then
    REPLACE_TRUEHD=1
fi
echo ""

echo "  Output: ${NAME}_atmos_eac3.mkv"
if [ "$REPLACE_TRUEHD" == "1" ]; then
    echo "  Original TrueHD tracks will be removed."
else
    echo "  Original TrueHD tracks are kept alongside the new EAC3 tracks."
fi
echo ""
read -r -p "  Press Enter to continue or Ctrl+C to cancel..."
echo ""

hdr "STEP 2 — Copy"
log "Copying source file locally..."
mkdir -p "$WORKDIR"
rm -f "$LOCAL_SOURCE"
SOURCE_SIZE=$(stat -f%z "$SOURCE")
cp "$SOURCE" "$LOCAL_SOURCE" &
CP_PID=$!
while kill -0 $CP_PID 2>/dev/null; do
    COPIED=$(stat -f%z "$LOCAL_SOURCE" 2>/dev/null || echo 0)
    PCT=$((COPIED * 100 / SOURCE_SIZE))
    printf "\r  %s GB / %s GB (%d%%)" \
        "$(awk "BEGIN{printf \"%.1f\", $COPIED/1073741824}")" \
        "$(awk "BEGIN{printf \"%.1f\", $SOURCE_SIZE/1073741824}")" \
        "$PCT"
    sleep 2
done
wait $CP_PID
echo ""
ok "Copied: $FILENAME"

hdr "STEP 3 — Converting to EAC3"

declare -a EAC3_FILES
declare -a EAC3_LANGS
declare -a EAC3_TITLES
declare -a REPLACED_STREAM_IDXS
EAC3_COUNT=0

while IFS='|' read -r AUDIO_IDX LANG TITLE CHANNELS IS_ATMOS STREAM_IDX; do
    # Skip non-Atmos tracks if user declined
    if [ "$IS_ATMOS" == "0" ] && [ "$CONVERT_NON_ATMOS" == "0" ]; then
        continue
    fi

    EAC3_FILE="$WORKDIR/track_${AUDIO_IDX}.eac3"

    if echo "$TITLE" | grep -qi "TrueHD"; then
        NEW_TITLE=$(echo "$TITLE" | sed 's/TrueHD/EAC3/g')
    else
        NEW_TITLE="${TITLE} EAC3"
    fi

    if [ "$IS_ATMOS" == "1" ]; then
        log "Converting (Atmos): $TITLE → EAC3 at 768 kbps..."
    else
        log "Converting (size saving): $TITLE → EAC3 at 768 kbps..."
    fi
    "$FFMPEG" -y -i "$LOCAL_SOURCE" -map "0:a:${AUDIO_IDX}" -c:a eac3 -b:a 768k "$EAC3_FILE" 2>/dev/null
    ok "Converted: $NEW_TITLE"

    EAC3_FILES[$EAC3_COUNT]="$EAC3_FILE"
    EAC3_LANGS[$EAC3_COUNT]="$LANG"
    EAC3_TITLES[$EAC3_COUNT]="$NEW_TITLE"
    REPLACED_STREAM_IDXS[$EAC3_COUNT]="$STREAM_IDX"
    ((EAC3_COUNT++)) || true
done < "$ATMOS_TRACKS_FILE"

hdr "STEP 4 — Remuxing"
log "Adding EAC3 tracks to MKV..."

if [ "$REPLACE_TRUEHD" == "1" ]; then
    EXCL=""
    for SIDX in "${REPLACED_STREAM_IDXS[@]}"; do
        EXCL="${EXCL}!${SIDX},"
    done
    MERGE_ARGS=("$MKVMERGE" -o "$OUTPUT_MKV" --audio-tracks "${EXCL%,}" "$LOCAL_SOURCE")
else
    MERGE_ARGS=("$MKVMERGE" -o "$OUTPUT_MKV" "$LOCAL_SOURCE")
fi
IDX=0
for EAC3_FILE in "${EAC3_FILES[@]}"; do
    MERGE_ARGS+=(--language "0:${EAC3_LANGS[$IDX]}" --track-name "0:${EAC3_TITLES[$IDX]}" "$EAC3_FILE")
    ((IDX++)) || true
done

"${MERGE_ARGS[@]}"
ok "Remux complete."
rm "$LOCAL_SOURCE"

hdr "STEP 5 — Finalise"

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
