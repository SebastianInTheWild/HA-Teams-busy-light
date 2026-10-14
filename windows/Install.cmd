@echo off
rem Starts the Teams Busy Light installer as administrator without a console window.
rem Keep this file next to Install.ps1.
start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Start-Process -FilePath powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList '-NoProfile','-STA','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','\"%~dp0Install.ps1\"'"
