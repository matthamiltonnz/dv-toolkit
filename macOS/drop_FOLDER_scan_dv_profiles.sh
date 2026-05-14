#!/bin/bash

# =============================================================
#  Dolby Vision Profile Scanner for macOS
#  - Scans a folder recursively for DV profiles
#  - Supports multi-folder scanning with combined results
#  - Reports Profile 7, Profile 8, and any other DV profiles
#
#  Usage:
#    ./drop_FOLDER_scan_dv_profiles.sh /path/to/folder
#    Or drag a folder onto the Automator app wrapper
#
#  Required tools:
#    brew install ffmpeg
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
err()  { echo -e "${RED}  ✗ $1${NC}"; }
hdr()  { echo -e "\n${BOLD}  $1${NC}"; echo "  $(echo "$1" | sed 's/./-/g')"; }

SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"
OUTFILE="$SCRIPTDIR/dv_profile_scan.txt"
STATEFILE="$SCRIPTDIR/tmp_scan_state.json"
TMP_P7="$SCRIPTDIR/tmp_p7.txt"
TMP_P8="$SCRIPTDIR/tmp_p8.txt"
TMP_OTHER="$SCRIPTDIR/tmp_other.txt"

# ---- Tool resolution ----
resolve_tool() {
    if command -v "$1" &>/dev/null; then echo "$1"
    elif [ -f "$SCRIPTDIR/bin/$1" ]; then echo "$SCRIPTDIR/bin/$1"
    elif [ -f "$SCRIPTDIR/$1" ]; then echo "$SCRIPTDIR/$1"
    else err "$1 not found. Install via Homebrew or place in the script folder."; exit 1
    fi
}
FFPROBE=$(resolve_tool ffprobe)

# ---- Argument check ----
if [ -z "$1" ]; then
    err "No folder specified."
    echo "  Usage: ./drop_FOLDER_scan_dv_profiles.sh /path/to/folder"
    read -r -p "  Press Enter to close..."
    exit 1
fi

SCANDIR="$1"

if [ ! -d "$SCANDIR" ]; then
    err "Folder not found: $SCANDIR"
    read -r -p "  Press Enter to close..."
    exit 1
fi

echo ""
echo -e "${BOLD}  ================================================${NC}"
echo -e "${BOLD}  Dolby Vision Profile Scanner — macOS${NC}"
echo -e "${BOLD}  ================================================${NC}"
echo "  Scanning: $SCANDIR"
echo "  Output:   $OUTFILE"
echo ""

# ---- Check for existing session ----
APPEND=0
PREV_COUNT=0
PREV_P7=0
PREV_P8=0
PREV_OTHER=0
PREV_FOLDERS=""

if [ -f "$STATEFILE" ]; then
    PREV_COUNT=$(python3 -c "import json; d=json.load(open('$STATEFILE')); print(d.get('count',0))")
    PREV_P7=$(python3 -c "import json; d=json.load(open('$STATEFILE')); print(d.get('p7',0))")
    PREV_P8=$(python3 -c "import json; d=json.load(open('$STATEFILE')); print(d.get('p8',0))")
    PREV_OTHER=$(python3 -c "import json; d=json.load(open('$STATEFILE')); print(d.get('other',0))")
    PREV_FOLDERS=$(python3 -c "import json; d=json.load(open('$STATEFILE')); print('\n    '.join(d.get('folders',[])))")

    echo "  An existing scan session was found."
    echo "  Previous folders scanned:"
    echo "    $PREV_FOLDERS"
    echo "  Files scanned so far: $PREV_COUNT"
    echo "  Profile 7: $PREV_P7  Profile 8: $PREV_P8"
    echo ""
    read -r -p "  Add this folder to existing results? [Y=Add / N=Start new scan]: " CHOICE
    if [[ "$CHOICE" == "Y" ]] || [[ "$CHOICE" == "y" ]]; then
        APPEND=1
    fi
fi

if [ "$APPEND" == "0" ]; then
    # Fresh start
    : > "$TMP_P7"
    : > "$TMP_P8"
    : > "$TMP_OTHER"
    PREV_COUNT=0; PREV_P7=0; PREV_P8=0; PREV_OTHER=0
    PREV_FOLDERS_LIST="[]"
else
    [ -f "$TMP_P7" ]    || : > "$TMP_P7"
    [ -f "$TMP_P8" ]    || : > "$TMP_P8"
    [ -f "$TMP_OTHER" ] || : > "$TMP_OTHER"
    PREV_FOLDERS_LIST=$(python3 -c "import json; d=json.load(open('$STATEFILE')); print(json.dumps(d.get('folders',[])))")
fi

# ---- Scan ----
echo ""
hdr "Scanning..."
echo ""

COUNT=0
COUNT_P7=0
COUNT_P8=0
COUNT_OTHER=0

while IFS= read -r -d '' FILE; do
    ((COUNT++)) || true
    BASENAME=$(basename "$FILE")
    echo "  Checking $COUNT: $BASENAME"

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
        echo -e "    ${RED}^^^ PROFILE 7${NC}"
        echo "$FILE" >> "$TMP_P7"
        ((COUNT_P7++)) || true
    elif [ "$PROFILE" == "8" ]; then
        echo -e "    ${GREEN}^^^ PROFILE 8${NC}"
        echo "$FILE" >> "$TMP_P8"
        ((COUNT_P8++)) || true
    elif [ -n "$PROFILE" ]; then
        echo -e "    ${YELLOW}^^^ PROFILE $PROFILE${NC}"
        echo "[Profile $PROFILE] $FILE" >> "$TMP_OTHER"
        ((COUNT_OTHER++)) || true
    fi

done < <(find "$SCANDIR" \( -name "*.mkv" -o -name "*.mp4" -o -name "*.ts" \) -print0)

# ---- Combine totals ----
TOTAL_COUNT=$((PREV_COUNT + COUNT))
TOTAL_P7=$((PREV_P7 + COUNT_P7))
TOTAL_P8=$((PREV_P8 + COUNT_P8))
TOTAL_OTHER=$((PREV_OTHER + COUNT_OTHER))

# ---- Save state ----
python3 -c "
import json
prev = json.loads('$PREV_FOLDERS_LIST')
prev.append('$SCANDIR')
state = {'count': $TOTAL_COUNT, 'p7': $TOTAL_P7, 'p8': $TOTAL_P8, 'other': $TOTAL_OTHER, 'folders': prev}
json.dump(state, open('$STATEFILE', 'w'), indent=2)
"

# ---- Write report ----
{
    echo "Dolby Vision Profile Scan"
    echo "Last updated: $(date)"
    echo ""
    echo "FOLDERS SCANNED"
    echo "----------------------------------------"
    python3 -c "
import json
d=json.load(open('$STATEFILE'))
for f in d['folders']:
    print(f)
"
    echo ""
    echo "PROFILE 7 FILES ($TOTAL_P7)"
    echo "----------------------------------------"
    cat "$TMP_P7"
    echo ""
    echo "PROFILE 8 FILES ($TOTAL_P8)"
    echo "----------------------------------------"
    cat "$TMP_P8"
    if [ "$TOTAL_OTHER" -gt 0 ]; then
        echo ""
        echo "OTHER DV PROFILES ($TOTAL_OTHER)"
        echo "----------------------------------------"
        cat "$TMP_OTHER"
    fi
    echo ""
    echo "----------------------------------------"
    echo "Total scanned:   $TOTAL_COUNT"
    echo "Profile 7 found: $TOTAL_P7"
    echo "Profile 8 found: $TOTAL_P8"
    [ "$TOTAL_OTHER" -gt 0 ] && echo "Other DV found:  $TOTAL_OTHER"
} > "$OUTFILE"

# ---- Summary ----
echo ""
echo -e "${BOLD}  ================================================${NC}"
echo -e "${GREEN}${BOLD}  Scan complete.${NC}"
echo "  This folder  — scanned: $COUNT  P7: $COUNT_P7  P8: $COUNT_P8"
echo "  ----------------------------------------"
echo "  Combined totals:"
echo "  Scanned:   $TOTAL_COUNT"
echo "  Profile 7: $TOTAL_P7"
echo "  Profile 8: $TOTAL_P8"
[ "$TOTAL_OTHER" -gt 0 ] && echo "  Other DV:  $TOTAL_OTHER"
echo ""
echo "  Report saved to: $OUTFILE"
echo ""
echo "  Tip: drag another folder onto this script to add to the report,"
echo "       or drag a new folder and choose N to start a fresh scan."
echo -e "${BOLD}  ================================================${NC}"
echo ""
read -r -p "  Press Enter to close..."
echo ""
