@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0prepare-and-start.ps1" %*
set "TH09AI_EXIT=%ERRORLEVEL%"
if not "%TH09AI_EXIT%"=="0" (
  echo.
  echo Launcher failed with exit code: %TH09AI_EXIT%
  pause
)
exit /b %TH09AI_EXIT%
