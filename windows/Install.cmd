@echo off
rem Starts the Teams Busy Light installer without a console window.
rem No administrator rights are needed. Keep this file next to Install.ps1.
start "" /b powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Install.ps1"
