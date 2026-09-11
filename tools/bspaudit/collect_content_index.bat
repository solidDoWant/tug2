@echo off
REM Double-click me, or run me from a terminal.
REM Finds Steam and Insurgency on their own - no arguments needed.

setlocal
cd /d "%~dp0"

REM "py" is the Windows Python launcher and is what a normal python.org install provides.
where py >nul 2>&1 && (
    py -3 collect_content_index.py --out content_index.txt %*
    goto done
)
where python >nul 2>&1 && (
    python collect_content_index.py --out content_index.txt %*
    goto done
)

echo.
echo Python was not found on this machine.
echo.
echo Either install it from https://www.python.org/downloads/ ^(tick "Add python.exe to PATH"^),
echo or skip this entirely: zip up every *_dir.vpk file from
echo   ...\steamapps\common\insurgency2\insurgency\
echo and send those instead. They are small - the directory trees only, not the content - and
echo the index can be built from them elsewhere.
echo.

:done
echo.
pause
