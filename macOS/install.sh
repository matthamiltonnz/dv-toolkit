#!/bin/bash

# =============================================================
#  DV Toolkit — macOS Setup Script
#  Run this once after cloning or downloading the project.
#  Sets correct permissions and removes Gatekeeper quarantine.
# =============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓ $1${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $1${NC}"; }
err()  { echo -e "${RED}  ✗ $1${NC}"; }
log()  { echo -e "${CYAN}  $1${NC}"; }

SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo -e "${BOLD}  DV Toolkit — macOS Setup${NC}"
echo "  =========================="
echo ""

# ---- Make scripts executable ----
log "Setting script permissions..."

for f in \
    "$SCRIPTDIR/drop_FILE_convert_compress.sh" \
    "$SCRIPTDIR/drop_FOLDER_batch_convert_p7_to_p8.sh" \
    "$SCRIPTDIR/drop_FOLDER_scan_dv_profiles.sh"
do
    if [ -f "$f" ]; then
        chmod +x "$f"
        ok "chmod +x $(basename "$f")"
    else
        warn "Not found: $(basename "$f") — skipping"
    fi
done

# ---- Remove Gatekeeper quarantine from dovi_tool ----
echo ""
log "Checking for dovi_tool..."

DOVI_LOCATIONS=(
    "/usr/local/bin/dovi_tool"
    "$SCRIPTDIR/bin/dovi_tool"
)

DOVI_FOUND=""
for loc in "${DOVI_LOCATIONS[@]}"; do
    if [ -f "$loc" ]; then
        DOVI_FOUND="$loc"
        break
    fi
done

if [ -n "$DOVI_FOUND" ]; then
    chmod +x "$DOVI_FOUND"
    ok "chmod +x $DOVI_FOUND"
    if xattr -l "$DOVI_FOUND" 2>/dev/null | grep -q "com.apple.quarantine"; then
        log "Removing Gatekeeper quarantine flag..."
        xattr -d com.apple.quarantine "$DOVI_FOUND"
        ok "Quarantine removed: $DOVI_FOUND"
    else
        ok "No quarantine flag on $DOVI_FOUND"
    fi
else
    warn "dovi_tool not found in expected locations."
    echo "  Download from: https://github.com/quietvoid/dovi_tool/releases"
    echo "  Then place it in one of:"
    for loc in "${DOVI_LOCATIONS[@]}"; do
        echo "    $loc"
    done
fi

# ---- Check Homebrew tools ----
echo ""
log "Checking required Homebrew tools..."

MISSING=()
for tool in ffmpeg ffprobe mkvmerge; do
    if command -v "$tool" &>/dev/null; then
        ok "$tool found: $(command -v "$tool")"
    else
        err "$tool not found"
        MISSING+=("$tool")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo ""
    warn "Some tools are missing. Install with:"
    echo ""
    echo "    brew install ffmpeg mkvtoolnix"
    echo ""
fi

# ---- Check AV1 / libsvtav1 support (optional) ----
echo ""
log "Checking optional AV1 support..."

if command -v ffmpeg &>/dev/null; then
    if ffmpeg -encoders 2>/dev/null | grep -q libsvtav1; then
        if ffmpeg -h encoder=libsvtav1 2>/dev/null | grep -q dolbyvision; then
            ok "libsvtav1 with Dolby Vision support detected — AV1 mode available"
        else
            warn "libsvtav1 found but Dolby Vision support not compiled in"
            echo "  AV1 mode will not be available."
            echo "  See SETUP.md for instructions to get a compatible ffmpeg build."
        fi
    else
        warn "libsvtav1 not found — AV1 mode not available"
        echo "  This is optional. HEVC and remux modes work with standard ffmpeg."
        echo "  See SETUP.md for AV1 setup instructions if needed."
    fi
fi

# ---- Summary ----
echo ""
echo -e "${BOLD}  =========================="
if [ ${#MISSING[@]} -eq 0 ] && [ -n "$DOVI_FOUND" ]; then
    echo -e "${GREEN}${BOLD}  Setup complete.${NC}"
    echo "  You can now use the scripts or set up Automator drag-and-drop."
    echo "  See SETUP.md for Automator instructions."
else
    echo -e "${YELLOW}${BOLD}  Setup incomplete — see warnings above.${NC}"
fi
echo -e "${BOLD}  ==========================${NC}"
echo ""
