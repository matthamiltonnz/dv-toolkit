@echo off
setlocal enabledelayedexpansion

cd /d "%~dp0"
set "PATH=%~dp0bin;%PATH%"

set "SCANDIR=%~1"
set "TMP_JSON=%~dp0tmp_probe.json"
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

if not exist "%SCANDIR%" (
    echo  ERROR: Folder not found.
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
    for /f "delims=" %%I in ('findstr /i "dv_profile" "%TMP_JSON%"') do (
        set "LINE=%%I"
        set "LINE=!LINE: =!"
        set "LINE=!LINE:"=!"
        set "LINE=!LINE:,=!"
        for /f "tokens=2 delims=:" %%J in ("!LINE!") do set "PROFILE=%%J"
    )

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

echo  Creating working directory...
mkdir "%WORKDIR%"
if errorlevel 1 goto :conv_error

echo  Copying source file locally...
xcopy /j "%SOURCE%" "%LOCAL_SOURCE%*" /y
if errorlevel 1 goto :conv_error

echo  Detecting video tracks...
set TRACK_COUNT=0
for /f %%C in ('ffprobe -v error -select_streams v -show_entries stream^=index -of csv^=p^=0 "%LOCAL_SOURCE%" 2^>^&1 ^| find /c /v ""') do set TRACK_COUNT=%%C
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

echo  Copying converted file back...
xcopy /j "%WORKDIR%\output.mkv" "%SOURCEDIR%%FILENAME%*" /y
if errorlevel 1 goto :conv_error_after_rename
del "%WORKDIR%\output.mkv"

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
