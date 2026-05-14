@echo off
setlocal enabledelayedexpansion

cd /d "%~dp0"
set "PATH=%~dp0bin;%PATH%"

set "SCANDIR=%~1"
set "OUTFILE=%~dp0dv_profile_scan.txt"
set "TMP_P7=%~dp0tmp_p7.txt"
set "TMP_P8=%~dp0tmp_p8.txt"
set "TMP_OTHER=%~dp0tmp_other.txt"
set "TMP_JSON=%~dp0tmp_probe.json"
set "TMP_STATE=%~dp0tmp_scan_state.txt"

echo.
echo  Dolby Vision Profile Scanner
echo  ------------------------------
echo  Scanning: %SCANDIR%
echo  Output:   %OUTFILE%
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

rem -----------------------------------------------
rem  Check for existing report and prompt user
rem -----------------------------------------------
set "APPEND=0"
set "PREV_COUNT=0"
set "PREV_P7=0"
set "PREV_P8=0"
set "PREV_OTHER=0"
set "PREV_FOLDERS="

if exist "%TMP_STATE%" (
    echo  An existing scan session was found.
    echo.
    for /f "tokens=1,* delims==" %%A in (%TMP_STATE%) do (
        if "%%A"=="COUNT"   set "PREV_COUNT=%%B"
        if "%%A"=="P7"      set "PREV_P7=%%B"
        if "%%A"=="P8"      set "PREV_P8=%%B"
        if "%%A"=="OTHER"   set "PREV_OTHER=%%B"
        if "%%A"=="FOLDERS" set "PREV_FOLDERS=%%B"
    )
    echo  Previous folders scanned:
    for %%F in ("%PREV_FOLDERS:;=" "%") do echo    %%~F
    echo  Files scanned so far: %PREV_COUNT%
    echo  Profile 7: %PREV_P7%  Profile 8: %PREV_P8%
    echo.
    set /p "CHOICE=  Add this folder to existing results? [Y=Add / N=Start new scan]: "
    if /i "!CHOICE!"=="Y" set "APPEND=1"
)

if "!APPEND!"=="0" (
    rem Start fresh - clear all temp files
    type nul > "%TMP_P7%"
    type nul > "%TMP_P8%"
    type nul > "%TMP_OTHER%"
    set "PREV_COUNT=0"
    set "PREV_P7=0"
    set "PREV_P8=0"
    set "PREV_OTHER=0"
    set "PREV_FOLDERS="
) else (
    rem Restore previous file lists if they exist
    if not exist "%TMP_P7%"    type nul > "%TMP_P7%"
    if not exist "%TMP_P8%"    type nul > "%TMP_P8%"
    if not exist "%TMP_OTHER%" type nul > "%TMP_OTHER%"
)

rem -----------------------------------------------
rem  Scan the folder
rem -----------------------------------------------
set COUNT=0
set COUNT_P7=0
set COUNT_P8=0
set COUNT_OTHER=0

echo.
echo  Scanning %SCANDIR%...
echo.

for /r "%SCANDIR%" %%F in (*.mkv *.mp4 *.ts) do (
    set /a COUNT+=1
    echo Checking !COUNT!: %%~nxF

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
        echo   ^^^ PROFILE 7
        echo %%F >> "%TMP_P7%"
        set /a COUNT_P7+=1
    ) else if "!PROFILE!"=="8" (
        echo   ^^^ PROFILE 8
        echo %%F >> "%TMP_P8%"
        set /a COUNT_P8+=1
    ) else if not "!PROFILE!"=="" (
        echo   ^^^ PROFILE !PROFILE!
        echo [Profile !PROFILE!] %%F >> "%TMP_OTHER%"
        set /a COUNT_OTHER+=1
    )
)

if exist "%TMP_JSON%" del "%TMP_JSON%"

rem -----------------------------------------------
rem  Combine with previous totals
rem -----------------------------------------------
set /a TOTAL_COUNT=PREV_COUNT+COUNT
set /a TOTAL_P7=PREV_P7+COUNT_P7
set /a TOTAL_P8=PREV_P8+COUNT_P8
set /a TOTAL_OTHER=PREV_OTHER+COUNT_OTHER

rem Build folder list
if "!PREV_FOLDERS!"=="" (
    set "ALL_FOLDERS=%SCANDIR%"
) else (
    set "ALL_FOLDERS=!PREV_FOLDERS!;%SCANDIR%"
)

rem -----------------------------------------------
rem  Save state for next run
rem -----------------------------------------------
echo COUNT=%TOTAL_COUNT%> "%TMP_STATE%"
echo P7=%TOTAL_P7%>> "%TMP_STATE%"
echo P8=%TOTAL_P8%>> "%TMP_STATE%"
echo OTHER=%TOTAL_OTHER%>> "%TMP_STATE%"
echo FOLDERS=!ALL_FOLDERS!>> "%TMP_STATE%"

rem -----------------------------------------------
rem  Write report
rem -----------------------------------------------
echo Dolby Vision Profile Scan > "%OUTFILE%"
echo Last updated: %date% %time% >> "%OUTFILE%"
echo. >> "%OUTFILE%"
echo FOLDERS SCANNED >> "%OUTFILE%"
echo ---------------------------------------- >> "%OUTFILE%"
for %%F in ("!ALL_FOLDERS:;=" "!") do echo %%~F >> "%OUTFILE%"

echo. >> "%OUTFILE%"
echo PROFILE 7 FILES (%TOTAL_P7%) >> "%OUTFILE%"
echo ---------------------------------------- >> "%OUTFILE%"
type "%TMP_P7%" >> "%OUTFILE%"

echo. >> "%OUTFILE%"
echo PROFILE 8 FILES (%TOTAL_P8%) >> "%OUTFILE%"
echo ---------------------------------------- >> "%OUTFILE%"
type "%TMP_P8%" >> "%OUTFILE%"

if %TOTAL_OTHER% GTR 0 (
    echo. >> "%OUTFILE%"
    echo OTHER DV PROFILES (%TOTAL_OTHER%) >> "%OUTFILE%"
    echo ---------------------------------------- >> "%OUTFILE%"
    type "%TMP_OTHER%" >> "%OUTFILE%"
)

echo. >> "%OUTFILE%"
echo ---------------------------------------- >> "%OUTFILE%"
echo Total scanned:   %TOTAL_COUNT% >> "%OUTFILE%"
echo Profile 7 found: %TOTAL_P7% >> "%OUTFILE%"
echo Profile 8 found: %TOTAL_P8% >> "%OUTFILE%"
if %TOTAL_OTHER% GTR 0 echo Other DV found:  %TOTAL_OTHER% >> "%OUTFILE%"

rem -----------------------------------------------
rem  Summary
rem -----------------------------------------------
echo.
echo  ========================================
echo  Folder scan complete.
echo  This folder - scanned: %COUNT%  P7: %COUNT_P7%  P8: %COUNT_P8%
echo  ----------------------------------------
echo  Combined totals across all folders:
echo  Scanned:   %TOTAL_COUNT%
echo  Profile 7: %TOTAL_P7%
echo  Profile 8: %TOTAL_P8%
if %TOTAL_OTHER% GTR 0 echo  Other DV:  %TOTAL_OTHER%
echo  ========================================
echo.
echo  Report saved to: %OUTFILE%
echo.
echo  Tip: Drag another folder onto this script to add to the report,
echo       or drag a new folder and choose N to start a fresh scan.
echo.
pause
