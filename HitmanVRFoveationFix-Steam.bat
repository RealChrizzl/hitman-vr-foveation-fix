@echo off
rem  Steam launch option wrapper. Set HITMAN's launch options to:
rem      "<this folder>\HitmanVRFoveationFix-Steam.bat" %%command%%
rem  It starts the fix through the scheduled task from
rem  HitmanVRFoveationFix-AutoStart.bat (no UAC prompt), then the game.
rem  Without that task it falls back to a normal start with a UAC prompt.
schtasks /run /tn "HitmanVRFoveationFix" >nul 2>&1 || start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0HitmanVRFoveationFix.ps1" -ExitWithGame
if "%~1"=="" exit /b
%*
