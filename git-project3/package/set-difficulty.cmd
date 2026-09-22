@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0set-difficulty.ps1" %*
if errorlevel 1 goto failed
if "%~1"=="" pause
exit /b 0
:failed
pause
exit /b 1
