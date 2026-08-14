@echo off
rem Lanzador del descargador de logs de las NCU sin tocar politicas de PowerShell.
rem Uso (desde cmd o doble clic editando la linea de abajo):
rem   descarga_logs_ncu.bat -Ip 192.168.4.45 -Ncu 05 -Desde 2026-04-21 -Hasta 2026-08-13
rem   descarga_logs_ncu.bat -Ncus ncus.json
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0descarga_logs_ncu.ps1" %*
pause
