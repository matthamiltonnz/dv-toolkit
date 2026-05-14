# Dolby Vision Conversion Toolkit

## Purpose

UHD Blu-ray discs encode Dolby Vision using **Profile 7** — a dual-layer format that stores a base HDR10 video stream alongside a separate Dolby Vision enhancement layer. This format is designed for disc playback hardware and is not supported by most streaming devices and software players.

Most streaming devices and media players require **Dolby Vision Profile 8** — a single-layer format where the DV metadata is embedded directly into the HEVC video stream alongside a standard HDR10 base layer.

This toolkit converts MKV rips (made with MakeMKV from UHD Blu-ray discs) from Profile 7 to Profile 8, enabling full Dolby Vision playback on streaming devices. The conversion is lossless — no video re-encoding occurs in the standard workflow, only metadata restructuring. Devices that do not support Dolby Vision at all will automatically fall back to the embedded HDR10 layer.

On macOS with an Apple Silicon Mac, an optional compression mode is available that re-encodes the video using Apple's VideoToolbox hardware encoder, reducing file sizes to streaming-equivalent quality (~20-25 GB) while preserving Dolby Vision Profile 8 metadata.

---

## Platform Summary

| Feature | Windows | macOS |
|---------|---------|-------|
| P7 → P8 conversion (single file) | ✓ `drop_FILE_convert_p7_to_p8.bat` | ✓ `drop_FILE_convert_compress.sh` (remux mode) |
| P7 → P8 conversion (batch folder) | ✓ `drop_FOLDER_batch_convert_p7_to_p8.bat` | ✓ `drop_FOLDER_batch_convert_p7_to_p8.sh` |
| Library profile scanner | ✓ `drop_FOLDER_scan_dv_profiles.bat` | ✓ `drop_FOLDER_scan_dv_profiles.sh` |
| Compression (re-encode) | ✗ Not supported¹ | ✓ `drop_FILE_convert_compress.sh` (compress mode) |

> ¹ **Windows compression is not supported.** Preserving Dolby Vision metadata during HEVC re-encoding requires hardware encoder support for DV passthrough. AMD GPUs (including RDNA 4) strip DV metadata in their hardware encoders, and CPU encoding via x265 is impractically slow for 4K UHD content. Compression is only available on macOS using Apple's VideoToolbox encoder on M-series chips.

---

## Windows Setup

### 1. Create the folder structure

Create a dedicated folder for the Windows scripts, for example:

```
C:\Tools\DV Convert\windows\
```

Inside it, create a `bin\` subfolder for the executables:

```
windows\
  bin\                    ← executables go here
  drop_FILE_convert_p7_to_p8.bat
  drop_FOLDER_batch_convert_p7_to_p8.bat
  drop_FOLDER_scan_dv_profiles.bat
```

The scripts automatically add the `bin\` folder to the PATH when run — no system PATH changes needed.

### 2. Download the scripts

Place the following batch files in the `windows\` folder:

- `drop_FILE_convert_p7_to_p8.bat` — single file converter
- `drop_FOLDER_batch_convert_p7_to_p8.bat` — batch folder converter
- `drop_FOLDER_scan_dv_profiles.bat` — library scanner

### 3. Download required binaries

Download the following and place the executables in the `windows\bin\` subfolder:

#### FFmpeg (includes ffprobe)
- Download from: **https://ffmpeg.org/download.html**
- Under Windows, choose a release build from **gyan.dev** or **BtbN**
- Extract the zip and copy `ffmpeg.exe` and `ffprobe.exe` from the `bin` folder into `windows\bin\`

#### dovi_tool
- Download from: **https://github.com/quietvoid/dovi_tool/releases**
- Download the latest release for your system (e.g. `dovi_tool-x.x.x-x86_64-pc-windows-msvc.zip` for 64-bit Windows)
- Extract and copy `dovi_tool.exe` into `windows\bin\`

#### MKVToolNix (mkvmerge + mkvextract)
- Download from: **https://mkvtoolnix.download/downloads.html**
- Install the application, then copy `mkvmerge.exe` and `mkvextract.exe` from the install location (typically `C:\Program Files\MKVToolNix\`) into `windows\bin\`

### 4. Verify the folder contents

Your folder should look like this:

```
windows\
  bin\
    ffmpeg.exe
    ffprobe.exe
    dovi_tool.exe
    mkvmerge.exe
    mkvextract.exe
  drop_FILE_convert_p7_to_p8.bat
  drop_FOLDER_batch_convert_p7_to_p8.bat
  drop_FOLDER_scan_dv_profiles.bat
```

### 5. Disk space

The scripts copy source files locally during processing. Ensure the drive containing the tools folder has at least **2× the size of your largest source file** free — typically 100-120 GB for a 50-60 GB UHD rip.

---

## Windows Scripts

### `drop_FILE_convert_p7_to_p8.bat` — Single File Converter

**Drag an MKV file onto this script** to convert it from Profile 7 to Profile 8.

**What it does:**
- Detects single-track or dual-track (BL+EL) Profile 7 sources automatically
- Copies the source file to a local `work\` subfolder before processing (avoids slow network read/write throughout)
- Converts RPU metadata from P7 to P8 using mode 2 (removes FEL luma/chroma mapping cleanly)
- Deletes intermediate files as it goes to minimise peak disk usage
- Remuxes all original audio and subtitle tracks
- Renames the original to `.bak`, copies the converted file back with the original filename, then deletes the `.bak`
- On error, preserves the work folder for investigation — the original is always safe until the final step

> ⚠️ **The original file will be deleted after successful conversion.** The converted file replaces it with the same filename so your media library metadata is preserved. Make a manual backup of any files you cannot afford to lose before running this script.

**Output:** Converted file replaces the original in the same folder. File size will be slightly smaller than the source (typically 8-10%) due to removal of the enhancement layer.

---

### `drop_FOLDER_batch_convert_p7_to_p8.bat` — Batch Folder Converter

**Drag a folder onto this script** to scan and convert all Profile 7 files within it recursively.

**What it does:**
- Scans all `.mkv`, `.mp4`, and `.ts` files in the folder and all subfolders
- Skips files that are not Profile 7 (Profile 8, non-DV, etc.)
- Converts each P7 file using the identical workflow to the single file converter
- On error for any file, logs the failure and moves on to the next file
- Writes a full log to `batch_convert_log.txt` in the tools folder

> ⚠️ **All Profile 7 files found in the folder will be converted and originals deleted.** This cannot be undone. Make a manual backup of your files before running this script if you need to preserve the originals.

**Note:** Files are processed sequentially. Given the copy-in / copy-back steps, a large library may take a significant time on a slow network connection.

---

### `drop_FOLDER_scan_dv_profiles.bat` — Library Scanner

**Drag a folder onto this script** to scan for Dolby Vision profiles across your media library.

**What it does:**
- Recursively scans all `.mkv`, `.mp4`, and `.ts` files
- Reports Profile 7, Profile 8, and any other DV profiles found
- Supports **multi-folder scanning** — results from multiple folders can be combined into a single report

**Output:** `dv_profile_scan.txt` in the tools folder, grouped by profile with totals.

**Multi-folder scanning:**
1. Drag the first folder → scan runs and results are saved
2. Drag another folder → prompted to add (`Y`) or start a new scan (`N`)
3. Repeat for as many folders as needed
4. Delete `tmp_scan_state.txt` in the tools folder to fully reset the session

---

## macOS Setup

### 1. Install Homebrew (if not already installed)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### 2. Install ffmpeg and MKVToolNix

```bash
brew install ffmpeg mkvtoolnix
```

### 3. Install dovi_tool

Download from: **https://github.com/quietvoid/dovi_tool/releases**

Download the latest release for your system (choose the universal macOS binary if available, otherwise the arm64 build for Apple Silicon or x86_64 for Intel), then install:

```bash
# Unzip, make executable, and move to PATH
chmod +x dovi_tool
sudo mv dovi_tool /usr/local/bin/
```

macOS Gatekeeper will block the binary on first run. Remove the quarantine flag:

```bash
xattr -d com.apple.quarantine /usr/local/bin/dovi_tool
```

Verify the install:

```bash
dovi_tool --version
```

### 4. Place the scripts and make them executable

Place the scripts in the `macos/` folder. If you prefer not to install `dovi_tool` system-wide via `/usr/local/bin`, you can instead place the binary in a `macos/bin/` subfolder — the scripts check there automatically.

```
macos/
  bin/
    dovi_tool                          ← optional, only if not installed system-wide
  drop_FILE_convert_compress.sh
  drop_FOLDER_batch_convert_p7_to_p8.sh
  drop_FOLDER_scan_dv_profiles.sh
```

Run the included setup script to set permissions in one step:

```bash
bash /path/to/macos/install.sh
```

Or set permissions manually:

```bash
chmod +x /path/to/drop_FILE_convert_compress.sh
chmod +x /path/to/drop_FOLDER_batch_convert_p7_to_p8.sh
chmod +x /path/to/drop_FOLDER_scan_dv_profiles.sh
```

### 5. Set up drag-and-drop (Automator)

macOS doesn't natively support dragging files onto shell scripts. Create an **Automator Application** wrapper for each script — a one-time 2-minute setup.

1. Open **Automator** (⌘ Space → Automator)
2. Choose **New Document → Application**
3. Search for **Run Shell Script** and double-click it
4. Set **Shell** to `/bin/bash` and **Pass input** to `as arguments`
5. Replace the default script content with:

```bash
for f in "$@"
do
    osascript -e "tell application \"Terminal\"
        activate
        do script \"/path/to/script.sh \" & quoted form of \"$f\"
    end tell"
done
```

6. Replace `/path/to/script.sh` with the full path to your script (drag the `.sh` file into Terminal to get its path)
7. Save as an Application — e.g. **Convert DV** or **Scan DV** — to your Applications folder or Desktop

Create one Automator Application per script (`drop_FILE_convert_compress.sh`, `drop_FOLDER_batch_convert_p7_to_p8.sh`, `drop_FOLDER_scan_dv_profiles.sh`), each pointing to its own script path.

**Automator variants for `drop_FILE_convert_compress.sh`:**

For fixed compress mode at 25 Mbps:
```bash
do script \"/path/to/drop_FILE_convert_compress.sh \" & quoted form of \"$f\" & \" 25\"
```

For remux-only mode (no re-encode, matches Windows workflow):
```bash
do script \"/path/to/drop_FILE_convert_compress.sh \" & quoted form of \"$f\" & \" remux\"
```

**Alternative — Terminal drag-and-drop** (no Automator needed):
1. Open Terminal, type `bash ` (with a trailing space)
2. Drag the script file onto the Terminal window
3. Type a space, drag your MKV or folder onto the Terminal window
4. Press Enter

### 6. Disk space

The scripts copy source files locally during processing. Ensure the drive containing the scripts has at least **2× the size of your source file** free for remux mode, or **3× the size** for compress mode (source + encoded stream + output).

---

## macOS Scripts

### `drop_FILE_convert_compress.sh` — Converter & Compressor

Handles P7→P8 remux (matching the Windows workflow), HEVC compression, and experimental AV1 compression. Drag an MKV onto the Automator wrapper, or run from Terminal.

**Modes:**

| Mode | Encoder | DV Profile | What it does |
|------|---------|------------|-------------|
| **Remux only** | None | P8 | Converts P7→P8, no re-encode. Replaces original. |
| **HEVC** | Apple VideoToolbox (GPU) | P8 | Hardware encode at target bitrate. Fast. |
| **AV1** | SVT-AV1 (CPU) | P10 | Experimental. Smaller files, slow encode, limited device support. |

When run interactively (no arguments) the script prompts for mode.

**Usage:**
```bash
./drop_FILE_convert_compress.sh /path/to/movie.mkv           # interactive — prompts for mode
./drop_FILE_convert_compress.sh /path/to/movie.mkv remux     # remux only, no re-encode
./drop_FILE_convert_compress.sh /path/to/movie.mkv 25        # HEVC at 25 Mbps
./drop_FILE_convert_compress.sh /path/to/movie.mkv av1       # AV1 at default CRF 27
./drop_FILE_convert_compress.sh /path/to/movie.mkv av1 22    # AV1 at custom CRF
```

**HEVC bitrate reference:**

| Bitrate | Quality equivalent | Approx size (2hr film) |
|---------|-------------------|------------------------|
| 15 Mbps | Amazon Prime 4K | ~14 GB |
| 22 Mbps | Apple iTunes 4K | ~20 GB |
| 25 Mbps | Apple TV+ 4K ← **default** | ~23 GB |
| 31 Mbps | iTunes peak | ~28 GB |

**AV1 CRF reference:**

| CRF | Quality equivalent | Approx size (2hr film) |
|-----|-------------------|------------------------|
| 22 | Very high quality | ~12 GB |
| 27 | iTunes equivalent ← **default** | ~8 GB |
| 32 | Streaming quality | ~5 GB |

> ⚠️ **AV1 mode is experimental.** Output is Dolby Vision Profile 10 (AV1 container). Device support is very limited — the current Apple TV 4K (2022, A15 chip) has no AV1 hardware decode and will struggle with 4K content. Verify playback compatibility on your target devices before converting your library. AV1 mode also requires a custom ffmpeg build — see [AV1 Setup](#av1-setup-macos) below.

**In all modes the script:**
- Copies the source locally before processing (shows rsync progress)
- Detects and handles P7 single-track and dual-track (BL+EL) sources automatically
- Lists all audio and subtitle tracks and prompts for which to keep
- Deletes intermediate files as it goes to minimise disk usage
- Pauses at completion so the Terminal window stays open

> ⚠️ **Remux mode deletes the original file after successful conversion.** Make a backup first if you need to preserve the original.

**Remux output:** Replaces the original file (same rename/delete workflow as Windows).
**HEVC output:** New file alongside the original, suffixed `_compressed`.
**AV1 output:** New file alongside the original, suffixed `_av1`.

---

### AV1 Setup (macOS)

The standard `brew install ffmpeg` does not include `libsvtav1` with Dolby Vision support. The script will detect this and display instructions if AV1 mode is selected without a compatible build.

**Option 1 — Homebrew tap with extra codecs:**
```bash
brew tap homebrew-ffmpeg/ffmpeg
brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-svt-av1
```

**Option 2 — Build from source:**
```bash
brew install svt-av1 pkg-config nasm
# Then follow: https://ercan.dev/blog/notes/build-ffmpeg-from-source-on-macos
# Ensure --enable-libsvtav1 is included in the ./configure flags
```

**Verify support after installation:**
```bash
ffmpeg -encoders | grep svtav1
ffmpeg -h encoder=libsvtav1 | grep dolbyvision
```


---


### `drop_FOLDER_batch_convert_p7_to_p8.sh` — Batch Folder Converter

**Drag a folder onto the Automator wrapper** (or run from Terminal) to scan and convert all Profile 7 files within it recursively.

**Usage:**
```bash
./drop_FOLDER_batch_convert_p7_to_p8.sh /path/to/folder
```

**What it does:**
- Scans all `.mkv`, `.mp4`, and `.ts` files in the folder and all subfolders
- Skips files that are not Profile 7 (Profile 8, non-DV, etc.)
- Converts each P7 file to Profile 8 using the same remux pipeline as the single-file script
- Handles both single-track and dual-track (BL+EL) P7 sources automatically
- All audio and subtitle tracks are preserved — no track selection (batch mode)
- On error for any file, logs the failure and continues to the next file
- Writes a full log to `batch_convert_log.txt` in the scripts folder

> ⚠️ **All Profile 7 files found in the folder will be converted and originals deleted.** This cannot be undone. Make a backup of your files before running this script if you need to preserve the originals.

**Output:** Each converted file replaces its original in-place (same rename/delete workflow as the single-file script).

---

### `drop_FOLDER_scan_dv_profiles.sh` — Library Scanner

Mirrors the Windows scanner. Drag a folder onto the Automator wrapper, or run from Terminal.

**Usage:**
```bash
./drop_FOLDER_scan_dv_profiles.sh /path/to/folder
```

**What it does:**
- Recursively scans all `.mkv`, `.mp4`, and `.ts` files
- Reports Profile 7, Profile 8, and any other DV profiles
- Supports multi-folder scanning with combined results

**Output:** `dv_profile_scan.txt` in the scripts folder.

**Multi-folder scanning:** Same as Windows — drag successive folders, choosing `Y` to append. Delete `tmp_scan_state.json` to reset the session.

---

## Workflow Notes

- **Network performance:** When the source file is on a network share (NAS), scripts copy it to a local work folder before processing. This avoids slow network read/write during every intermediate step. If the source file is already on the same local disk as the scripts, a hard link is created instead — no data is copied and no extra space is used for the source.
- **Disk space:** Intermediate files are deleted as soon as they are no longer needed to minimise peak disk usage. A free space check runs before each file is processed — if there is insufficient space, that file is skipped and logged, and the batch continues. See disk space notes in the setup sections above.
- **Error handling:** On failure, work folders are preserved for investigation. The original file is never deleted until the conversion is fully complete and the output has been successfully copied back.
- **Profile 7 dual-track:** Some disc rips store the Dolby Vision enhancement layer as a separate video track. All scripts detect this automatically and handle both single and dual-track sources without any configuration.
- **HDR10 fallback:** Profile 8 files embed DV metadata alongside a standard HDR10 base layer. Devices that don't support Dolby Vision play the HDR10 layer automatically — no separate HDR10 file is needed.
- **File size:** P7→P8 remux produces a file approximately 8-10% smaller than the source due to removal of the enhancement layer. No video quality is lost.
- **Visual quality vs disc playback:** Profile 7 FEL sources contain pixel-level correction data (luma/chroma residual) designed to be processed by dedicated disc player hardware. This residual is discarded during conversion — only the RPU dynamic metadata is preserved. In practice the difference is negligible: the base layer quality is already very high, the RPU (which drives DV's tone-mapping advantage over HDR10) is fully retained, and streaming devices never had access to FEL processing anyway. The converted P8 file is equivalent to what a streaming service would deliver.
