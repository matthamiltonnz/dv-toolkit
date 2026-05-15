# DV Toolkit — Developer Notes

This file documents the project background, technical decisions, known limitations, and areas for future development. It is intended to support ongoing development and future Claude conversations about this project.

---

## Project Background

Developed through an iterative Claude conversation (May 2026) to solve a specific home media workflow problem: UHD Blu-ray MKV rips from MakeMKV contain Dolby Vision Profile 7 which is not playable on Apple TV 4K via Infuse, Jellyfin, or Plex. The goal was a drag-and-drop toolkit requiring no technical knowledge to operate.

**Hardware context:**
- NAS: QNAP TS-853 Pro and QNAP TS-459, both serving media files over the network
- Media server: Jellyfin installed on Home Assistant, running on an Intel N100-based mini PC
- Windows PC: Ryzen 7 7700, AMD RX 9070 XT (RDNA 4)
- MacBook Air: M5 (10-core CPU, 8-core GPU, 16GB) — macOS scripts are experimental and untested
- Playback devices: Apple TV 4K (2022, A15), Jellyfin app on TCL C645 TV (DV-capable), Xiaomi Google TV box, 4× Chromecast with Google TV, BenQ TK800 projector (HDR10 only)
- Physical disc player: Panasonic DMP-UB900 (does not support Dolby Vision — hence the rip and convert workflow for streaming device playback)

---

## Technical Background

### Dolby Vision Profiles

| Profile | Format | Used by |
|---------|--------|---------|
| 4 | HDR10 compatible, single layer | Some streaming |
| 5 | Single layer, no HDR10 fallback | Disney+ |
| 7 | Dual layer (BL + EL), HDR10 compatible | UHD Blu-ray discs |
| 8 | Single layer, HDR10 compatible | Streaming, converted rips |
| 10 | AV1 container | Emerging — DV in AV1 not yet in mainstream streaming use (AV1 itself is widely used by YouTube/Netflix but without DV) |

**Profile 7** stores a base layer (BL, standard HDR10-compatible HEVC) and a separate enhancement layer (EL) that carries the Dolby Vision dynamic metadata. The EL can be FEL (Full Enhancement Layer — full resolution) or MEL (Minimum Enhancement Layer). FEL requires dedicated hardware (disc players) to process. MEL is more widely compatible.

**Profile 8** embeds the DV RPU (Reference Processing Unit — the dynamic metadata) directly into the HEVC stream alongside the HDR10 base layer. Single track, single file. Widely supported by streaming devices.

**Profile 8.1** specifically indicates the HDR10 compatibility signal ID = 1, which is what `dovi_tool -m 2 convert` produces.

### RPU (Reference Processing Unit)

The RPU is the per-frame or per-shot dynamic metadata that tells a DV display how to tone-map each frame. It is extracted from the EL in P7, converted to P8 format, and injected back into the BL HEVC stream. This is what `dovi_tool` handles.

### Visual Quality: FEL P7 vs Converted P8

In a Profile 7 FEL source, the enhancement layer contains two distinct things:

1. **The RPU** — per-frame dynamic metadata (brightness targets, colour volume, tone-mapping curves). **Fully preserved** in the P8 conversion.
2. **Luma/chroma mapping coefficients and residual data** — pixel-level corrections applied on top of the base layer by the playback hardware. **Discarded** by `dovi_tool -m 2 convert --discard`.

The luma/chroma residual in a FEL source is designed to be processed by dedicated disc playback hardware (e.g. a Panasonic UB900). The hardware uses it to apply fine per-pixel corrections to the base layer — in theory producing the most accurate representation of the master. When playing a disc on hardware that supports FEL processing, this is the full DV experience as the studio intended.

When converting to P8, the residual is discarded and the display works solely from the base HEVC layer, guided by the preserved RPU.

**In practice, visible differences are negligible for most content**, for several reasons:

- Many UHD Blu-ray discs use MEL (Minimum Enhancement Layer) rather than FEL. A MEL EL clip appears solid green — it encodes no pixel-level difference at all. For these sources, the remux-only approach produces identical results to any FEL-aware pipeline.
- For FEL sources, the benefit depends on how much visible structure is present in the EL clip. The more recognisable the content in the EL, the greater the potential difference — but even then it is limited to scenes with extreme highlights or highly saturated colours where the base layer clips.
- The RPU dynamic metadata — the primary driver of DV's visual advantage over standard HDR10 — is fully preserved. The display still receives per-frame tone-mapping instructions and can adjust highlights, shadows, and colour volume accordingly.
- Streaming devices (Apple TV, Chromecast, smart TV apps) have never had access to FEL processing. A streaming service delivering DV content sends Profile 8 — the same format produced by this toolkit.

The bottom line: the converted P8 file delivers the same DV experience as streaming-service content. For MEL sources (common on UHD Blu-ray), there is no difference whatsoever. For FEL sources, any pixel-level difference is limited to extreme-highlight scenes and is only visible on reference displays in controlled conditions. See the DoViBaker / DoviScripts section for tools that can quantify and optionally apply the FEL residual.

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

Windows parse (used in bat scripts — findstr to temp file, then string manipulation):
```bat
ffprobe -v quiet -show_streams -of json "file.mkv" > tmp.json
findstr /i "dv_profile" tmp.json > tmp_dvline.txt
rem Parse value by stripping spaces, quotes, commas and splitting on :
rem NOTE: do NOT use for /f ('findstr ... "path"') — double quotes inside
rem single-quoted for /f commands fail when the script folder has spaces.
rem Always redirect findstr output to a temp file and read with usebackq.
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
- **`for /f` double-quote-in-single-quote bug** — Using `for /f "..." %%V in ('command "path with spaces"')` silently fails or produces wrong output when the script folder path contains spaces. The outer single quotes cannot contain unescaped double quotes. Fixed throughout by redirecting command output to a temp file and reading it with `usebackq`: `for /f "usebackq ..." %%V in ("tmpfile.txt")`. All `findstr` and `ffprobe` pipe operations use this pattern.
- **Empty `set` assignment in cmd.exe** — `set "VAR="` and `set VAR=` (clearing a variable) cause "The syntax of the command is incorrect." inside parenthesised blocks on some Windows configurations, and are unreliable at top level too. The Windows scanner originally had multi-folder session persistence relying on `set PREV_FOLDERS=` to clear between runs — this could not be made reliably work and was removed. The scanner now scans one folder per run with no session state.

### macOS

- **`declare -a` arrays in bash** — macOS ships with bash 3.2 (due to GPL licensing). The `declare -a` array syntax used for track selection works in bash 3.2 but `((count++))` can trigger ERR trap on zero result. Scripts use `|| true` to suppress this.
- **Bash `^^` uppercase operator** *(fixed)* — `${VAR^^}` requires bash 4.0+. macOS ships bash 3.2. All scripts now use `tr '[:lower:]' '[:upper:]'` or explicit `Y`/`y` comparisons instead. Watch for this when adding new input prompts.
- **rsync progress** — `rsync --progress` shows per-file transfer progress. For very large files this works well; for many small files the output is verbose.
- **Gatekeeper** — dovi_tool binary requires `xattr -d com.apple.quarantine` after download. This is a one-time step but easy to forget.

### General

- **AV1 / Profile 10** — AV1 with DV Profile 10 encoding is technically supported by FFmpeg + SVT-AV1 but not pursued due to lack of hardware AV1 decode on current Apple TV hardware. Revisit when Apple TV ships with A17 or newer.
- **dovi_tool info verification** — Removed from scripts as it doesn't work reliably on MKV containers and requires extracting HEVC first. mkvmerge success is used as the proxy for a valid output.
- **Cloud-synced script folders (OneDrive / iCloud)** — rsync and other file operations writing to a cloud-synced folder appear to complete immediately (the OS filesystem layer accepts the write), but the actual data is handed off to the cloud sync process asynchronously. For large files this means rsync reports 100% while the cloud is still uploading, and if sync is paused mid-transfer the destination file may be absent or incomplete. macOS scripts now write all intermediate files to `/tmp/dv-toolkit/` to avoid this entirely. Windows scripts write to a `work\` subfolder alongside the scripts — if the scripts are in an OneDrive folder on Windows, move them to a local drive.

---

## Tested Configurations

| Source | Tracks | Result |
|--------|--------|--------|
| Spider-Man: Across the Spider-Verse (2023) | Single-track P7 | ✓ Converted successfully |
| RoboCop (1987) 2160p | Single-track P8 | ✓ Detected correctly by scanner |
| Anchorman: The Legend of Ron Burgundy | Single-track P7 | ✓ Converted (xcopy space-in-filename fix required) |

---

## Future Development Ideas

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
| May 2026 | Added batch folder converter (Windows) |
| May 2026 | Added macOS scanner and compress/remux script |
| May 2026 | Added remux-only mode to macOS script (matches Windows workflow) |
| May 2026 | Added audio/subtitle track selection to macOS compressor |
| May 2026 | Added AV1 / SVT-AV1 mode with native DV Profile 10 support |
| May 2026 | Added macOS batch folder converter (drop_FOLDER_batch_convert_p7_to_p8.sh) |
| May 2026 | Added local disk detection and free space check to both macOS and Windows batch converters |
| May 2026 | Fixed Windows `for /f` quoting bug affecting all scripts when script folder path has spaces |
| May 2026 | Fixed bash 3.2 `^^` uppercase operator — replaced with explicit Y/y comparisons |
| May 2026 | Added input validation (file-vs-folder) to all scripts on both platforms |
| May 2026 | Investigated DoViBaker for FEL preservation — determined not suitable (see below) |
| May 2026 | Published to GitHub as public repository |
| May 2026 | Removed multi-folder session persistence from Windows scanner — caused "The syntax of the command is incorrect." on cmd.exe; reverted to single-folder scan per run |
| May 2026 | macOS convert script: added DV profile check before mode prompt; changed WORKDIR to /tmp/dv-toolkit to avoid OneDrive sync; HEVC/AV1 output named with quality suffix (_25mbps, _av1_crf27), originals kept; OneDrive detection notice added; fixed bash 3.2 `^^` bug in subtitle NONE check |
| May 2026 | Windows scanner: added startup cleanup of leftover temp files from old session-based version |
| May 2026 | Added TrueHD Atmos → EAC3 Atmos converter (drop_FILE_add_atmos_eac3.sh / .bat) — detects Atmos-flagged TrueHD tracks, converts to EAC3 768 kbps, adds alongside originals; output named _atmos_eac3.mkv |
| May 2026 | Added Atmos conversion option to macOS single-file compress script (HEVC/AV1 modes) — TrueHD replaced by EAC3 in compressed output |
| May 2026 | Extended Atmos tools to also offer non-Atmos TrueHD → EAC3 conversion (size saving, lossy — clearly flagged); improved Atmos detection to use ffprobe profile field (codec-level) plus title tag fallback |
| May 2026 | Replaced rsync with cp+progress loop for copy-out step in macOS single-file compress script (all three paths) — consistent with copy-in and batch converter |

---

## GitHub / VS Code Notes

### Recommended repository structure

```
/
  README.md
  CLAUDE.md                              ← this file (dev notes)
  .gitignore
  .gitattributes                         ← enforces CRLF for *.bat, LF for *.sh
  Windows/
    bin/                               ← gitignored, not committed to GitHub
      ffmpeg.exe
      ffprobe.exe
      dovi_tool.exe
      mkvmerge.exe
      mkvextract.exe
    drop_FILE_convert_p7_to_p8.bat
    drop_FOLDER_batch_convert_p7_to_p8.bat
    drop_FOLDER_scan_dv_profiles.bat
    drop_FILE_add_atmos_eac3.bat
  macOS/
    bin/                               ← gitignored, place dovi_tool here if not in PATH
      dovi_tool                          ← optional, can use system PATH instead
    drop_FILE_convert_compress.sh
    drop_FOLDER_batch_convert_p7_to_p8.sh
    drop_FOLDER_scan_dv_profiles.sh
    drop_FILE_add_atmos_eac3.sh
    install.sh
```

### Recommended .gitignore

```
# Binary tools — not committed to GitHub
Windows/bin/
macOS/bin/

# Processing work folders
Windows/work/
macOS/work/
work/

# Intermediate files
*.hevc
*.ivf
*.bin

# Temporary probe files
tmp_*.txt
tmp_*.json

# Output reports and logs
dv_profile_scan.txt
batch_convert_log.txt
```

The `bin/` folders hold the required executables and must not be committed — they are platform-specific binaries and would make the repository unnecessarily large. The `work/` folders are temporary processing directories. The `tmp_*` files are temporary probe/intermediate files created and deleted during script runs.

### README note

The `DV_Toolkit.md` file is intended to serve as the GitHub `README.md`. Rename or symlink accordingly.

### Script naming convention

All scripts are prefixed with `drop_FILE_` or `drop_FOLDER_` to make the drag-and-drop input type immediately clear in Finder/Explorer. This is intentional and should be preserved.

### Continuation prompt for Claude

To continue development in a new Claude conversation, paste the contents of this `CLAUDE.md` file at the start of the conversation along with any specific question or task. Claude will have full context of the project, tools, known issues, and decisions made.

---

## Investigated Approaches: DoViBaker / DoviScripts

[DoViBaker](https://github.com/erazortt/DoViBaker) is an AviSynth+ plugin that processes Profile 7 FEL sources by combining the BL, EL, and RPU to produce a corrected output — reportedly a 12-bit stream that applies the luma/chroma residual from the FEL and incorporates the display trim metadata from the RPU. This is the only known tool that actually uses the FEL correction data rather than discarding it. The internal implementation details have not been verified against the source code.

[DoviScripts](https://github.com/erazortt/DoviScripts) is a companion package from the same author that wraps DoViBaker in a workflow capable of outputting a Profile 8 MKV — closing the loop from FEL P7 source to a distributable P8 file.

[DoViAnalyzer](https://github.com/erazortt/DoViAnalyzer) (same author) calculates whether the RPU-driven colour difference exceeds a perceptible threshold — specifically, whether the difference exceeds 3 bits out of 10 (equivalent to >1 bit out of 8). This can be used to screen a source before deciding whether DoViBaker is worth running.

### MEL vs FEL — when DoViBaker actually matters

Per the author's guidance, the benefit of DoViBaker depends entirely on the EL content:

- **MEL sources** — the EL clip appears solid green. There is no pixel-level difference encoded. DoViBaker provides no improvement at the pixel level for these sources. The remux-only approach in this toolkit is already optimal.
- **FEL sources** — the EL clip contains visible structure. The more recognisable the content, the greater the potential pixel-level difference. Worth checking visually before deciding whether to use DoViBaker.
- **RPU coloring differences** — even for MEL sources, the RPU may encode general colour adjustments. However, the RPU is fully preserved in this toolkit's pipeline (`dovi_tool -m 2 convert` retains it), so this benefit is already captured regardless of DoViBaker.

The author's recommended screening workflow:
1. Play the EL clip — if green (MEL), skip DoViBaker; the remux approach gives identical results.
2. If FEL, check whether visible structure is present in the EL. More structure = more potential benefit.
3. Optionally run DoViAnalyzer to quantify whether the RPU difference exceeds the perceptible threshold.
4. Only if differences are confirmed significant: use DoViBaker + DoviScripts to produce a re-encoded P8.

**Why it was not integrated into this toolkit:**

1. **Re-encoding required** — DoViBaker outputs a processed frame sequence that must then be re-encoded to HEVC. There is no path to a lossless P8 output via this route. Re-encoding at practical home-server bitrates introduces artefacts that partially offset any quality gained from the FEL residual.
2. **AviSynth-only** — DoViBaker is a plugin for AviSynth+ (Windows only), not a standalone tool. It cannot be called from a batch file or shell script without a full AviSynth scripting environment.
3. **Source-dependent benefit** — most UHD Blu-ray rips are MEL, or FEL with subtle residual. The RPU — the primary driver of DV's visual advantage — is already preserved in this toolkit's output. The FEL pixel residual only materially matters on sources where the EL shows visible structure in scenes with extreme highlights.
4. **Out of scope** — the toolkit goal is a fast, lossless remux. DoViBaker + DoviScripts turns this into a full transcode pipeline.

**Conclusion:** For the majority of sources, this toolkit's remux output is equivalent to or indistinguishable from a DoViBaker encode. DoViBaker + DoviScripts is the right choice for archival work on confirmed FEL sources where the EL shows significant pixel-level content and a re-encode at high bitrate is acceptable. Not suitable for this toolkit's workflow.

---

## TrueHD Atmos → EAC3 Atmos Notes

### Background

UHD Blu-ray rips from MakeMKV typically contain a TrueHD audio track. On discs with Atmos, TrueHD wraps both a 7.1 core track and the Atmos JOC (Joint Object Coding) object-based spatial metadata in a MAT (Metadata-enhanced Audio Transmission) container.

Apple TV 4K cannot decode TrueHD natively. It passes TrueHD audio through as multi-channel PCM — the 7.1 core plays, but the Atmos MAT layer is discarded entirely. The result: no Atmos spatial audio, despite the track containing it.

EAC3 (Dolby Digital Plus with JOC extension) is the streaming format for Atmos. Apple TV decodes EAC3 Atmos natively and passes it to the AVR or TV as an Atmos bitstream. Adding an EAC3 Atmos track to an MKV alongside the original TrueHD makes the file compatible with Apple TV while still providing lossless audio for players that support TrueHD (Infuse with a capable receiver, Kodi, dedicated disc players).

### Detection

Atmos tracks are detected using ffprobe's `profile` field first (codec-level detection — ffprobe reads the MAT 2.0 header in the TrueHD bitstream and sets `profile = "TrueHD + Dolby Atmos"` when present), with `tags.title` containing 'Atmos' as a fallback. Title-only detection is unreliable — track names depend on the ripping or tagging tool used, not the disc content. The profile field is available in FFmpeg 4.x+ and requires reading the start of the TrueHD stream; for streams deep in the file, the default probesize may not be sufficient.

Non-Atmos TrueHD tracks (codec truehd, no Atmos detected in profile or title) are offered as a separate conversion option. This is a size saving (~2–3 GB per 2hr film) at the cost of lossless audio quality — users are told this explicitly.

### Conversion

FFmpeg's EAC3 encoder handles TrueHD → EAC3 conversion, preserving the JOC Atmos object data in the output stream. 768 kbps is the standard bitrate for EAC3 7.1 Atmos on streaming services (Dolby's recommended ceiling for EAC3 7.1).

```bash
ffmpeg -i input.mkv -map 0:a:N -c:a eac3 -b:a 768k output.eac3
```

### Two modes

- **Standalone tool** (`drop_FILE_add_atmos_eac3.sh` / `.bat`): Adds EAC3 alongside TrueHD. Both tracks in output. Original MKV kept. For files you want to remain full quality.
- **Integrated in compress script** (`drop_FILE_convert_compress.sh`, HEVC/AV1 modes): TrueHD replaced by EAC3 in the compressed output. No TrueHD in output. Appropriate since you're already accepting lossy video compression.

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
