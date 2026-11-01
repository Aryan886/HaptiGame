@echo off
rem Phantom Defense launcher: starts the haptic bridge, then the game.
rem Usage: run_demo.bat [simulator^|fake^|serial] [extra bridge args, e.g. --port COM5 --profile eight]
rem Set GODOT to override the Godot executable used when no export exists.
setlocal
cd /d "%~dp0"
set BACKEND=%1
if "%BACKEND%"=="" set BACKEND=simulator
if not defined GODOT set GODOT=C:\Godot\Godot_v4.7.2-stable_win64.exe

start "phantom bridge (%BACKEND%)" cmd /k python bridge\main.py --backend %BACKEND% %2 %3 %4 %5 %6
timeout /t 1 /nobreak >nul

if exist game\export\phantom_defense.exe (
  start "" game\export\phantom_defense.exe
) else (
  if not exist "%GODOT%" (
    echo Godot not found at %GODOT%. Set GODOT or export the game to game\export\phantom_defense.exe.
    exit /b 1
  )
  start "" "%GODOT%" --path game
)
endlocal
