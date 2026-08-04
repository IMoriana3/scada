@echo off
REM Lanzador de TCU Toolbox. Colocar junto a TCU_Toolbox.ps1.
REM No requiere instalar nada: usa el PowerShell incluido en Windows.
setlocal
set "SCRIPT=%~dp0TCU_Toolbox.ps1"
if not exist "%SCRIPT%" (
  echo ERROR: no se encuentra TCU_Toolbox.ps1 junto a este .bat
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT%"
if errorlevel 1 (
  echo.
  echo La herramienta termino con error %errorlevel%. Revisa el mensaje de arriba
  echo o el log en la carpeta "logs" junto al script.
  pause
)
