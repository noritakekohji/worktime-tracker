@echo off
chcp 65001 > nul
powershell.exe -ExecutionPolicy Bypass -File "%~dp0WbsInput.ps1"
if errorlevel 1 pause
