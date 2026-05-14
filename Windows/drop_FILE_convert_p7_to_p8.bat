@echo off
setlocal enabledelayedexpansion

cd /d "%~dp0"
set "PATH=%~dp0bin;%PATH%"

set "SOURCE=%~1"
set "SOURCEDIR=%~dp1"
set "NAME=%~n1"
set "FILENAME=%~nx1"
set "WORKDIR=%~dp0work\%NAME%"
set "LOCAL_SOURCE=%WORKDIR%\%FILENAME%"
set "BL=%WORKDIR%\bl.hevc"
set "EL=%WORKDIR%\el.hevc"
set "RPU=%WORKDIR%\rpu.bin"
set "BL_WITH_RPU=%WORKDIR%\bl_rpu.hevc"
set "HEVC=%WORKDIR%\source.hevc"
set "HEVC_P8=%WORKDIR%\output_p8.hevc"

echo.
echo  Dolby Vision Profile 7 ^> Profile 8 Converter
echo  -----------------------------------------------
echo  Source:  %SOURCE%
echo  Output:  %SOURCE% ^(original renamed to .bak^)
echo  Workdir: %WORKDIR%
if "%SOURCE%"=="" (
    echo  ERROR: Drag an MKV file onto this batch file to use it.
    pause
    exit /b 1
)

powershell -NoProfile -Command "if (Test-Path -LiteralPath $env:SOURCE -PathType Container) { exit 0 } else { exit 1 }"
if not errorlevel 1 (
    echo  ERROR: A folder was dropped onto this script.
    echo  This script converts a single video file.
    echo  To convert all files in a folder, use drop_FOLDER_batch_convert_p7_to_p8.bat
    pause
    exit /b 1
)

if not exist "%SOURCE%" (
    echo  ERROR: Source file not found.
    pause
    exit /b 1
)

echo  WARNING: The original source file will be DELETED after successful conversion.
echo  The converted file will replace it with the same filename.
echo  If you need to keep the original, cancel now and make a backup first.
echo.
set /p CONFIRM=  Type YES to continue or press Ctrl+C to cancel: 
if /i "!CONFIRM!" neq "YES" (
    echo  Cancelled.
    pause
    exit /b 0
)
echo.
echo  [1/7] Creating working directory...
mkdir "%WORKDIR%"
if errorlevel 1 goto :error

echo.
echo  [2/7] Copying source file locally ^(this may take a while^)...
xcopy /j "%SOURCE%" "%LOCAL_SOURCE%*" /y
if errorlevel 1 goto :error

echo.
echo  [3/7] Detecting video tracks...
set TRACK_COUNT=0
ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "%LOCAL_SOURCE%" > "%TMP_JSON%" 2>&1
for /f "usebackq" %%L in ("%TMP_JSON%") do set /a TRACK_COUNT+=1
if exist "%TMP_JSON%" del "%TMP_JSON%"
echo  Found !TRACK_COUNT! video track(s).
if "!TRACK_COUNT!"=="2" (
    echo  Dual-track source detected - extracting base layer and enhancement layer separately...
    echo.

    echo  [4/7] Extracting base layer ^(track 0^)...
    ffmpeg -i "%LOCAL_SOURCE%" -map 0:v:0 -c:v copy -an "%BL%"
    if errorlevel 1 goto :error

    echo.
    echo  [5/7] Extracting RPU from enhancement layer ^(track 1^)...
    ffmpeg -i "%LOCAL_SOURCE%" -map 0:v:1 -c:v copy -an "%EL%"
    if errorlevel 1 goto :error
    dovi_tool extract-rpu -i "%EL%" -o "%RPU%"
    if errorlevel 1 goto :error
    del "%EL%"

    echo.
    echo  [6/7] Injecting RPU into base layer and converting to Profile 8...
    dovi_tool inject-rpu -i "%BL%" --rpu-in "%RPU%" -o "%BL_WITH_RPU%"
    if errorlevel 1 goto :error
    del "%BL%"
    del "%RPU%"
    dovi_tool -m 2 convert --discard -i "%BL_WITH_RPU%" -o "%HEVC_P8%"
    if errorlevel 1 goto :error
    del "%BL_WITH_RPU%"

) else (
    echo  Single-track source detected.
    echo.

    echo  [4/7] Extracting HEVC stream...
    ffmpeg -i "%LOCAL_SOURCE%" -c:v copy -an "%HEVC%"
    if errorlevel 1 goto :error

    echo  [5/7] Skipped ^(no separate EL track^).

    echo.
    echo  [6/7] Converting RPU from Profile 7 to Profile 8...
    dovi_tool -m 2 convert --discard -i "%HEVC%" -o "%HEVC_P8%"
    if errorlevel 1 goto :error
    del "%HEVC%"
)

echo.
echo  [7/7] Remuxing into MKV...
mkvmerge -o "%WORKDIR%\output.mkv" "%HEVC_P8%" --no-video "%LOCAL_SOURCE%"
if errorlevel 1 goto :error
del "%HEVC_P8%"
del "%LOCAL_SOURCE%"

echo.
echo  Renaming original file to .bak...
rename "%SOURCE%" "%FILENAME%.bak"
if errorlevel 1 goto :error

echo.
echo  Copying converted file back as original filename...
xcopy /j "%WORKDIR%\output.mkv" "%SOURCEDIR%%FILENAME%*" /y
if errorlevel 1 goto :error_after_rename
del "%WORKDIR%\output.mkv"
echo.
echo  Deleting original .bak file...
del "%SOURCE%.bak"

echo.
echo  [Cleanup] Removing working directory...
rd /s /q "%WORKDIR%"


echo  Done! Converted file saved as:
echo  %SOURCE%
echo.
pause
exit /b 0

:error
echo.
echo  ERROR: Something went wrong at the above step.
echo  Temporary files kept in: %WORKDIR%
echo  Original file is unchanged.
echo  Remove the work folder manually once you have investigated.
echo.
pause
exit /b 1

:error_after_rename
echo.
echo  ERROR: Failed to copy converted file back.
echo  Temporary files kept in: %WORKDIR%
echo  Original file has been renamed to: %SOURCE%.bak
echo  Rename it back manually to restore it.
echo.
pause
exit /b 1
