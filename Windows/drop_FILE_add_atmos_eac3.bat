@echo off
setlocal enabledelayedexpansion

cd /d "%~dp0"
set "PATH=%~dp0bin;%PATH%"

set "SOURCE=%~1"
set "SOURCEDIR=%~dp1"
set "NAME=%~n1"
set "FILENAME=%~nx1"
set "WORKDIR=%~dp0work\%NAME%_atmos"
set "LOCAL_SOURCE=%WORKDIR%\%FILENAME%"
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

rem ---- Detect all TrueHD tracks (Atmos and non-Atmos) ----
echo  Detecting TrueHD tracks...
ffprobe -v quiet -show_streams -of json "%SOURCE%" > "%TMP_JSON%" 2>&1

rem Field 5 is is_atmos: 1 if profile or title contains Atmos, else 0
powershell -NoProfile -Command "$j=Get-Content '%TMP_JSON%'|ConvertFrom-Json;$i=0;$j.streams|%%{if($_.codec_type-eq'audio'){if($_.codec_name-eq'truehd'){$t=if($_.tags.title){$_.tags.title}else{'TrueHD'};$p=if($_.profile){$_.profile}else{''};$l=if($_.tags.language){$_.tags.language}else{'und'};$a=if(($p-match'(?i)atmos')-or($t-match'(?i)atmos')){'1'}else{'0'};$si=$_.index;Write-Output \"$i|$l|$t|$a|$si\"};$i++}}" > "%TMP_TRACKS%" 2>nul
if exist "%TMP_JSON%" del "%TMP_JSON%"

set TRUEHD_COUNT=0
set ATMOS_COUNT=0
set NON_ATMOS_COUNT=0
for /f "usebackq tokens=1,2,3,4,5 delims=|" %%A in ("%TMP_TRACKS%") do (
    set /a TRUEHD_COUNT+=1
    if "%%D"=="1" (set /a ATMOS_COUNT+=1) else (set /a NON_ATMOS_COUNT+=1)
)

if %TRUEHD_COUNT% EQU 0 (
    echo.
    echo  No TrueHD tracks found.
    if exist "%TMP_TRACKS%" del "%TMP_TRACKS%"
    pause
    exit /b 0
)

echo.
if %ATMOS_COUNT% GTR 0 (
    echo  TrueHD Atmos track(s) detected - will be converted ^(Apple TV compatibility + size saving^):
    echo.
    for /f "usebackq tokens=1,2,3,4,5 delims=|" %%A in ("%TMP_TRACKS%") do (
        if "%%D"=="1" echo    Audio stream %%A - %%C [%%B]
    )
    echo.
)

set CONVERT_NON_ATMOS=0
if %NON_ATMOS_COUNT% GTR 0 (
    echo  TrueHD track(s) without Atmos:
    echo.
    for /f "usebackq tokens=1,2,3,4,5 delims=|" %%A in ("%TMP_TRACKS%") do (
        if "%%D"=="0" echo    Audio stream %%A - %%C [%%B]
    )
    echo.
    echo  Converting to EAC3 at 768 kbps saves ~2-3 GB per 2-hour film.
    echo  WARNING: This is lossy - purely a size saving, not a compatibility issue.
    echo.
    set /p NON_ATMOS_CONV=  Convert non-Atmos TrueHD to EAC3 as well? [y/N]:
    if /i "!NON_ATMOS_CONV!"=="y" set CONVERT_NON_ATMOS=1
    echo.
)

if %ATMOS_COUNT% EQU 0 if !CONVERT_NON_ATMOS! EQU 0 (
    echo  Nothing to convert.
    if exist "%TMP_TRACKS%" del "%TMP_TRACKS%"
    pause
    exit /b 0
)

echo.
echo  Add EAC3 alongside the original TrueHD, or replace it?
echo    [1] Add     - keep TrueHD, add EAC3 track ^(larger file, max compatibility^)
echo    [2] Replace - remove TrueHD, EAC3 only ^(smaller file^)
echo.
set /p ADD_OR_REPLACE=  Choice [1/2]:
set REPLACE_TRUEHD=0
if "!ADD_OR_REPLACE!"=="2" set REPLACE_TRUEHD=1
echo.

echo  Output: %NAME%_atmos_eac3.mkv
if !REPLACE_TRUEHD! EQU 1 (
    echo  Original TrueHD tracks will be removed.
) else (
    echo  Original TrueHD tracks will be kept alongside the new EAC3 tracks.
)
echo.
pause

if not exist "%WORKDIR%" mkdir "%WORKDIR%"

rem ---- Copy source locally ----
echo.
echo  Copying source file locally...
xcopy /j "%SOURCE%" "%LOCAL_SOURCE%*" /y
if errorlevel 1 (
    echo  ERROR: Copy failed.
    pause
    exit /b 1
)
echo  Copy complete.

rem ---- Convert each TrueHD track ----
echo.
echo  Converting...
echo.

set TRACK_NUM=0
for /f "usebackq tokens=1,2,3,4,5 delims=|" %%A in ("%TMP_TRACKS%") do (
    set "AUDIO_IDX=%%A"
    set "TRACK_LANG=%%B"
    set "ORIG_TITLE=%%C"
    set "IS_ATMOS=%%D"
    set "STREAM_IDX=%%E"

    rem Skip non-Atmos tracks if user declined
    if "!IS_ATMOS!"=="0" if !CONVERT_NON_ATMOS! EQU 0 goto :skip_track

    set /a TRACK_NUM+=1
    set "EAC3_FILE=%WORKDIR%\track_%%A.eac3"
    set "NEW_TITLE=!ORIG_TITLE:TrueHD=EAC3!"

    if "!IS_ATMOS!"=="1" (
        echo  Track !TRACK_NUM!: !ORIG_TITLE! [stream !AUDIO_IDX!, Atmos]...
    ) else (
        echo  Track !TRACK_NUM!: !ORIG_TITLE! [stream !AUDIO_IDX!, size saving]...
    )
    ffmpeg -y -i "%LOCAL_SOURCE%" -map 0:a:!AUDIO_IDX! -c:a eac3 -b:a 768k "!EAC3_FILE!" 2>nul
    if errorlevel 1 (
        echo  ERROR: Conversion failed for track !TRACK_NUM!.
        if exist "%TMP_TRACKS%" del "%TMP_TRACKS%"
        pause
        exit /b 1
    )
    echo    Done: !NEW_TITLE!
    :skip_track
)

rem ---- Remux using PowerShell to handle dynamic arguments ----
echo.
echo  Building output MKV...

echo $tracks = Get-Content '%TMP_TRACKS%'>> "%TMP_PS%"
echo $convertNonAtmos = %CONVERT_NON_ATMOS%>> "%TMP_PS%"
echo $replaceTrueHD = %REPLACE_TRUEHD%>> "%TMP_PS%"
echo $excludeIdxs = @()>> "%TMP_PS%"
echo foreach ($t in $tracks) {>> "%TMP_PS%"
echo     $p = $t -split '\|', 5>> "%TMP_PS%"
echo     $isAtmos = $p[3] -eq '1'>> "%TMP_PS%"
echo     if (-not $isAtmos -and $convertNonAtmos -eq 0) { continue }>> "%TMP_PS%"
echo     $excludeIdxs += '!' + $p[4]>> "%TMP_PS%"
echo }>> "%TMP_PS%"
echo $a = @('-o', '%OUTPUT_MKV%')>> "%TMP_PS%"
echo if ($replaceTrueHD -eq 1 -and $excludeIdxs.Count -gt 0) {>> "%TMP_PS%"
echo     $a += '--audio-tracks', ($excludeIdxs -join ',')>> "%TMP_PS%"
echo }>> "%TMP_PS%"
echo $a += '%LOCAL_SOURCE%'>> "%TMP_PS%"
echo foreach ($t in $tracks) {>> "%TMP_PS%"
echo     $p = $t -split '\|', 5>> "%TMP_PS%"
echo     $isAtmos = $p[3] -eq '1'>> "%TMP_PS%"
echo     if (-not $isAtmos -and $convertNonAtmos -eq 0) { continue }>> "%TMP_PS%"
echo     $eac3 = '%WORKDIR%\track_' + $p[0] + '.eac3'>> "%TMP_PS%"
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
if exist "%LOCAL_SOURCE%" del "%LOCAL_SOURCE%"

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
