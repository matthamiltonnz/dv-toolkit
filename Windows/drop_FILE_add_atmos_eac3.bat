@echo off
setlocal enabledelayedexpansion

cd /d "%~dp0"
set "PATH=%~dp0bin;%PATH%"

set "SOURCE=%~1"
set "SOURCEDIR=%~dp1"
set "NAME=%~n1"
set "FILENAME=%~nx1"
set "WORKDIR=%~dp0work\%NAME%_atmos"
set "TMP_JSON=%~dp0tmp_probe.json"
set "TMP_TRACKS=%~dp0tmp_atmos_tracks.txt"
set "TMP_PS=%~dp0tmp_mkvmerge.ps1"
set "OUTPUT_MKV=%WORKDIR%\output.mkv"
set "OUTPUT_FINAL=%SOURCEDIR%%NAME%_atmos_eac3.mkv"

echo.
echo  ================================================
echo  TrueHD Atmos to EAC3 Atmos Converter
echo  ================================================
echo  Source:  %FILENAME%
echo  Output:  %NAME%_atmos_eac3.mkv
echo.

if "%SOURCE%"=="" (
    echo  ERROR: Drag an MKV file onto this batch file to use it.
    pause
    exit /b 1
)

dir "!SOURCE!\." >nul 2>&1
if not errorlevel 1 (
    echo  ERROR: A folder was dropped. This script processes a single MKV file.
    pause
    exit /b 1
)

if not exist "%SOURCE%" (
    echo  ERROR: Source file not found.
    pause
    exit /b 1
)

rem ---- Detect TrueHD Atmos tracks ----
echo  Detecting TrueHD Atmos tracks...
ffprobe -v quiet -show_streams -of json "%SOURCE%" > "%TMP_JSON%" 2>&1

powershell -NoProfile -Command "$j=Get-Content '%TMP_JSON%'|ConvertFrom-Json;$i=0;$j.streams|%%{if($_.codec_type-eq'audio'){if($_.codec_name-eq'truehd'){$t=if($_.tags.title){$_.tags.title}else{'TrueHD Atmos'};if($t-match'(?i)atmos'){$l=if($_.tags.language){$_.tags.language}else{'und'};Write-Output \"$i|$l|$t\"}};$i++}}" > "%TMP_TRACKS%" 2>nul
if exist "%TMP_JSON%" del "%TMP_JSON%"

set ATMOS_COUNT=0
for /f "usebackq delims=" %%L in ("%TMP_TRACKS%") do set /a ATMOS_COUNT+=1

if %ATMOS_COUNT% EQU 0 (
    echo.
    echo  No TrueHD Atmos tracks found.
    echo  Tracks must have 'Atmos' in their title tag to be detected.
    if exist "%TMP_TRACKS%" del "%TMP_TRACKS%"
    pause
    exit /b 0
)

echo  Found %ATMOS_COUNT% TrueHD Atmos track(s):
echo.
for /f "usebackq tokens=1,2,3 delims=|" %%A in ("%TMP_TRACKS%") do (
    echo    Audio stream %%A - %%C [%%B]
)
echo.
echo  Each track will be converted to EAC3 Atmos at 768 kbps.
echo  The original TrueHD track will be kept.
echo  Output: %NAME%_atmos_eac3.mkv
echo.
pause

if not exist "%WORKDIR%" mkdir "%WORKDIR%"

rem ---- Convert each TrueHD Atmos track ----
echo.
echo  Converting...
echo.

set TRACK_NUM=0
for /f "usebackq tokens=1,2,3 delims=|" %%A in ("%TMP_TRACKS%") do (
    set /a TRACK_NUM+=1
    set "EAC3_FILE=%WORKDIR%\atmos_%%A.eac3"
    set "ORIG_TITLE=%%C"
    set "NEW_TITLE=!ORIG_TITLE:TrueHD=EAC3!"
    set "TRACK_LANG=%%B"
    set "AUDIO_IDX=%%A"

    echo  Track !TRACK_NUM! of %ATMOS_COUNT%: !ORIG_TITLE! [audio stream !AUDIO_IDX!]...
    ffmpeg -y -i "%SOURCE%" -map 0:a:!AUDIO_IDX! -c:a eac3 -b:a 768k "!EAC3_FILE!" 2>nul
    if errorlevel 1 (
        echo  ERROR: Conversion failed for track !TRACK_NUM!.
        if exist "%TMP_TRACKS%" del "%TMP_TRACKS%"
        pause
        exit /b 1
    )
    echo    Done: !NEW_TITLE!
)

rem ---- Remux using PowerShell to handle dynamic arguments ----
echo.
echo  Building output MKV...

echo $tracks = Get-Content '%TMP_TRACKS%'> "%TMP_PS%"
echo $a = @('-o', '%OUTPUT_MKV%', '%SOURCE%')>> "%TMP_PS%"
echo foreach ($t in $tracks) {>> "%TMP_PS%"
echo     $p = $t -split '\|', 3>> "%TMP_PS%"
echo     $eac3 = '%WORKDIR%\atmos_' + $p[0] + '.eac3'>> "%TMP_PS%"
echo     $title = $p[2] -replace 'TrueHD', 'EAC3'>> "%TMP_PS%"
echo     $a += '--language', ('0:' + $p[1]), '--track-name', ('0:' + $title), $eac3>> "%TMP_PS%"
echo }>> "%TMP_PS%"
echo & mkvmerge @a>> "%TMP_PS%"
echo exit $LASTEXITCODE>> "%TMP_PS%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%TMP_PS%"
set MERGE_RESULT=%ERRORLEVEL%
if exist "%TMP_PS%" del "%TMP_PS%"
if exist "%TMP_TRACKS%" del "%TMP_TRACKS%"

if %MERGE_RESULT% NEQ 0 (
    echo  ERROR: mkvmerge failed.
    pause
    exit /b 1
)
echo  Remux complete.

rem ---- Move output into place ----
echo.
echo  Moving output into place...
if exist "%OUTPUT_FINAL%" del "%OUTPUT_FINAL%"
move /y "%OUTPUT_MKV%" "%OUTPUT_FINAL%" >nul
if errorlevel 1 (
    echo  ERROR: Failed to move output file to destination.
    echo  Output is at: %OUTPUT_MKV%
    pause
    exit /b 1
)

rem ---- Cleanup ----
if exist "%WORKDIR%" rmdir /s /q "%WORKDIR%"

echo.
echo  ========================================
echo  Complete.
echo  Output: %NAME%_atmos_eac3.mkv
echo  ========================================
echo.
pause
