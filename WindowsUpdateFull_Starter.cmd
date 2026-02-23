@echo off
:: WindowsUpdateFull_Starter.cmd
:: Startet das WindowsUpdate-Script mit erhöhten Rechten (UAC) als Administrator

:: Prüfen ob bereits als Admin
net session >nul 2>&1
if %errorLevel% == 0 (
    goto :run
) else (
    echo Starte mit Administrator-Rechten...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:run
echo Starte WindowsUpdateFull.ps1 ...
powershell.exe -ExecutionPolicy Bypass -NonInteractive -File "%~dp0WindowsUpdateFull.ps1"
if %errorLevel% neq 0 (
    echo.
    echo [FEHLER] Script wurde mit Fehlercode %errorLevel% beendet.
    pause
)
