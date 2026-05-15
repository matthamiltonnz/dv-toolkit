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
set "TMP_DVLINE=%~dp0tmp_dvline.txt"

rem Clean up any leftover files from previous runs
if exist "%~dp0tmp_scan_state.txt" del "%~dp0tmp_scan_state.txt" >nul 2>&1
if exist "%TMP_JSON%"   del "%TMP_JSON%" >nul 2>&1
if exist "%TMP_DVLINE%" del "%TMP_DVLINE%" >nul 2>&1
if exist "%TMP_P7%"     del "%TMP_P7%" >nul 2>&1
if exist "%TMP_P8%"     del "%TMP_P8%" >nul 2>&1
if exist "%TMP_OTHER%"  del "%TMP_OTHER%" >nul 2>&1

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

dir "!SCANDIR!\." >nul 2>&1
if errorlevel 1 (
    echo  ERROR: A file was dropped onto this script, or the folder was not found.
    echo  This script scans a folder. Please drop a folder onto it.
    pause
    exit /b 1
)

rem -----------------------------------------------
rem  Scan the folder
rem -----------------------------------------------
set COUNT=0
set COUNT_P7=0
set COUNT_P8=0
set COUNT_OTHER=0

copy nul "%TMP_P7%" /y >nul
copy nul "%TMP_P8%" /y >nul
copy nul "%TMP_OTHER%" /y >nul

echo.
echo  Scanning %SCANDIR%...
echo.

for /r "%SCANDIR%" %%F in (*.mkv *.mp4 *.ts) do (
    set /a COUNT+=1
    echo Checking !COUNT!: %%~nxF

    set "PROFILE=."
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
        echo   ^^^ PROFILE 7
        echo %%F >> "%TMP_P7%"
        set /a COUNT_P7+=1
    ) else if "!PROFILE!"=="8" (
        echo   ^^^ PROFILE 8
        echo %%F >> "%TMP_P8%"
        set /a COUNT_P8+=1
    ) else if not "!PROFILE!"=="." (
        echo   ^^^ PROFILE !PROFILE!
        echo [Profile !PROFILE!] %%F >> "%TMP_OTHER%"
        set /a COUNT_OTHER+=1
    )
)

if exist "%TMP_JSON%" del "%TMP_JSON%"

rem -----------------------------------------------
rem  Write report
rem -----------------------------------------------
echo Dolby Vision Profile Scan > "%OUTFILE%"
echo Last updated: %date% %time% >> "%OUTFILE%"
echo. >> "%OUTFILE%"
echo FOLDER SCANNED >> "%OUTFILE%"
echo ---------------------------------------- >> "%OUTFILE%"
echo %SCANDIR% >> "%OUTFILE%"

echo. >> "%OUTFILE%"
echo PROFILE 7 FILES (%COUNT_P7%) >> "%OUTFILE%"
echo ---------------------------------------- >> "%OUTFILE%"
type "%TMP_P7%" >> "%OUTFILE%"

echo. >> "%OUTFILE%"
echo PROFILE 8 FILES (%COUNT_P8%) >> "%OUTFILE%"
echo ---------------------------------------- >> "%OUTFILE%"
type "%TMP_P8%" >> "%OUTFILE%"

if %COUNT_OTHER% GTR 0 (
    echo. >> "%OUTFILE%"
    echo OTHER DV PROFILES (%COUNT_OTHER%) >> "%OUTFILE%"
    echo ---------------------------------------- >> "%OUTFILE%"
    type "%TMP_OTHER%" >> "%OUTFILE%"
)

echo. >> "%OUTFILE%"
echo ---------------------------------------- >> "%OUTFILE%"
echo Total scanned:   %COUNT% >> "%OUTFILE%"
echo Profile 7 found: %COUNT_P7% >> "%OUTFILE%"
echo Profile 8 found: %COUNT_P8% >> "%OUTFILE%"
if %COUNT_OTHER% GTR 0 echo Other DV found:  %COUNT_OTHER% >> "%OUTFILE%"

del "%TMP_P7%" >nul 2>&1
del "%TMP_P8%" >nul 2>&1
del "%TMP_OTHER%" >nul 2>&1

rem -----------------------------------------------
rem  Summary
rem -----------------------------------------------
echo.
echo  ========================================
echo  Scan complete.
echo  Scanned:   %COUNT%
echo  Profile 7: %COUNT_P7%
echo  Profile 8: %COUNT_P8%
if %COUNT_OTHER% GTR 0 echo  Other DV:  %COUNT_OTHER%
echo  ========================================
echo.
echo  Report saved to: %OUTFILE%
echo.
pause
