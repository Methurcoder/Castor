@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Castor-Download.ps1"
if errorlevel 1 pause
