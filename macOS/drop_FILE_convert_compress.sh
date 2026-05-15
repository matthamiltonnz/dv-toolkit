#!/bin/bash

# =============================================================
#  DV P7/P8 Converter & Compressor for macOS
#  - Converts DV Profile 7 to Profile 8 if needed
#  - Remux-only mode: P7→P8 without re-encoding
#  - HEVC mode: re-encodes using Apple VideoToolbox hardware
#  - AV1 mode: re-encodes using SVT-AV1 (CPU), retains DV as Profile 10
#
#  Usage:
#    ./drop_FILE_convert_compress.sh /path/to/movie.mkv         # interactive
#    ./drop_FILE_convert_compress.sh /path/to/movie.mkv remux   # remux only
#    ./drop_FILE_convert_compress.sh /path/to/movie.mkv 25      # HEVC at 25 Mbps
#    ./drop_FILE_convert_compress.sh /path/to/movie.mkv av1     # AV1 default CRF
#    ./drop_FILE_convert_compress.sh /path/to/movie.mkv av1 27  # AV1 custom CRF
#
#  Required tools:
#    brew install ffmpeg mkvtoolnix
#    dovi_tool: https://github.com/quietvoid/dovi_tool/releases
#
#  AV1 mode also requires ffmpeg built with libsvtav1 + dolbyvision support.
#  See AV1 setup notes below, or run this script and choose AV1 for instructions.
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

# ---- Arguments ----
if [ -z "$1" ]; then
    err "No file specified."
    echo "  Usage: ./drop_FILE_convert_compress.sh /path/to/movie.mkv [remux|bitrate_mbps|av1 [crf]]"
    read -r -p "  Press Enter to close..."
    exit 1
fi

SOURCE="$1"
SOURCEDIR="$(dirname "$SOURCE")"
NAME="$(basename "$SOURCE" .mkv)"
FILENAME="$(basename "$SOURCE")"
MODE_ARG="${2:-}"
AV1_CRF_ARG="${3:-}"

# ---- Paths ----
SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="/tmp/dv-toolkit/$NAME"
LOCAL_SOURCE="$WORKDIR/$FILENAME"
BL="$WORKDIR/bl.hevc"
EL="$WORKDIR/el.hevc"
RPU="$WORKDIR/rpu.bin"
CLEAN_BL="$WORKDIR/clean_bl.hevc"
ENCODED_HEVC="$WORKDIR/encoded.hevc"
STRIPPED_HEVC="$WORKDIR/stripped.hevc"
INJECTED_HEVC="$WORKDIR/injected.hevc"
ENCODED_AV1="$WORKDIR/encoded.ivf"
OUTPUT_MKV="$WORKDIR/output.mkv"

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

if [ -d "$SOURCE" ]; then
    err "A folder was dropped onto this script. This script converts a single video file."
    err "To batch-convert a folder, use drop_FOLDER_batch_convert_p7_to_p8.sh instead."
    read -r -p "  Press Enter to close..."
    exit 1
fi

if [ ! -f "$SOURCE" ]; then
    err "Source file not found: $SOURCE"
    read -r -p "  Press Enter to close..."
    exit 1
fi

# ---- Check AV1 + DV support in ffmpeg ----
check_av1_dv_support() {
    if ! "$FFMPEG" -encoders 2>/dev/null | grep -q libsvtav1; then
        return 1
    fi
    if ! "$FFMPEG" -h encoder=libsvtav1 2>/dev/null | grep -q dolbyvision; then
        return 2
    fi
    return 0
}

# ---- Header ----
echo ""
echo -e "${BOLD}  ================================================${NC}"
echo -e "${BOLD}  DV P7/P8 Converter & Compressor — macOS${NC}"
echo -e "${BOLD}  ================================================${NC}"
echo "  Source: $FILENAME"
echo ""

# ---- OneDrive / cloud storage notice ----
if echo "$SCRIPTDIR" | grep -qi "onedrive\|CloudStorage\|iCloud Drive"; then
    warn "Script is running from a cloud-synced folder."
    warn "Temporary conversion files will be written to /tmp/dv-toolkit/"
    warn "to avoid syncing large intermediate files to the cloud."
    warn "For best results, move the toolkit to a local folder:"
    warn "  ~/Desktop/DV-Toolkit  or  ~/DV-Toolkit"
    echo ""
fi

# ---- Early DV profile check ----
log "Checking Dolby Vision profile..."
DV_PROFILE_EARLY=$("$FFPROBE" -v quiet -show_streams -of json "$SOURCE" | \
    python3 -c "
import json,sys
data=json.load(sys.stdin)
for s in data.get('streams',[]):
    for sd in s.get('side_data_list',[]):
        if 'dv_profile' in sd:
            print(sd['dv_profile'])
            sys.exit()
" 2>/dev/null)

if [ -z "$DV_PROFILE_EARLY" ]; then
    warn "No Dolby Vision profile detected in this file."
    warn "This script is intended for DV content."
    echo ""
    read -r -p "  Continue anyway? [y/N]: " DV_CONT
    if [[ "$DV_CONT" != "y" && "$DV_CONT" != "Y" ]]; then
        echo "  Cancelled."
        exit 0
    fi
    echo ""
else
    ok "DV Profile $DV_PROFILE_EARLY detected."
    echo ""
fi

# ---- Check existing bitrate ----
CURRENT_BITRATE_KBPS=$("$FFPROBE" -v quiet -show_streams -select_streams v:0 -of json "$SOURCE" | \
    python3 -c "
import json,sys
data=json.load(sys.stdin)
for s in data.get('streams',[]):
    br = s.get('bit_rate') or s.get('tags',{}).get('BPS')
    if br:
        print(int(br)//1000)
        sys.exit()
" 2>/dev/null)

if [ -n "$CURRENT_BITRATE_KBPS" ]; then
    CURRENT_BITRATE_MBPS=$((CURRENT_BITRATE_KBPS / 1000))
    ok "Video bitrate: ~${CURRENT_BITRATE_MBPS} Mbps"
    echo ""
fi

# ---- Mode selection ----
REMUX_ONLY=0
HEVC_MODE=0
AV1_MODE=0
TARGET_MBPS=25
AV1_CRF=27

if [ "$MODE_ARG" == "remux" ]; then
    if [ "$DV_PROFILE_EARLY" != "7" ]; then
        err "Remux mode converts Profile 7 to Profile 8. This file is Profile ${DV_PROFILE_EARLY:-unknown}."
        read -r -p "  Press Enter to close..."
        exit 1
    fi
    REMUX_ONLY=1
elif [ "$MODE_ARG" == "av1" ]; then
    AV1_MODE=1
    [ -n "$AV1_CRF_ARG" ] && AV1_CRF="$AV1_CRF_ARG"
elif [[ "$MODE_ARG" =~ ^[0-9]+$ ]]; then
    HEVC_MODE=1
    TARGET_MBPS="$MODE_ARG"
else
    # Interactive prompt — options depend on source profile
    echo "  Select mode:"
    if [ "$DV_PROFILE_EARLY" == "7" ]; then
        echo "    [1] Remux only — convert P7→P8, no re-encode"
        echo "    [2] HEVC       — re-encode with Apple VideoToolbox at target bitrate"
        echo "    [3] AV1        — re-encode with SVT-AV1 (CPU), DV Profile 10 output"
        echo "                     ⚠ Experimental — requires compatible ffmpeg build"
        echo "                     ⚠ No hardware AV1 decode on current Apple TV hardware"
        echo ""
        read -r -p "  Choice [1/2/3]: " MODE_CHOICE

        case "$MODE_CHOICE" in
            1) REMUX_ONLY=1 ;;
            3) AV1_MODE=1
               echo ""
               echo "  AV1 CRF reference (lower = better quality, larger file):"
               echo "    22 = very high quality  (~12GB / 2hr)"
               echo "    27 = iTunes equivalent  (~8GB / 2hr)   ← default"
               echo "    32 = streaming quality  (~5GB / 2hr)"
               echo ""
               read -r -p "  CRF value [27]: " CRF_INPUT
               AV1_CRF="${CRF_INPUT:-27}"
               ;;
            *) HEVC_MODE=1
               echo ""
               echo "  Bitrate targets:"
               echo "    15 Mbps = Amazon Prime quality  (~14GB / 2hr)"
               echo "    22 Mbps = Apple iTunes quality  (~20GB / 2hr)"
               echo "    25 Mbps = Apple TV+ quality     (~23GB / 2hr)  ← default"
               echo "    31 Mbps = iTunes peak quality   (~28GB / 2hr)"
               [ -n "$CURRENT_BITRATE_MBPS" ] && echo "    Source bitrate: ~${CURRENT_BITRATE_MBPS} Mbps"
               echo ""
               read -r -p "  Target bitrate in Mbps [25]: " MBPS_INPUT
               TARGET_MBPS="${MBPS_INPUT:-25}"
               if [ -n "$CURRENT_BITRATE_MBPS" ] && [ "$TARGET_MBPS" -ge "$CURRENT_BITRATE_MBPS" ]; then
                   echo ""
                   warn "Target (${TARGET_MBPS} Mbps) is at or above source bitrate (~${CURRENT_BITRATE_MBPS} Mbps)."
                   warn "Compression will increase file size with no quality benefit."
                   read -r -p "  Continue anyway? [y/N]: " BR_CONT
                   if [[ "$BR_CONT" != "y" && "$BR_CONT" != "Y" ]]; then
                       echo "  Cancelled."
                       exit 0
                   fi
               fi
               ;;
        esac
    else
        echo "  File is DV Profile $DV_PROFILE_EARLY — remux not needed, compression only."
        echo ""
        echo "    [1] HEVC — re-encode with Apple VideoToolbox at target bitrate"
        echo "    [2] AV1  — re-encode with SVT-AV1 (CPU), DV Profile 10 output"
        echo "               ⚠ Experimental — requires compatible ffmpeg build"
        echo "               ⚠ No hardware AV1 decode on current Apple TV hardware"
        echo "    [3] Exit — do nothing"
        echo ""
        read -r -p "  Choice [1/2/3]: " MODE_CHOICE

        case "$MODE_CHOICE" in
            3) echo "  Nothing to do."
               read -r -p "  Press Enter to close..."
               exit 0
               ;;
            2) AV1_MODE=1
               echo ""
               echo "  AV1 CRF reference (lower = better quality, larger file):"
               echo "    22 = very high quality  (~12GB / 2hr)"
               echo "    27 = iTunes equivalent  (~8GB / 2hr)   ← default"
               echo "    32 = streaming quality  (~5GB / 2hr)"
               echo ""
               read -r -p "  CRF value [27]: " CRF_INPUT
               AV1_CRF="${CRF_INPUT:-27}"
               ;;
            *) HEVC_MODE=1
               echo ""
               echo "  Bitrate targets:"
               echo "    15 Mbps = Amazon Prime quality  (~14GB / 2hr)"
               echo "    22 Mbps = Apple iTunes quality  (~20GB / 2hr)"
               echo "    25 Mbps = Apple TV+ quality     (~23GB / 2hr)  ← default"
               echo "    31 Mbps = iTunes peak quality   (~28GB / 2hr)"
               [ -n "$CURRENT_BITRATE_MBPS" ] && echo "    Source bitrate: ~${CURRENT_BITRATE_MBPS} Mbps"
               echo ""
               read -r -p "  Target bitrate in Mbps [25]: " MBPS_INPUT
               TARGET_MBPS="${MBPS_INPUT:-25}"
               if [ -n "$CURRENT_BITRATE_MBPS" ] && [ "$TARGET_MBPS" -ge "$CURRENT_BITRATE_MBPS" ]; then
                   echo ""
                   warn "Target (${TARGET_MBPS} Mbps) is at or above source bitrate (~${CURRENT_BITRATE_MBPS} Mbps)."
                   warn "Compression will increase file size with no quality benefit."
                   read -r -p "  Continue anyway? [y/N]: " BR_CONT
                   if [[ "$BR_CONT" != "y" && "$BR_CONT" != "Y" ]]; then
                       echo "  Cancelled."
                       exit 0
                   fi
               fi
               ;;
        esac
    fi
fi

# ---- Validate AV1 support if needed ----
if [ "$AV1_MODE" == "1" ]; then
    check_av1_dv_support
    AV1_CHECK=$?
    if [ "$AV1_CHECK" != "0" ]; then
        echo ""
        echo -e "${YELLOW}  ================================================${NC}"
        echo -e "${YELLOW}  AV1 + Dolby Vision encoding is not available.${NC}"
        echo -e "${YELLOW}  ================================================${NC}"
        echo ""
        if [ "$AV1_CHECK" == "1" ]; then
            echo "  Your ffmpeg does not include libsvtav1."
        else
            echo "  Your ffmpeg has libsvtav1 but it was built without Dolby Vision support."
        fi
        echo ""
        echo "  To enable AV1 + DV encoding, you need a custom ffmpeg build."
        echo "  The standard 'brew install ffmpeg' does not include this."
        echo ""
        echo "  Option 1 — Build ffmpeg from source with SVT-AV1:"
        echo "    brew install svt-av1 pkg-config"
        echo "    See: https://ercan.dev/blog/notes/build-ffmpeg-from-source-on-macos"
        echo "    Ensure you pass --enable-libsvtav1 during ./configure"
        echo ""
        echo "  Option 2 — Use a pre-built ffmpeg with extra codecs:"
        echo "    brew tap homebrew-ffmpeg/ffmpeg"
        echo "    brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-svt-av1"
        echo ""
        echo "  Once installed, verify support with:"
        echo "    ffmpeg -encoders | grep svtav1"
        echo "    ffmpeg -h encoder=libsvtav1 | grep dolbyvision"
        echo ""
        read -r -p "  Press Enter to close..."
        exit 1
    fi
fi

# ---- Set output path and display mode ----
TARGET_BITRATE="${TARGET_MBPS}M"
MAX_BITRATE="$((TARGET_MBPS * 2))M"
BUF_SIZE="$((TARGET_MBPS * 4))M"

if [ "$REMUX_ONLY" == "1" ]; then
    FINAL="$SOURCEDIR/$FILENAME"
    echo "  Mode:    Remux only (P7→P8, no re-encode)"
    echo "  Output:  $FILENAME (replaces original)"
elif [ "$AV1_MODE" == "1" ]; then
    FINAL="$SOURCEDIR/${NAME}_av1_crf${AV1_CRF}.mkv"
    echo "  Mode:    AV1 / SVT-AV1 (CPU) — DV Profile 10 output"
    echo "  CRF:     $AV1_CRF  Preset: 6"
    echo "  Output:  ${NAME}_av1_crf${AV1_CRF}.mkv"
    echo ""
    warn "AV1 is CPU encoded — expect several hours for a 4K film on M5."
    warn "Output is DV Profile 10 — playback compatibility is limited."
    warn "Current Apple TV 4K (2022) has no AV1 hardware decode."
else
    FINAL="$SOURCEDIR/${NAME}_${TARGET_MBPS}mbps.mkv"
    echo "  Mode:    HEVC / VideoToolbox — DV Profile 8 output"
    echo "  Bitrate: ${TARGET_MBPS} Mbps"
    echo "  Output:  ${NAME}_${TARGET_MBPS}mbps.mkv"
    echo "  Note:    Original kept — compare quality before deleting."
fi
echo ""

# ---- Deletion warning for remux mode only ----
if [ "$REMUX_ONLY" == "1" ]; then
    echo -e "${YELLOW}  ⚠ WARNING: The original source file will be DELETED after successful conversion.${NC}"
    echo "  The converted file will replace it with the same filename."
    echo "  Make a backup of the original first if you need to keep it."
    echo ""
    read -r -p "  Type YES to continue or Ctrl+C to cancel: " CONFIRM
    if [ "${CONFIRM}" != "YES" ]; then
        echo "  Cancelled."
        exit 0
    fi
    echo ""
fi

# ---- Create work folder ----
hdr "STEP 1 — Setup"
log "Creating working directory..."
mkdir -p "$WORKDIR"
ok "Workdir: $WORKDIR"

# ---- Copy source locally ----
log "Copying source file locally..."
rm -f "$LOCAL_SOURCE"
SOURCE_SIZE=$(stat -f%z "$SOURCE")
cp "$SOURCE" "$LOCAL_SOURCE" &
CP_PID=$!
while kill -0 $CP_PID 2>/dev/null; do
    COPIED=$(stat -f%z "$LOCAL_SOURCE" 2>/dev/null || echo 0)
    PCT=$((COPIED * 100 / SOURCE_SIZE))
    COPIED_GB=$(awk "BEGIN{printf \"%.1f\", $COPIED/1073741824}")
    TOTAL_GB=$(awk "BEGIN{printf \"%.1f\", $SOURCE_SIZE/1073741824}")
    printf "\r  %s GB / %s GB (%d%%)" "$COPIED_GB" "$TOTAL_GB" "$PCT"
    sleep 2
done
wait $CP_PID
echo ""
ok "Copied: $FILENAME"

# ---- Inspect tracks ----
hdr "STEP 2 — Track Inspection"
log "Reading stream information..."
echo ""

PROBE=$("$FFPROBE" -v quiet -show_streams -of json "$LOCAL_SOURCE")
VIDEO_TRACKS=$(echo "$PROBE" | grep -c '"codec_type": "video"')
DV_PROFILE=$(echo "$PROBE" | grep '"dv_profile"' | head -1 | tr -d ' ",' | cut -d: -f2)

echo "  Video tracks:   $VIDEO_TRACKS"
echo "  DV Profile:     ${DV_PROFILE:-none detected}"
echo ""

# ---- List audio tracks ----
echo "  Audio tracks:"
AUDIO_COUNT=0
declare -a AUDIO_INFO
while IFS= read -r line; do
    INDEX=$(echo "$line" | grep -o '"index": [0-9]*' | head -1 | awk '{print $2}')
    CODEC=$(echo "$line" | grep -o '"codec_name": "[^"]*"' | head -1 | cut -d'"' -f4)
    LANG=$(echo "$line" | grep -o '"language": "[^"]*"' | cut -d'"' -f4)
    TITLE=$(echo "$line" | grep -o '"title": "[^"]*"' | cut -d'"' -f4)
    CHANNELS=$(echo "$line" | grep -o '"channels": [0-9]*' | awk '{print $2}')
    echo "    [$AUDIO_COUNT] Track $INDEX — $CODEC ${CHANNELS}ch  lang:${LANG:-unknown}  ${TITLE}"
    AUDIO_INFO[$AUDIO_COUNT]="$INDEX"
    ((AUDIO_COUNT++)) || true
done < <("$FFPROBE" -v quiet -show_streams -select_streams a -of json "$LOCAL_SOURCE" | \
    python3 -c "
import json,sys
data=json.load(sys.stdin)
for s in data['streams']:
    tags=s.get('tags',{})
    print(json.dumps({**s,'language':tags.get('language',''),'title':tags.get('title','')}))
")
echo ""

# ---- List subtitle tracks ----
echo "  Subtitle tracks:"
SUB_COUNT=0
declare -a SUB_INFO
while IFS= read -r line; do
    INDEX=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['index'])" 2>/dev/null)
    CODEC=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('codec_name',''))" 2>/dev/null)
    LANG=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tags',{}).get('language',''))" 2>/dev/null)
    TITLE=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tags',{}).get('title',''))" 2>/dev/null)
    echo "    [$SUB_COUNT] Track $INDEX — $CODEC  lang:${LANG:-unknown}  ${TITLE}"
    SUB_INFO[$SUB_COUNT]="$INDEX"
    ((SUB_COUNT++)) || true
done < <("$FFPROBE" -v quiet -show_streams -select_streams s -of json "$LOCAL_SOURCE" | \
    python3 -c "
import json,sys
data=json.load(sys.stdin)
for s in data['streams']:
    print(json.dumps(s))
")
echo ""

# ---- Track selection ----
hdr "STEP 3 — Track Selection"
echo "  Enter the numbers of the audio tracks to KEEP (space separated)."
echo "  Example: 0 2  (keeps first and third audio tracks)"
echo "  Press Enter to keep ALL audio tracks."
echo ""
read -r -p "  Audio tracks to keep: " AUDIO_CHOICE

echo ""
echo "  Enter the numbers of the subtitle tracks to KEEP (space separated)."
echo "  Press Enter to keep ALL.  Type NONE to strip all subtitles."
echo ""
read -r -p "  Subtitle tracks to keep: " SUB_CHOICE

# ---- Build mkvmerge track args ----
AUDIO_ARGS=""
if [ -n "$AUDIO_CHOICE" ]; then
    KEEP_AUDIO_TRACKS=""
    for N in $AUDIO_CHOICE; do
        IDX="${AUDIO_INFO[$N]}"
        KEEP_AUDIO_TRACKS="${KEEP_AUDIO_TRACKS}${IDX},"
    done
    AUDIO_ARGS="--audio-tracks ${KEEP_AUDIO_TRACKS%,}"
fi

SUB_ARGS=""
SUB_CHOICE_UPPER=$(echo "$SUB_CHOICE" | tr '[:lower:]' '[:upper:]')
if [ "$SUB_CHOICE_UPPER" == "NONE" ]; then
    SUB_ARGS="--no-subtitles"
elif [ -n "$SUB_CHOICE" ]; then
    KEEP_SUB_TRACKS=""
    for N in $SUB_CHOICE; do
        IDX="${SUB_INFO[$N]}"
        KEEP_SUB_TRACKS="${KEEP_SUB_TRACKS}${IDX},"
    done
    SUB_ARGS="--subtitle-tracks ${KEEP_SUB_TRACKS%,}"
fi

echo ""
ok "Track selection confirmed."

# ---- Extract and prepare base layer ----
hdr "STEP 4 — DV Metadata Extraction"

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
    if [ "$DV_PROFILE" == "7" ]; then
        log "Single-track Profile 7 — converting to Profile 8..."
        "$FFMPEG" -y -i "$LOCAL_SOURCE" -map 0:v:0 -c:v copy -an -f hevc "$BL" 2>/dev/null
        "$DOVI" -m 2 convert --discard -i "$BL" -o "$CLEAN_BL"
        mv "$CLEAN_BL" "$BL"
        ok "Converted to Profile 8."
    else
        log "Profile $DV_PROFILE source — extracting HEVC stream..."
        "$FFMPEG" -y -i "$LOCAL_SOURCE" -map 0:v:0 -c:v copy -an -f hevc "$BL" 2>/dev/null
        ok "HEVC stream extracted."
    fi
fi

# ========================================
#  REMUX-ONLY PATH
# ========================================
if [ "$REMUX_ONLY" == "1" ]; then

    log "Extracting RPU from prepared base layer..."
    "$DOVI" extract-rpu -i "$BL" -o "$RPU"
    ok "RPU ready."

    hdr "STEP 5 — Remux (no re-encode)"
    log "Injecting Profile 8 RPU into base layer..."
    "$DOVI" inject-rpu -i "$BL" --rpu-in "$RPU" -o "$INJECTED_HEVC"
    ok "RPU injected."
    rm "$BL" "$RPU"

    log "Remuxing with selected audio and subtitle tracks..."
    "$MKVMERGE" -o "$OUTPUT_MKV" \
        "$INJECTED_HEVC" \
        --no-video \
        $AUDIO_ARGS \
        $SUB_ARGS \
        "$LOCAL_SOURCE"
    ok "Remux complete."
    rm "$INJECTED_HEVC" "$LOCAL_SOURCE"

    hdr "STEP 6 — Finalise"
    log "Renaming original to .bak..."
    mv "$SOURCE" "${SOURCE}.bak"
    ok "Original renamed."

    log "Copying converted file back..."
    rsync --progress "$OUTPUT_MKV" "$FINAL"
    ok "File copied."
    rm "$OUTPUT_MKV"

    log "Deleting original .bak..."
    rm "${SOURCE}.bak"
    ok "Original deleted."

    rm -rf "$WORKDIR"
    OUTPUT_SIZE=$(du -sh "$FINAL" | cut -f1)

    echo ""
    echo -e "${BOLD}  ================================================${NC}"
    echo -e "${GREEN}${BOLD}  Done! (Remux / P7→P8)${NC}"
    echo "  Output: $FINAL"
    echo "  Size:   $OUTPUT_SIZE"
    echo -e "${BOLD}  ================================================${NC}"

# ========================================
#  AV1 PATH
# ========================================
elif [ "$AV1_MODE" == "1" ]; then

    hdr "STEP 5 — AV1 Encode (SVT-AV1 CPU)"
    log "Encoding with libsvtav1 at CRF $AV1_CRF, preset 6..."
    log "DV metadata will be embedded natively as Profile 10."
    warn "This will take several hours on M5 for a 4K film."

    "$FFMPEG" -y \
        -i "$BL" \
        -c:v libsvtav1 \
        -crf "$AV1_CRF" \
        -preset 6 \
        -svtav1-params "tune=0:enable-overlays=1:scd=1:scm=0:keyint=10s" \
        -dolbyvision 1 \
        -pix_fmt yuv420p10le \
        -color_primaries bt2020 \
        -color_trc smpte2084 \
        -colorspace bt2020nc \
        -an \
        "$ENCODED_AV1"
    ok "AV1 encode complete."
    rm "$BL"

    hdr "STEP 6 — Remux"
    log "Remuxing AV1 stream with selected audio and subtitle tracks..."
    "$MKVMERGE" -o "$OUTPUT_MKV" \
        "$ENCODED_AV1" \
        --no-video \
        $AUDIO_ARGS \
        $SUB_ARGS \
        "$LOCAL_SOURCE"
    ok "Remux complete."
    rm "$ENCODED_AV1" "$LOCAL_SOURCE"

    hdr "STEP 7 — Finalise"
    log "Copying output to source location..."
    rsync --progress "$OUTPUT_MKV" "$FINAL"
    ok "File copied."
    rm "$OUTPUT_MKV"
    rm -rf "$WORKDIR"

    SOURCE_SIZE=$(du -sh "$SOURCE" | cut -f1)
    OUTPUT_SIZE=$(du -sh "$FINAL" | cut -f1)

    echo ""
    echo -e "${BOLD}  ================================================${NC}"
    echo -e "${GREEN}${BOLD}  Done! (AV1 / DV Profile 10)${NC}"
    echo "  Original: $FILENAME ($SOURCE_SIZE) — kept for quality comparison."
    echo "  Output:   $(basename "$FINAL") ($OUTPUT_SIZE)"
    echo ""
    warn "Verify DV Profile 10 playback on your target devices before"
    warn "converting your library. Current Apple TV 4K (A15) has no"
    warn "AV1 hardware decode — software decode may struggle at 4K."
    echo -e "${BOLD}  ================================================${NC}"

# ========================================
#  HEVC / VIDEOTOOLBOX PATH
# ========================================
else

    log "Extracting RPU from prepared base layer..."
    "$DOVI" extract-rpu -i "$BL" -o "$RPU"
    ok "RPU ready."

    hdr "STEP 5 — HEVC Encode (VideoToolbox)"
    log "Encoding at ${TARGET_MBPS} Mbps with Apple VideoToolbox..."
    "$FFMPEG" -y \
        -i "$BL" \
        -c:v hevc_videotoolbox \
        -b:v "$TARGET_BITRATE" \
        -maxrate "$MAX_BITRATE" \
        -bufsize "$BUF_SIZE" \
        -tag:v hvc1 \
        -color_primaries bt2020 \
        -color_trc smpte2084 \
        -colorspace bt2020nc \
        -pix_fmt p010le \
        -allow_sw 0 \
        -an \
        -f hevc "$ENCODED_HEVC"
    ok "Encode complete."
    rm "$BL"

    hdr "STEP 6 — Strip Residual Metadata"
    log "Removing any residual DV metadata from encoded stream..."
    "$DOVI" demux -i "$ENCODED_HEVC" --bl-out "$STRIPPED_HEVC" 2>/dev/null || \
        cp "$ENCODED_HEVC" "$STRIPPED_HEVC"
    rm "$ENCODED_HEVC"
    ok "Clean base layer ready."

    hdr "STEP 7 — DV Metadata Injection"
    log "Injecting Profile 8 RPU into encoded stream..."
    "$DOVI" inject-rpu -i "$STRIPPED_HEVC" --rpu-in "$RPU" -o "$INJECTED_HEVC"
    ok "DV Profile 8 metadata restored."
    rm "$STRIPPED_HEVC" "$RPU"

    hdr "STEP 8 — Remux"
    log "Remuxing with selected audio and subtitle tracks..."
    "$MKVMERGE" -o "$OUTPUT_MKV" \
        "$INJECTED_HEVC" \
        --no-video \
        $AUDIO_ARGS \
        $SUB_ARGS \
        "$LOCAL_SOURCE"
    ok "Remux complete."
    rm "$INJECTED_HEVC" "$LOCAL_SOURCE"

    hdr "STEP 9 — Finalise"
    log "Copying compressed file to source location..."
    rsync --progress "$OUTPUT_MKV" "$FINAL"
    ok "File copied."
    rm "$OUTPUT_MKV"
    rm -rf "$WORKDIR"

    SOURCE_SIZE=$(du -sh "$SOURCE" | cut -f1)
    OUTPUT_SIZE=$(du -sh "$FINAL" | cut -f1)

    echo ""
    echo -e "${BOLD}  ================================================${NC}"
    echo -e "${GREEN}${BOLD}  Done! (HEVC / DV Profile 8)${NC}"
    echo "  Original: $FILENAME ($SOURCE_SIZE) — kept for quality comparison."
    echo "  Output:   $(basename "$FINAL") ($OUTPUT_SIZE)"
    echo -e "${BOLD}  ================================================${NC}"

fi

echo ""
read -r -p "  Press Enter to close..."
echo ""
