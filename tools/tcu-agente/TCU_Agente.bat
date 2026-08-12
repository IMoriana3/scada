@echo off
REM Arranca el TUNEL y el AGENTE de una vez, en esta misma ventana.
REM La URL del tunel sale en verde, se copia al portapapeles y queda en
REM ultima_url.txt. Al cerrar esta ventana se cierra tambien el tunel.
REM
REM Si no quieres tunel (PC de planta sin acceso remoto), borra o renombra
REM cloudflared.exe de esta carpeta: el agente arranca igual.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Arrancar.ps1"
pause
