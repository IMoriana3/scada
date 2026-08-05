@echo off
REM Arranca el TCU Agente (API de solo lectura para la Toolbox web).
REM Si tienes cloudflared instalado, abre otra ventana con:
REM   cloudflared tunnel --url http://localhost:8585
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0TCU_Agente.ps1"
pause
