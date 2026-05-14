# DV Toolkit — Developer Notes

This file documents the project background, technical decisions, known limitations, and areas for future development. It is intended to support ongoing development and future Claude conversations about this project.

---

## Project Background

Developed through an iterative Claude conversation (May 2026) to solve a specific home media workflow problem: UHD Blu-ray MKV rips from MakeMKV contain Dolby Vision Profile 7 which is not playable on Apple TV 4K via Infuse, Jellyfin, or Plex. The goal was a drag-and-drop toolkit requiring no technical knowledge to operate.

**Hardware context:**
- NAS: QNAP TS-853 Pro (1GbE, no PCIe expansion) serving files over the network
- Windows PC: Ryzen 7 7700, AMD RX 9070 XT (RDNA 4)
- MacBook Air: M5 (10-core CPU, 8-core GPU, 16GB) — primary compression machine
- Playback: Apple TV 4K (2022, A15) via Infuse → TCL C645 (DV-capable) and BenQ TK800 projector (HDR10 only)
- Physical disc player: Panasonic UB820 (handles P7 FEL natively from disc)

---

## Technical Background

### Dolby Vision Profiles

| Profile | Format | Used by |
|---------|--------|---------|
| 4 | HDR10 compatible, single layer | Some streaming |
| 5 | Single layer, no HDR10 fallback | Disney+ |
| 7 | Dual layer (BL + EL), HDR10 compatible | UHD Blu-ray discs |
| 8 | Single layer, HDR10 compatible | Streaming, converted rips |
| 10 | AV1 container | Future streaming |

**Profile 7** stores a base layer (BL, standard HDR10-compatible HEVC) and a separate enhancement layer (EL) that carries the Dolby Vision dynamic metadata. The EL can be FEL (Full Enhancement Layer — full resolution) or MEL (Minimum Enhancement Layer). FEL requires dedicated hardware (disc players) to process. MEL is more widely compatible.

**Profile 8** embeds the DV RPU (Reference Processing Unit — the dynamic metadata) directly into the HEVC stream alongside the HDR10 base layer. Single track, single file. Widely supported by streaming devices.

**Profile 8.1** specifically indicates the HDR10 compatibility signal ID = 1, which is what `dovi_tool -m 2 convert` produces.

### RPU (Reference Processing Unit)

The RPU is the per-frame or per-shot dynamic metadata that tells a DV display how to tone-map each frame. It is extracted from the EL in P7, converted to P8 format, and injected back into the BL HEVC stream. This is what `dovi_tool` handles.

---

## Tools and Commands

### dovi_tool

Key commands used in this toolkit:

```bash
# Extract RPU from a HEVC stream (EL for P7, or embedded for P8)
dovi_tool extract-rpu -i input.hevc -o RPU.bin

# Convert P7 to P8.1 — mode 2 removes FEL luma/chroma mapping
# Mode must be specified BEFORE the subcommand
dovi_tool -m 2 convert --discard -i input.hevc -o output.hevc

# Inject RPU into a base layer stream
dovi_tool inject-rpu -i bl.hevc --rpu-in RPU.bin -o output.hevc

# Demux — strips EL, outputs clean BL (used to clean encoded streams)
dovi_tool demux -i input.hevc --bl-out clean_bl.hevc

# Info — inspect RPU metadata (requires raw HEVC, not MKV)
dovi_tool info -i input.hevc -f 0
```

**Important:** `-m` (mode) is a global flag and must appear before the subcommand (`convert`, `extract-rpu`, etc.), not after.

**Mode reference:**
- `0` — Parse and rewrite RPU untouched
- `1` — Convert to MEL compatible
- `2` — Convert to Profile 8.1 (removes FEL luma/chroma mapping) ← used in this toolkit
- `3` — Convert Profile 5 to 8.1
- `4` — Convert to Profile 8.4
- `5` — Convert to Profile 8.1, preserving mapping (old mode 2)

### ffprobe — Detecting DV Profile in MKV

The DV profile in an MKV container is nested in `side_data_list` within stream data. It cannot be extracted with `-show_entries stream_side_data=dv_profile` — this returns nothing for MKV containers. The correct approach is `-show_streams -of json` and parsing `dv_profile` from the JSON:

```bash
ffprobe -v quiet -show_streams -of json input.mkv
# Look for: side_data_list > dv_profile
```

Python3 parse (used in macOS scripts):
```python
import json, sys
data = json.load(sys.stdin)
for s in data.get('streams', []):
    for sd in s.get('side_data_list', []):
        if 'dv_profile' in sd:
            print(sd['dv_profile'])
```

Windows parse (used in bat scripts — findstr + string manipulation):
```bat
ffprobe -v quiet -show_streams -of json "file.mkv" > tmp.json
findstr /i "dv_profile" tmp.json
# Parse value by stripping spaces, quotes, commas and splitting on :
```

### ffmpeg — VideoToolbox HEVC Encoding (macOS)

Key flags for DV-compatible HEVC encoding:

```bash
ffmpeg -i input.hevc \
  -c:v hevc_videotoolbox \
  -b:v 25M \
  -maxrate 50M \
  -bufsize 100M \
  -tag:v hvc1 \          # required for Apple device compatibility
  -color_primaries bt2020 \
  -color_trc smpte2084 \
  -colorspace bt2020nc \
  -pix_fmt p010le \      # 10-bit pixel format required for HDR
  -allow_sw 0 \          # fail if hardware encode unavailable
  -an \                  # no audio — handled separately by mkvmerge
  -f hevc output.hevc
```

After VideoToolbox encoding, any residual DV metadata in the encoded stream should be stripped with `dovi_tool demux --bl-out` before RPU injection to avoid conflicts.

### mkvmerge — Track Selection

```bash
# Keep specific audio tracks by track index (0-based stream index from ffprobe)
mkvmerge -o output.mkv video.hevc --no-video --audio-tracks 1,3 source.mkv

# Strip all subtitles
mkvmerge -o output.mkv video.hevc --no-video --no-subtitles source.mkv

# Keep specific subtitle tracks
mkvmerge -o output.mkv video.hevc --no-video --subtitle-tracks 4 source.mkv
```

---

## Known Issues and Limitations

### Windows

- **AMD GPU cannot compress with DV** — RDNA 4 AMF encoder strips DV metadata. No workaround without switching to NVIDIA or Apple Silicon.
- **xcopy progress** — Windows xcopy shows a file count rather than a percentage. No clean alternative without third-party tools since robocopy doesn't handle quoted filenames with spaces reliably.
- **dovi_tool info on MKV** — `dovi_tool info` only works on raw HEVC streams, not MKV containers. Verification step was removed from the conversion scripts for this reason.
- **batch script ERR handling** — Windows batch `errorlevel` checking is fragile; robocopy uses a bitmask (0-7 = success, 8+ = error) which differs from standard 0/1 convention.

### macOS

- **`declare -a` arrays in bash** — macOS ships with bash 3.2 (due to GPL licensing). The `declare -a` array syntax used for track selection works in bash 3.2 but `((count++))` can trigger ERR trap on zero result. Scripts use `|| true` to suppress this.
- **Bash `^^` uppercase operator** — requires bash 4.0+. If users have not installed bash via Homebrew, `${VAR^^}` may fail. Consider replacing with `tr '[:lower:]' '[:upper:]'` for robustness.
- **rsync progress** — `rsync --progress` shows per-file transfer progress. For very large files this works well; for many small files the output is verbose.
- **Gatekeeper** — dovi_tool binary requires `xattr -d com.apple.quarantine` after download. This is a one-time step but easy to forget.

### General

- **AV1 / Profile 10** — AV1 with DV Profile 10 encoding is technically supported by FFmpeg + SVT-AV1 but not pursued due to lack of hardware AV1 decode on current Apple TV hardware. Revisit when Apple TV ships with A17 or newer.
- **dovi_tool info verification** — Removed from scripts as it doesn't work reliably on MKV containers and requires extracting HEVC first. mkvmerge success is used as the proxy for a valid output.

---

## Tested Configurations

| Source | Tracks | Result |
|--------|--------|--------|
| Spider-Man: Across the Spider-Verse (2023) | Single-track P7 | ✓ Converted successfully |
| RoboCop (1987) 2160p | Single-track P8 | ✓ Detected correctly by scanner |
| Anchorman: The Legend of Ron Burgundy | Single-track P7 | ✓ Converted (xcopy space-in-filename fix required) |

---

## Future Development Ideas

- **Batch macOS converter** — shell script equivalent of `batch_convert_drop_FILE_convert_p7_to_p8.bat` that recurses a folder and converts all P7 files
- **Windows compression** — if user switches to NVIDIA GPU, NVENC on RTX 3000+ supports DV metadata passthrough; a Windows compress script using ffmpeg + hevc_nvenc would be straightforward
- **AV1 / Profile 10 pipeline** — revisit when Apple TV supports hardware AV1 decode; SVT-AV1 + dovi_tool RPU injection is the correct approach
- **Infuse / Jellyfin verification** — automated check that converted P8 files are detected correctly as DV by the target player
- **GUI wrapper** — a simple macOS Swift app or Windows WPF app wrapping the scripts for non-technical users
- **Queue management** — ability to queue multiple files for overnight batch processing on macOS
- **Quality verification** — VMAF scoring of compressed output vs source to validate quality settings

---

## Version History

| Date | Change |
|------|--------|
| May 2026 | Initial development — Windows P7→P8 converter, scanner, macOS compressor |
| May 2026 | Added local copy workflow to avoid NAS network bottleneck |
| May 2026 | Fixed dovi_tool -m flag position (must precede subcommand) |
| May 2026 | Fixed xcopy for filenames with spaces (robocopy alternative failed) |
| May 2026 | Added dual-track P7 (BL+EL) detection and handling |
| May 2026 | Added batch folder converter |
| May 2026 | Added multi-folder scanner with session persistence |
| May 2026 | Added macOS scanner and compress/remux script |
| May 2026 | Added remux-only mode to macOS script (matches Windows workflow) |
| May 2026 | Added audio/subtitle track selection to macOS compressor |
| May 2026 | Added AV1 / SVT-AV1 mode with native DV Profile 10 support |

---

## GitHub / VS Code Notes

### Recommended repository structure

```
/
  README.md                              ← copy of DV_Toolkit.md
  CLAUDE.md                              ← this file (dev notes)
  .gitignore
  windows/
    bin/                               ← gitignored, not committed to GitHub
      ffmpeg.exe
      ffprobe.exe
      dovi_tool.exe
      mkvmerge.exe
      mkvextract.exe
    drop_FILE_convert_p7_to_p8.bat
    drop_FOLDER_batch_convert_p7_to_p8.bat
    drop_FOLDER_scan_dv_profiles.bat
  macos/
    bin/                               ← gitignored, place dovi_tool here if not in /usr/local/bin
      dovi_tool                          ← optional, can use system PATH instead
    drop_FILE_convert_compress.sh
    drop_FOLDER_scan_dv_profiles.sh
```

### Recommended .gitignore

```
# Binary tools — not committed to GitHub
windows/bin/
macos/bin/

# Processing work folders
windows/work/
macos/work/
work/

# Intermediate files
*.hevc
*.ivf
*.bin

# Scan session state
tmp_*.txt
tmp_*.json

# Output reports and logs
dv_profile_scan.txt
batch_convert_log.txt
```

The `bin/` folders hold the required executables and must not be committed — they are platform-specific binaries and would make the repository unnecessarily large. The `work/` folders are temporary processing directories. The `tmp_*` files are scan session state.

### README note

The `DV_Toolkit.md` file is intended to serve as the GitHub `README.md`. Rename or symlink accordingly.

### Script naming convention

All scripts are prefixed with `drop_FILE_` or `drop_FOLDER_` to make the drag-and-drop input type immediately clear in Finder/Explorer. This is intentional and should be preserved.

### Continuation prompt for Claude

To continue development in a new Claude conversation, paste the contents of this `CLAUDE.md` file at the start of the conversation along with any specific question or task. Claude will have full context of the project, tools, known issues, and decisions made.

---

## AV1 / DV Profile 10 Notes

### How it differs from the HEVC pipeline

For HEVC (VideoToolbox), DV metadata must be manually extracted before encoding and re-injected after, because VideoToolbox has no native DV awareness. The pipeline is: extract RPU → encode BL → strip residual → inject RPU.

For AV1 (libsvtav1), FFmpeg handles DV natively via the `-dolbyvision 1` flag. The RPU is read from the input stream and embedded into the AV1 bitstream during encode. No separate extract/inject step is needed. Output is DV Profile 10 (the AV1 DV profile) rather than P8.

### ffmpeg command for AV1 + DV

```bash
ffmpeg -y \
    -i input.hevc \
    -c:v libsvtav1 \
    -crf 27 \
    -preset 6 \
    -svtav1-params "tune=0:enable-overlays=1:scd=1:scm=0:keyint=10s" \
    -dolbyvision 1 \
    -pix_fmt yuv420p10le \
    -color_primaries bt2020 \
    -color_trc smpte2084 \
    -colorspace bt2020nc \
    -an \
    output.ivf
```

Output is `.ivf` (raw AV1 bitstream) then muxed into MKV by mkvmerge.

### SVT-AV1 preset guide

| Preset | Speed | Use case |
|--------|-------|---------|
| 4-5 | Slow | Maximum quality |
| 6 | Medium | Default — good balance |
| 7-8 | Fast | Quicker but slightly larger |
| 9+ | Very fast | Testing only |

### Known limitation

The standard `brew install ffmpeg` does not include `libsvtav1` with DV support. Requires custom build or alternative tap. Script detects this at runtime and provides instructions.

### Device compatibility as of May 2026

- Apple TV 4K (2022, A15): AV1 software decode only — may struggle at 4K bitrates
- Apple TV 4K (future, A17+): expected hardware AV1 decode
- Vero V: hardware AV1 decode supported
- TCL C645: check manufacturer specs — many 2023+ TVs support AV1 decode
- BenQ TK800 projector: no AV1 support
