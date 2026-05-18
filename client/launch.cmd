@echo off
rem WorkTime Tracker launcher (double-click to run)
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0WorkTimeTracker.ps1"
if errorlevel 1 pause
