@echo off
REM Lanzador del menu de descarga de logs de NCU. Colocar junto a descarga_logs_ncu.ps1.
REM No requiere instalar nada: usa el PowerShell incluido en Windows.
setlocal
set "SCRIPT=%~dp0descarga_logs_ncu.ps1"
if not exist "%SCRIPT%" (
  echo ERROR: no se encuentra descarga_logs_ncu.ps1 junto a este .bat
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
if errorlevel 1 (
  echo.
  echo La descarga termino con error %errorlevel%. Revisa descargas.log en la carpeta logs-ncu.
  pause
)
