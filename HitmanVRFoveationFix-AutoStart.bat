@echo off
rem  Run once to install (or remove) automatic start with the game.
rem  It only launches the PowerShell script that sits next to it.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0HitmanVRFoveationFix-AutoStart.ps1"
