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
set "TMP_JSON=%~dp0tmp_probe.json"
set "TMP_DVLINE=%~dp0tmp_dvline.txt"
set "TMP_AUDIO=%~dp0tmp_audio_tracks.txt"
set "TMP_SUBS=%~dp0tmp_sub_tracks.txt"
set "TMP_PS=%~dp0tmp_mkvmerge.ps1"
set "OUTPUT_MKV=%WORKDIR%\output.mkv"

echo.
echo  ================================================
echo  Dolby Vision P7 to P8 Converter - Windows
echo  ================================================
echo  Source: %FILENAME%
echo.

if "%SOURCE%"=="" (
    echo  ERROR: Drag an MKV file onto this batch file to use it.
    pause
    exit /b 1
)

dir "!SOURCE!\." >nul 2>&1
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

rem ---- DV Profile check ----
echo  Checking Dolby Vision profile...
set "PROFILE=."
ffprobe -v quiet -show_streams -of json "%SOURCE%" > "%TMP_JSON%" 2>&1
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
    echo  Profile 7 detected.
) else if "!PROFILE!"=="." (
    echo  No Dolby Vision profile detected - nothing to convert.
    if exist "%TMP_JSON%" del "%TMP_JSON%"
    pause
    exit /b 0
) else (
    echo  Profile !PROFILE! detected - already converted or not a P7 file.
    if exist "%TMP_JSON%" del "%TMP_JSON%"
    pause
    exit /b 0
)
echo.

rem ---- Track inspection ----
echo  Audio tracks:
powershell -NoProfile -Command "$j=Get-Content '%TMP_JSON%'|ConvertFrom-Json;$i=0;$j.streams|%%{if($_.codec_type-eq'audio'){$c=$_.codec_name;$si=$_.index;$ch=if($_.channels){$_.channels}else{0};$l=if($_.tags.language){$_.tags.language}else{'und'};$t=if($_.tags.title){$_.tags.title}else{''};$p=if($_.profile){$_.profile}else{''}; $ia=if($c-eq'truehd'-and(($p-match'(?i)atmos')-or($t-match'(?i)atmos'))){'1'}else{'0'};$it=if($c-eq'truehd'){'1'}else{'0'};Write-Output \"$i|$si|$c|$ch|$l|$t|$it|$ia\";$i++}}" > "%TMP_AUDIO%" 2>nul

set AUDIO_COUNT=0
for /f "usebackq tokens=1,2,3,4,5,6,7,8 delims=|" %%A in ("%TMP_AUDIO%") do (
    echo    [%%A] Track %%B - %%C %%Dch  lang:%%E  %%F
    set /a AUDIO_COUNT+=1
)
if !AUDIO_COUNT! EQU 0 echo    (none)
echo.
set "AUDIO_CHOICE=."
set /p AUDIO_CHOICE=  Audio tracks to keep (space-separated, Enter = all):
if "!AUDIO_CHOICE!"=="." set "AUDIO_CHOICE="
echo.

echo  Subtitle tracks:
powershell -NoProfile -Command "$j=Get-Content '%TMP_JSON%'|ConvertFrom-Json;$i=0;$j.streams|%%{if($_.codec_type-eq'subtitle'){$si=$_.index;$c=$_.codec_name;$l=if($_.tags.language){$_.tags.language}else{'und'};$t=if($_.tags.title){$_.tags.title}else{''}; Write-Output \"$i|$si|$c|$l|$t\";$i++}}" > "%TMP_SUBS%" 2>nul

set SUB_COUNT=0
for /f "usebackq tokens=1,2,3,4,5 delims=|" %%A in ("%TMP_SUBS%") do (
    echo    [%%A] Track %%B - %%C  lang:%%D  %%E
    set /a SUB_COUNT+=1
)
if !SUB_COUNT! EQU 0 echo    (none)
echo.
set "SUB_CHOICE=."
if !SUB_COUNT! GTR 0 (
    set /p SUB_CHOICE=  Subtitle tracks to keep (Enter = all, NONE = strip all):
    echo.
)
if "!SUB_CHOICE!"=="." set "SUB_CHOICE="
if exist "%TMP_JSON%" del "%TMP_JSON%"

rem ---- TrueHD / Atmos detection ----
set ATMOS_COUNT=0
set NON_ATMOS_TRUEHD_COUNT=0
for /f "usebackq tokens=1,2,3,4,5,6,7,8 delims=|" %%A in ("%TMP_AUDIO%") do (
    set "T_AIDX=%%A"
    set "T_IS_TRUEHD=%%G"
    set "T_IS_ATMOS=%%H"
    set INCLUDED=0
    if "!AUDIO_CHOICE!"=="" (
        set INCLUDED=1
    ) else (
        for %%X in (!AUDIO_CHOICE!) do if "%%X"=="!T_AIDX!" set INCLUDED=1
    )
    if !INCLUDED! EQU 1 if "!T_IS_ATMOS!"=="1" set /a ATMOS_COUNT+=1
    if !INCLUDED! EQU 1 if "!T_IS_TRUEHD!"=="1" if "!T_IS_ATMOS!"=="0" set /a NON_ATMOS_TRUEHD_COUNT+=1
)

set CONVERT_ATMOS=0
set CONVERT_NON_ATMOS=0
set REPLACE_TRUEHD=0

if !ATMOS_COUNT! GTR 0 (
    echo  TrueHD Atmos track(s) detected in selection:
    echo.
    for /f "usebackq tokens=1,2,3,4,5,6,7,8 delims=|" %%A in ("%TMP_AUDIO%") do (
        set "T_AIDX=%%A"
        set "T_LANG=%%E"
        set "T_TITLE=%%F"
        set "T_IS_ATMOS=%%H"
        set INCLUDED=0
        if "!AUDIO_CHOICE!"=="" (set INCLUDED=1) else (for %%X in (!AUDIO_CHOICE!) do if "%%X"=="!T_AIDX!" set INCLUDED=1)
        if !INCLUDED! EQU 1 if "!T_IS_ATMOS!"=="1" echo    [!T_AIDX!] !T_TITLE! [!T_LANG!]
    )
    echo.
    echo  Apple TV 4K passes TrueHD as multi-channel PCM, losing the Atmos layer.
    echo  Converting to EAC3 Atmos ^(768 kbps^) preserves the Atmos spatial metadata.
    echo  The TrueHD track will be replaced by EAC3 in the output.
    echo.
    set "ATMOS_CONV=."
    set /p ATMOS_CONV=  Convert TrueHD Atmos to EAC3 Atmos? [Y/n]:
    if /i "!ATMOS_CONV!"=="n" (set CONVERT_ATMOS=0) else (set CONVERT_ATMOS=1)
    echo.
)

if !NON_ATMOS_TRUEHD_COUNT! GTR 0 (
    echo  TrueHD track(s) without Atmos detected:
    echo.
    for /f "usebackq tokens=1,2,3,4,5,6,7,8 delims=|" %%A in ("%TMP_AUDIO%") do (
        set "T_AIDX=%%A"
        set "T_LANG=%%E"
        set "T_TITLE=%%F"
        set "T_IS_TRUEHD=%%G"
        set "T_IS_ATMOS=%%H"
        set INCLUDED=0
        if "!AUDIO_CHOICE!"=="" (set INCLUDED=1) else (for %%X in (!AUDIO_CHOICE!) do if "%%X"=="!T_AIDX!" set INCLUDED=1)
        if !INCLUDED! EQU 1 if "!T_IS_TRUEHD!"=="1" if "!T_IS_ATMOS!"=="0" echo    [!T_AIDX!] !T_TITLE! [!T_LANG!]
    )
    echo.
    echo  Converting to EAC3 at 768 kbps saves ~2-3 GB per 2-hour film.
    echo  WARNING: This is lossy - purely a size saving, not a compatibility issue.
    echo.
    set "NON_ATMOS_CONV=."
    set /p NON_ATMOS_CONV=  Convert to EAC3 for size saving? [y/N]:
    if /i "!NON_ATMOS_CONV!"=="y" set CONVERT_NON_ATMOS=1
    echo.
)

set NEED_REPLACE_PROMPT=0
if !CONVERT_ATMOS! EQU 1 set NEED_REPLACE_PROMPT=1
if !CONVERT_NON_ATMOS! EQU 1 set NEED_REPLACE_PROMPT=1

if !NEED_REPLACE_PROMPT! EQU 1 (
    echo  Add EAC3 alongside the original TrueHD, or replace it?
    echo    [1] Add     - keep TrueHD, add EAC3 track ^(larger file, max compatibility^)
    echo    [2] Replace - remove TrueHD, EAC3 only ^(smaller file^)
    echo.
    set "ADD_OR_REPLACE=."
    set /p ADD_OR_REPLACE=  Choice [1/2]:
    if "!ADD_OR_REPLACE!"=="2" set REPLACE_TRUEHD=1
    echo.
)

rem ---- Confirm destructive operation ----
echo  WARNING: The original source file will be DELETED after successful conversion.
echo  The converted file will replace it with the same filename.
echo  If you need to keep the original, cancel now and make a backup first.
echo.
set "CONFIRM=."
set /p CONFIRM=  Type YES to continue or press Ctrl+C to cancel:
if /i "!CONFIRM!" neq "YES" (
    echo  Cancelled.
    if exist "%TMP_AUDIO%" del "%TMP_AUDIO%"
    if exist "%TMP_SUBS%" del "%TMP_SUBS%"
    pause
    exit /b 0
)
echo.

rem ---- Create work dir and copy ----
echo  Creating working directory...
mkdir "%WORKDIR%"
if errorlevel 1 goto :error

echo.
echo  Copying source file locally (this may take a while)...
xcopy /j "%SOURCE%" "%LOCAL_SOURCE%*" /y
if errorlevel 1 goto :error

rem ---- EAC3 conversion ----
if !CONVERT_ATMOS! EQU 0 if !CONVERT_NON_ATMOS! EQU 0 goto :after_eac3

echo.
echo  Converting TrueHD to EAC3...
echo.

for /f "usebackq tokens=1,2,3,4,5,6,7,8 delims=|" %%A in ("%TMP_AUDIO%") do (
    set "T_AIDX=%%A"
    set "T_LANG=%%E"
    set "T_TITLE=%%F"
    set "T_IS_TRUEHD=%%G"
    set "T_IS_ATMOS=%%H"

    set INCLUDED=0
    if "!AUDIO_CHOICE!"=="" (set INCLUDED=1) else (for %%X in (!AUDIO_CHOICE!) do if "%%X"=="!T_AIDX!" set INCLUDED=1)

    set DO_CONV=0
    if !INCLUDED! EQU 1 if "!T_IS_ATMOS!"=="1" if !CONVERT_ATMOS! EQU 1 set DO_CONV=1
    if !INCLUDED! EQU 1 if "!T_IS_TRUEHD!"=="1" if "!T_IS_ATMOS!"=="0" if !CONVERT_NON_ATMOS! EQU 1 set DO_CONV=1

    if !DO_CONV! EQU 1 (
        set "EAC3_FILE=%WORKDIR%\truehd_!T_AIDX!.eac3"
        if "!T_IS_ATMOS!"=="1" (
            echo  Converting ^(Atmos^): !T_TITLE! ...
        ) else (
            echo  Converting ^(size saving^): !T_TITLE! ...
        )
        ffmpeg -y -i "%LOCAL_SOURCE%" -map 0:a:!T_AIDX! -c:a eac3 -b:a 768k "!EAC3_FILE!" 2>nul
        if errorlevel 1 (
            echo  ERROR: EAC3 conversion failed for: !T_TITLE!
            goto :error
        )
        echo    Done.
    )
)

:after_eac3

rem ---- Detect video tracks ----
echo.
echo  Detecting video tracks...
set TRACK_COUNT=0
ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "%LOCAL_SOURCE%" > "%TMP_JSON%" 2>&1
for /f "usebackq" %%L in ("%TMP_JSON%") do set /a TRACK_COUNT+=1
if exist "%TMP_JSON%" del "%TMP_JSON%"
echo  Found !TRACK_COUNT! video track(s).

if "!TRACK_COUNT!"=="2" (
    echo  Dual-track source - extracting base and enhancement layers...
    echo.

    echo  Extracting base layer...
    ffmpeg -i "%LOCAL_SOURCE%" -map 0:v:0 -c:v copy -an "%BL%"
    if errorlevel 1 goto :error

    echo.
    echo  Extracting RPU from enhancement layer...
    ffmpeg -i "%LOCAL_SOURCE%" -map 0:v:1 -c:v copy -an "%EL%"
    if errorlevel 1 goto :error
    dovi_tool extract-rpu -i "%EL%" -o "%RPU%"
    if errorlevel 1 goto :error
    del "%EL%"

    echo.
    echo  Injecting RPU and converting to Profile 8...
    dovi_tool inject-rpu -i "%BL%" --rpu-in "%RPU%" -o "%BL_WITH_RPU%"
    if errorlevel 1 goto :error
    del "%BL%"
    del "%RPU%"
    dovi_tool -m 2 convert --discard -i "%BL_WITH_RPU%" -o "%HEVC_P8%"
    if errorlevel 1 goto :error
    del "%BL_WITH_RPU%"

) else (
    echo  Single-track source.
    echo.

    echo  Extracting HEVC stream...
    ffmpeg -i "%LOCAL_SOURCE%" -c:v copy -an "%HEVC%"
    if errorlevel 1 goto :error

    echo.
    echo  Converting RPU from Profile 7 to Profile 8...
    dovi_tool -m 2 convert --discard -i "%HEVC%" -o "%HEVC_P8%"
    if errorlevel 1 goto :error
    del "%HEVC%"
)

rem ---- Remux via PowerShell (handles audio/subtitle/EAC3 args dynamically) ----
echo.
echo  Remuxing...

if exist "%TMP_PS%" del "%TMP_PS%"
echo $audioChoice = '!AUDIO_CHOICE!'> "%TMP_PS%"
echo $subChoice = '!SUB_CHOICE!'>> "%TMP_PS%"
echo $convertAtmos = %CONVERT_ATMOS%>> "%TMP_PS%"
echo $convertNonAtmos = %CONVERT_NON_ATMOS%>> "%TMP_PS%"
echo $replaceTrueHD = %REPLACE_TRUEHD%>> "%TMP_PS%"
echo $audioTracks = Get-Content '%TMP_AUDIO%'>> "%TMP_PS%"
echo $subTracks = @(); if (Test-Path '%TMP_SUBS%') { $subTracks = Get-Content '%TMP_SUBS%' }>> "%TMP_PS%"
echo $selectedAudioStreamIdxs = @()>> "%TMP_PS%"
echo foreach ($t in $audioTracks) {>> "%TMP_PS%"
echo     $p = $t -split '\|', 8>> "%TMP_PS%"
echo     if ($audioChoice -eq '') { $selectedAudioStreamIdxs += $p[1] }>> "%TMP_PS%"
echo     else { foreach ($n in ($audioChoice -split '\s+')) { if ($p[0] -eq $n) { $selectedAudioStreamIdxs += $p[1] } } }>> "%TMP_PS%"
echo }>> "%TMP_PS%"
echo $eac3Args = @()>> "%TMP_PS%"
echo $excludedStreamIdxs = @()>> "%TMP_PS%"
echo foreach ($t in $audioTracks) {>> "%TMP_PS%"
echo     $p = $t -split '\|', 8>> "%TMP_PS%"
echo     $aidx = $p[0]; $sidx = $p[1]; $isTrueHD = $p[6]; $isAtmos = $p[7]>> "%TMP_PS%"
echo     $inSel = $selectedAudioStreamIdxs -contains $sidx>> "%TMP_PS%"
echo     $doConv = ($isAtmos -eq '1' -and $convertAtmos -eq 1) -or ($isTrueHD -eq '1' -and $isAtmos -eq '0' -and $convertNonAtmos -eq 1)>> "%TMP_PS%"
echo     if ($inSel -and $doConv) {>> "%TMP_PS%"
echo         $eac3File = '%WORKDIR%\truehd_' + $aidx + '.eac3'>> "%TMP_PS%"
echo         $title = if ($p[5] -match '(?i)TrueHD') { $p[5] -replace '(?i)TrueHD', 'EAC3' } else { $p[5] + ' EAC3' }>> "%TMP_PS%"
echo         $eac3Args += '--language', ('0:' + $p[4]), '--track-name', ('0:' + $title), $eac3File>> "%TMP_PS%"
echo         if ($replaceTrueHD -eq 1) { $excludedStreamIdxs += $sidx }>> "%TMP_PS%"
echo     }>> "%TMP_PS%"
echo }>> "%TMP_PS%"
echo $keepAudio = $selectedAudioStreamIdxs | Where-Object { $excludedStreamIdxs -notcontains $_ }>> "%TMP_PS%"
echo $a = @('-o', '%OUTPUT_MKV%', '%HEVC_P8%')>> "%TMP_PS%"
echo if ($keepAudio.Count -eq 0) { $a += '--no-audio' } else { $a += '--audio-tracks', ($keepAudio -join ',') }>> "%TMP_PS%"
echo $sc = $subChoice.Trim()>> "%TMP_PS%"
echo if ($sc -match '(?i)^none$') { $a += '--no-subtitles' }>> "%TMP_PS%"
echo elseif ($sc -ne '') { $selSubs = @(); foreach ($t in $subTracks) { $p = $t -split '\|',5; foreach ($n in ($sc -split '\s+')) { if ($p[0] -eq $n) { $selSubs += $p[1] } } }; if ($selSubs.Count -gt 0) { $a += '--subtitle-tracks', ($selSubs -join ',') } }>> "%TMP_PS%"
echo $a += '--no-video', '%LOCAL_SOURCE%'>> "%TMP_PS%"
echo $a += $eac3Args>> "%TMP_PS%"
echo ^& mkvmerge @a>> "%TMP_PS%"
echo exit $LASTEXITCODE>> "%TMP_PS%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%TMP_PS%"
set MERGE_RESULT=%ERRORLEVEL%
if exist "%TMP_PS%" del "%TMP_PS%"
if exist "%TMP_AUDIO%" del "%TMP_AUDIO%"
if exist "%TMP_SUBS%" del "%TMP_SUBS%"
if exist "%HEVC_P8%" del "%HEVC_P8%"
if exist "%LOCAL_SOURCE%" del "%LOCAL_SOURCE%"

if %MERGE_RESULT% NEQ 0 goto :error

echo.
echo  Renaming original file to .bak...
rename "%SOURCE%" "%FILENAME%.bak"
if errorlevel 1 goto :error

echo.
echo  Copying converted file back...
xcopy /j "%OUTPUT_MKV%" "%SOURCEDIR%%FILENAME%*" /y
if errorlevel 1 goto :error_after_rename
del "%OUTPUT_MKV%"

echo.
echo  Deleting original .bak file...
del "%SOURCE%.bak"

echo.
echo  Removing working directory...
rd /s /q "%WORKDIR%"

echo.
echo  ================================================
echo  Done! Converted file saved as:
echo  %SOURCE%
echo  ================================================
echo.
pause
exit /b 0

:error
echo.
echo  ERROR: Something went wrong.
echo  Temporary files kept in: %WORKDIR%
echo  Original file is unchanged.
echo.
pause
exit /b 1

:error_after_rename
echo.
echo  ERROR: Failed to copy converted file back.
echo  Temporary files kept in: %WORKDIR%
echo  Original has been renamed to: %SOURCE%.bak
echo  Rename it back manually to restore it.
echo.
pause
exit /b 1
