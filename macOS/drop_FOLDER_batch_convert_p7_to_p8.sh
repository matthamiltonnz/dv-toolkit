#!/bin/bash

# =============================================================
#  Dolby Vision Batch Converter for macOS
#  - Scans a folder recursively for DV Profile 7 files
#  - Converts each P7 file to Profile 8 (remux only, no re-encode)
#  - Original files are replaced in-place with the same filename
#  - All audio and subtitle tracks are preserved
#
#  Usage:
#    ./drop_FOLDER_batch_convert_p7_to_p8.sh /path/to/folder
#    Or drag a folder onto the Automator app wrapper
#
#  Required tools:
#    brew install ffmpeg mkvtoolnix
#    dovi_tool: https://github.com/quietvoid/dovi_tool/releases
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
LOGFILE="$HOME/Desktop/batch_convert_log.txt"

# ---- Disk helpers ----
get_device()  { stat -f %d "$1" 2>/dev/null; }
get_free_kb() { df -k "$1" | awk 'NR==2{print $4}'; }
get_size_kb() { du -sk "$1" | awk '{print $1}'; }
fmt_gb()      { awk "BEGIN{printf \"%.1f GB\", $1/1048576}"; }

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
DOVI=$(resolve_tool dovi_tool)
MKVMERGE=$(resolve_tool mkvmerge)

# ---- Argument check ----
if [ -z "$1" ]; then
    err "No folder specified."
    echo "  Usage: ./drop_FOLDER_batch_convert_p7_to_p8.sh /path/to/folder"
    read -r -p "  Press Enter to close..."
    exit 1
fi

SCANDIR="$1"

if [ -f "$SCANDIR" ]; then
    err "A file was dropped onto this script. This script converts all P7 files in a folder."
    err "To convert a single file, use drop_FILE_convert_compress.sh instead."
    read -r -p "  Press Enter to close..."
    exit 1
fi

if [ ! -d "$SCANDIR" ]; then
    err "Folder not found: $SCANDIR"
    read -r -p "  Press Enter to close..."
    exit 1
fi

echo ""
echo -e "${BOLD}  ================================================${NC}"
echo -e "${BOLD}  Dolby Vision Batch Converter — macOS${NC}"
echo -e "${BOLD}  ================================================${NC}"
echo "  Folder: $SCANDIR"
echo "  Log:    $LOGFILE"
echo ""

# ---- OneDrive / cloud storage notice ----
if echo "$SCRIPTDIR" | grep -qi "onedrive\|CloudStorage\|iCloud Drive"; then
    warn "Script is running from a cloud-synced folder."
    warn "Temporary conversion files will be written to /tmp/dv-toolkit/"
    warn "to avoid syncing large intermediate files to the cloud."
    echo ""
fi

echo -e "${YELLOW}  ⚠ WARNING: ALL Profile 7 files found in this folder will be converted.${NC}"
echo "  Original files will be DELETED after successful conversion."
echo "  Converted files will replace originals with the same filename."
echo "  Recommend making a backup of your files before proceeding."
echo ""
read -r -p "  Type YES to continue or press Ctrl+C to cancel: " CONFIRM
if [ "$CONFIRM" != "YES" ]; then
    echo "  Cancelled."
    exit 0
fi
echo ""

# ---- Initialise log ----
{
    echo "Dolby Vision Batch Convert Log"
    echo "Folder: $SCANDIR"
    echo "Started: $(date)"
    echo "----------------------------------------"
} > "$LOGFILE"

SCAN_COUNT=0
CONVERT_COUNT=0
SKIP_COUNT=0
ERROR_COUNT=0

# ---- Conversion function ----
convert_file() {
    local SOURCE="$1"
    local SOURCEDIR
    SOURCEDIR="$(dirname "$SOURCE")"
    local FILENAME
    FILENAME="$(basename "$SOURCE")"
    local NAME="${FILENAME%.mkv}"

    local WORKDIR="/tmp/dv-toolkit/$NAME"
    local LOCAL_SOURCE="$WORKDIR/$FILENAME"
    local BL="$WORKDIR/bl.hevc"
    local EL="$WORKDIR/el.hevc"
    local RPU="$WORKDIR/rpu.bin"
    local CLEAN_BL="$WORKDIR/clean_bl.hevc"
    local INJECTED_HEVC="$WORKDIR/injected.hevc"
    local OUTPUT_MKV="$WORKDIR/output.mkv"
    local FINAL="$SOURCEDIR/$FILENAME"

    echo "" >> "$LOGFILE"
    echo "CONVERTING: $SOURCE" >> "$LOGFILE"

    # ---- Disk locality and free space check ----
    local SOURCE_DEV WORK_DEV FILE_KB FREE_KB NEEDED_KB IS_LOCAL
    SOURCE_DEV=$(get_device "$SOURCE")
    WORK_DEV=$(get_device "$SCRIPTDIR")
    FILE_KB=$(get_size_kb "$SOURCE")

    if [ "$SOURCE_DEV" = "$WORK_DEV" ]; then
        IS_LOCAL=1
        NEEDED_KB=$((FILE_KB * 2))
        log "Source is on local disk — will hard-link instead of copying ($(fmt_gb $FILE_KB))."
    else
        IS_LOCAL=0
        NEEDED_KB=$((FILE_KB * 3))
        log "Source is on a separate volume — will copy locally first ($(fmt_gb $FILE_KB))."
    fi

    FREE_KB=$(get_free_kb "$SCRIPTDIR")
    log "Space check: need $(fmt_gb $NEEDED_KB), available $(fmt_gb $FREE_KB)."
    if [ "$FREE_KB" -lt "$NEEDED_KB" ]; then
        err "Insufficient disk space — skipping."
        err "  Need $(fmt_gb $NEEDED_KB), only $(fmt_gb $FREE_KB) free on work disk."
        echo "STATUS: SKIPPED (insufficient disk space — need $(fmt_gb $NEEDED_KB), have $(fmt_gb $FREE_KB))" >> "$LOGFILE"
        return 1
    fi

    log "Creating working directory..."
    mkdir -p "$WORKDIR"

    if [ "$IS_LOCAL" = "1" ]; then
        log "Hard-linking source (no copy needed)..."
        ln "$SOURCE" "$LOCAL_SOURCE"
        ok "Linked."
    else
        log "Copying source file locally (rsync)..."
        rsync --progress "$SOURCE" "$LOCAL_SOURCE"
        ok "Copied."
    fi

    hdr "STEP 2 — Track Inspection"
    local PROBE
    PROBE=$("$FFPROBE" -v quiet -show_streams -of json "$LOCAL_SOURCE")
    local VIDEO_TRACKS
    VIDEO_TRACKS=$(echo "$PROBE" | grep -c '"codec_type": "video"')
    local DV_PROFILE
    DV_PROFILE=$(echo "$PROBE" | grep '"dv_profile"' | head -1 | tr -d ' ",' | cut -d: -f2)

    echo "  Video tracks: $VIDEO_TRACKS  DV Profile: ${DV_PROFILE:-none}"

    hdr "STEP 3 — DV Metadata Extraction"

    if [ "$VIDEO_TRACKS" -ge 2 ]; then
        log "Dual-track source (P7 with EL) — extracting base and enhancement layers..."
        "$FFMPEG" -y -i "$LOCAL_SOURCE" -map 0:v:0 -c:v copy -an -f hevc "$BL" 2>/dev/null
        ok "Base layer extracted."
        "$FFMPEG" -y -i "$LOCAL_SOURCE" -map 0:v:1 -c:v copy -an -f hevc "$EL" 2>/dev/null
        ok "Enhancement layer extracted."
        log "Extracting RPU from enhancement layer..."
        "$DOVI" extract-rpu -i "$EL" -o "$RPU"
        ok "RPU extracted."
        rm "$EL"
        log "Injecting RPU into base layer and converting to Profile 8..."
        "$DOVI" inject-rpu -i "$BL" --rpu-in "$RPU" -o "$CLEAN_BL"
        rm "$BL" "$RPU"
        "$DOVI" -m 2 convert --discard -i "$CLEAN_BL" -o "$BL"
        rm "$CLEAN_BL"
        ok "Converted to Profile 8."
    else
        log "Single-track Profile 7 — converting to Profile 8..."
        "$FFMPEG" -y -i "$LOCAL_SOURCE" -map 0:v:0 -c:v copy -an -f hevc "$BL" 2>/dev/null
        "$DOVI" -m 2 convert --discard -i "$BL" -o "$CLEAN_BL"
        mv "$CLEAN_BL" "$BL"
        ok "Converted to Profile 8."
    fi

    hdr "STEP 4 — RPU Extraction & Injection"
    log "Extracting RPU from prepared base layer..."
    "$DOVI" extract-rpu -i "$BL" -o "$RPU"
    ok "RPU ready."
    log "Injecting Profile 8 RPU..."
    "$DOVI" inject-rpu -i "$BL" --rpu-in "$RPU" -o "$INJECTED_HEVC"
    ok "RPU injected."
    rm "$BL" "$RPU"

    hdr "STEP 5 — Remux"
    log "Remuxing with all audio and subtitle tracks..."
    "$MKVMERGE" -o "$OUTPUT_MKV" \
        "$INJECTED_HEVC" \
        --no-video \
        "$LOCAL_SOURCE"
    ok "Remux complete."
    rm "$INJECTED_HEVC" "$LOCAL_SOURCE"

    hdr "STEP 6 — Finalise"
    log "Renaming original to .bak..."
    mv "$SOURCE" "${SOURCE}.bak"
    ok "Original renamed."

    if [ "$IS_LOCAL" = "1" ]; then
        log "Moving converted file into place..."
        mv "$OUTPUT_MKV" "$FINAL"
    else
        log "Copying converted file back..."
        rsync --progress "$OUTPUT_MKV" "$FINAL"
        rm "$OUTPUT_MKV"
    fi
    ok "File in place."

    log "Deleting original .bak..."
    rm "${SOURCE}.bak"
    ok "Original deleted."

    rm -rf "$WORKDIR"
}

# ---- Main scan loop ----
hdr "Scanning for Profile 7 files..."
echo ""

while IFS= read -r -d '' FILE; do
    ((SCAN_COUNT++)) || true
    BASENAME=$(basename "$FILE")
    echo ""
    echo "  [$SCAN_COUNT] Checking: $BASENAME"

    PROFILE=$("$FFPROBE" -v quiet -show_streams -of json "$FILE" | \
        python3 -c "
import json,sys
data=json.load(sys.stdin)
for s in data.get('streams',[]):
    for sd in s.get('side_data_list',[]):
        if 'dv_profile' in sd:
            print(sd['dv_profile'])
            exit()
" 2>/dev/null)

    if [ "$PROFILE" == "7" ]; then
        echo -e "    ${RED}Profile 7 detected — converting...${NC}"
        if convert_file "$FILE"; then
            ok "SUCCESS: $BASENAME"
            echo "STATUS: SUCCESS" >> "$LOGFILE"
            ((CONVERT_COUNT++)) || true
        else
            err "FAILED: $BASENAME"
            echo "STATUS: FAILED" >> "$LOGFILE"
            ((ERROR_COUNT++)) || true
        fi
    elif [ -z "$PROFILE" ]; then
        echo "    No DV profile detected — skipping."
        ((SKIP_COUNT++)) || true
    else
        echo "    Profile $PROFILE — skipping."
        ((SKIP_COUNT++)) || true
    fi

done < <(find "$SCANDIR" \( -name "*.mkv" -o -name "*.mp4" -o -name "*.ts" \) -print0)

# ---- Finalise log ----
{
    echo ""
    echo "----------------------------------------"
    echo "Completed: $(date)"
    echo "Scanned:   $SCAN_COUNT"
    echo "Converted: $CONVERT_COUNT"
    echo "Skipped:   $SKIP_COUNT"
    echo "Errors:    $ERROR_COUNT"
} >> "$LOGFILE"

# ---- Summary ----
echo ""
echo -e "${BOLD}  ================================================${NC}"
if [ "$ERROR_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}${BOLD}  Batch complete — with errors.${NC}"
else
    echo -e "${GREEN}${BOLD}  Batch complete.${NC}"
fi
echo "  Scanned:   $SCAN_COUNT"
echo "  Converted: $CONVERT_COUNT"
echo "  Skipped:   $SKIP_COUNT"
[ "$ERROR_COUNT" -gt 0 ] && echo -e "  ${RED}Errors:    $ERROR_COUNT${NC}"
echo ""
echo "  Log saved to: $LOGFILE"
echo -e "${BOLD}  ================================================${NC}"
echo ""
read -r -p "  Press Enter to close..."
echo ""
