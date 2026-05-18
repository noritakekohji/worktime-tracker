@echo off
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0ReportViewer.ps1"
if errorlevel 1 pause
