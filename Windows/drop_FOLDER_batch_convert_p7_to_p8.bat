@echo off
setlocal enabledelayedexpansion

cd /d "%~dp0"
set "PATH=%~dp0bin;%PATH%"

set "SCANDIR=%~1"
set "TMP_JSON=%~dp0tmp_probe.json"
set "TMP_DVLINE=%~dp0tmp_dvline.txt"
set "LOGFILE=%~dp0batch_convert_log.txt"

echo.
echo  Dolby Vision Batch Converter
echo  ------------------------------
echo  Folder: %SCANDIR%
echo  Log:    %LOGFILE%
echo.

if "%SCANDIR%"=="" (
    echo  ERROR: Drag a folder onto this batch file to scan it.
    pause
    exit /b 1
)

powershell -NoProfile -Command "if (Test-Path -LiteralPath $env:SCANDIR -PathType Container) { exit 0 } else { exit 1 }"
if errorlevel 1 (
    echo  ERROR: A file was dropped onto this script, or the folder was not found.
    echo  This script converts all Profile 7 files in a folder. Please drop a folder onto it.
    pause
    exit /b 1
)

echo.
echo  WARNING: ALL Profile 7 files found in this folder will be converted.
echo  Original files will be DELETED after successful conversion.
echo  Converted files will replace originals with the same filename.
echo  Recommend making a backup of your files before proceeding.
echo.
set /p CONFIRM=  Type YES to continue or press Ctrl+C to cancel: 
if /i "!CONFIRM!" neq "YES" (
    echo  Cancelled.
    pause
    exit /b 0
)
echo.
echo Dolby Vision Batch Convert Log > "%LOGFILE%"
echo Folder: %SCANDIR% >> "%LOGFILE%"
echo Started: %date% %time% >> "%LOGFILE%"
echo ---------------------------------------- >> "%LOGFILE%"

set SCAN_COUNT=0
set CONVERT_COUNT=0
set SKIP_COUNT=0
set ERROR_COUNT=0

for /r "%SCANDIR%" %%F in (*.mkv *.mp4 *.ts) do (
    set /a SCAN_COUNT+=1
    set "SOURCE=%%F"
    set "SOURCEDIR=%%~dpF"
    set "NAME=%%~nF"
    set "FILENAME=%%~nxF"

    echo.
    echo  [!SCAN_COUNT!] Checking: !FILENAME!

    set "PROFILE="
    ffprobe -v quiet -show_streams -of json "%%F" > "%TMP_JSON%" 2>&1
    findstr /i "dv_profile" "%TMP_JSON%" > "%TMP_DVLINE%" 2>nul
    for /f "usebackq delims=" %%I in ("%TMP_DVLINE%") do (
        set "LINE=%%I"
        set "LINE=!LINE: =!"
        set "LINE=!LINE:"=!"
        set "LINE=!LINE:,=!"
        for /f "tokens=2 delims=:" %%J in ("!LINE!") do set "PROFILE=%%J"
    )
    if exist "%TMP_DVLINE%" del "%TMP_DVLINE%"

    if "!PROFILE!"=="7" (
        echo  Profile 7 detected - converting...
        echo. >> "%LOGFILE%"
        echo CONVERTING: %%F >> "%LOGFILE%"
        call :convert "%%F"
        if !ERRORLEVEL!==0 (
            echo  SUCCESS: !FILENAME!
            echo STATUS: SUCCESS >> "%LOGFILE%"
            set /a CONVERT_COUNT+=1
        ) else (
            echo  FAILED: !FILENAME!
            echo STATUS: FAILED >> "%LOGFILE%"
            set /a ERROR_COUNT+=1
        )
    ) else if "!PROFILE!"=="" (
        echo  No DV profile detected - skipping.
        set /a SKIP_COUNT+=1
    ) else (
        echo  Profile !PROFILE! - skipping.
        set /a SKIP_COUNT+=1
    )
)

if exist "%TMP_JSON%" del "%TMP_JSON%"

echo.
echo ---------------------------------------- >> "%LOGFILE%"
echo Completed: %date% %time% >> "%LOGFILE%"
echo Scanned:   %SCAN_COUNT% >> "%LOGFILE%"
echo Converted: %CONVERT_COUNT% >> "%LOGFILE%"
echo Skipped:   %SKIP_COUNT% >> "%LOGFILE%"
echo Errors:    %ERROR_COUNT% >> "%LOGFILE%"

echo.
echo  ========================================
echo  Batch complete.
echo  Scanned:   %SCAN_COUNT%
echo  Converted: %CONVERT_COUNT%
echo  Skipped:   %SKIP_COUNT%
echo  Errors:    %ERROR_COUNT%
echo  Log saved to: %LOGFILE%
echo  ========================================
echo.
pause
exit /b 0

rem ========================================
rem  Conversion subroutine
rem ========================================
:convert
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

rem -----------------------------------------------
rem  Locality check - same drive = hard link, else copy
rem -----------------------------------------------
set "SRC_DRIVE=%SOURCE:~0,2%"
set "WORK_ROOT=%~dp0"
set "WORK_DRIVE=%WORK_ROOT:~0,2%"
set "IS_LOCAL=0"

if "!SRC_DRIVE:~0,1!"=="\" (
    echo  Source is a network path ^(UNC^) - will copy locally.
) else if /i "!SRC_DRIVE!"=="!WORK_DRIVE!" (
    echo  Source is on local disk - will hard-link instead of copying.
    set "IS_LOCAL=1"
) else (
    echo  Source is on a different drive - will copy locally.
)

rem -----------------------------------------------
rem  Free space check via PowerShell (handles large file sizes)
rem -----------------------------------------------
echo  Checking available disk space...
powershell -NoProfile -Command "[math]::Ceiling((Get-Item '%SOURCE%').Length/1MB)" > "%TEMP%\dv_size.tmp" 2>nul
set /p FILE_MB=<"%TEMP%\dv_size.tmp"
del "%TEMP%\dv_size.tmp" 2>nul
if not defined FILE_MB set FILE_MB=0

powershell -NoProfile -Command "[math]::Floor(([System.IO.DriveInfo]::new('%WORK_DRIVE%')).AvailableFreeSpace/1MB)" > "%TEMP%\dv_free.tmp" 2>nul
set /p FREE_MB=<"%TEMP%\dv_free.tmp"
del "%TEMP%\dv_free.tmp" 2>nul
if not defined FREE_MB set FREE_MB=0

if "!IS_LOCAL!"=="1" (
    set /a NEEDED_MB=FILE_MB * 2
) else (
    set /a NEEDED_MB=FILE_MB * 3
)

echo  Space check: need !NEEDED_MB! MB, have !FREE_MB! MB free on !WORK_DRIVE!.
if !FREE_MB! LSS !NEEDED_MB! (
    echo  ERROR: Insufficient disk space - skipping this file.
    echo STATUS: SKIPPED ^(insufficient disk space - need !NEEDED_MB! MB, have !FREE_MB! MB free^) >> "%LOGFILE%"
    exit /b 1
)

echo  Creating working directory...
mkdir "%WORKDIR%"
if errorlevel 1 goto :conv_error

if "!IS_LOCAL!"=="1" (
    echo  Hard-linking source ^(no copy needed^)...
    mklink /h "%LOCAL_SOURCE%" "%SOURCE%"
    if errorlevel 1 goto :conv_error
) else (
    echo  Copying source file locally...
    xcopy /j "%SOURCE%" "%LOCAL_SOURCE%*" /y
    if errorlevel 1 goto :conv_error
)

echo  Detecting video tracks...
set TRACK_COUNT=0
ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "%LOCAL_SOURCE%" > "%TMP_JSON%" 2>&1
for /f "usebackq" %%L in ("%TMP_JSON%") do set /a TRACK_COUNT+=1
if exist "%TMP_JSON%" del "%TMP_JSON%"
echo  Found %TRACK_COUNT% video track(s).

if "%TRACK_COUNT%"=="2" (
    echo  Dual-track - extracting base layer...
    ffmpeg -i "%LOCAL_SOURCE%" -map 0:v:0 -c:v copy -an "%BL%"
    if errorlevel 1 goto :conv_error

    echo  Extracting RPU from enhancement layer...
    ffmpeg -i "%LOCAL_SOURCE%" -map 0:v:1 -c:v copy -an "%EL%"
    if errorlevel 1 goto :conv_error
    dovi_tool extract-rpu -i "%EL%" -o "%RPU%"
    if errorlevel 1 goto :conv_error
    del "%EL%"

    echo  Injecting RPU and converting to Profile 8...
    dovi_tool inject-rpu -i "%BL%" --rpu-in "%RPU%" -o "%BL_WITH_RPU%"
    if errorlevel 1 goto :conv_error
    del "%BL%"
    del "%RPU%"
    dovi_tool -m 2 convert --discard -i "%BL_WITH_RPU%" -o "%HEVC_P8%"
    if errorlevel 1 goto :conv_error
    del "%BL_WITH_RPU%"

) else (
    echo  Single-track - extracting HEVC stream...
    ffmpeg -i "%LOCAL_SOURCE%" -c:v copy -an "%HEVC%"
    if errorlevel 1 goto :conv_error

    echo  Converting RPU to Profile 8...
    dovi_tool -m 2 convert --discard -i "%HEVC%" -o "%HEVC_P8%"
    if errorlevel 1 goto :conv_error
    del "%HEVC%"
)

echo  Remuxing into MKV...
mkvmerge -o "%WORKDIR%\output.mkv" "%HEVC_P8%" --no-video "%LOCAL_SOURCE%"
if errorlevel 1 goto :conv_error
del "%HEVC_P8%"
del "%LOCAL_SOURCE%"

echo  Renaming original to .bak...
rename "%SOURCE%" "%FILENAME%.bak"
if errorlevel 1 goto :conv_error

if "!IS_LOCAL!"=="1" (
    echo  Moving converted file into place...
    move "%WORKDIR%\output.mkv" "%SOURCEDIR%%FILENAME%"
    if errorlevel 1 goto :conv_error_after_rename
) else (
    echo  Copying converted file back...
    xcopy /j "%WORKDIR%\output.mkv" "%SOURCEDIR%%FILENAME%*" /y
    if errorlevel 1 goto :conv_error_after_rename
    del "%WORKDIR%\output.mkv"
)

echo  Deleting original .bak...
del "%SOURCE%.bak"

echo  Cleaning up work folder...
rd /s /q "%WORKDIR%"

exit /b 0

:conv_error
echo  ERROR during conversion - work folder preserved: %WORKDIR%
echo ERROR: work folder preserved at %WORKDIR% >> "%LOGFILE%"
if exist "%TMP_JSON%" del "%TMP_JSON%"
exit /b 1

:conv_error_after_rename
echo  ERROR copying back - original is at: %SOURCE%.bak
echo ERROR: copy back failed, original preserved as %SOURCE%.bak >> "%LOGFILE%"
exit /b 1
