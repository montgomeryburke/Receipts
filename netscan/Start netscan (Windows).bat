@echo off
REM Double-click this file to start netscan on Windows.
cd /d "%~dp0"

where node >nul 2>nul
if errorlevel 1 (
  echo.
  echo   Node.js is not installed.
  echo   Install the "LTS" version from https://nodejs.org then try again.
  echo.
  pause
  exit /b 1
)

REM Open the browser on this computer shortly after the server starts.
start "" cmd /c "timeout /t 2 >nul & start http://localhost:8137"

set HOST=0.0.0.0
node server.js

echo.
echo   netscan stopped.
pause
