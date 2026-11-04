@echo off
REM =====================================================================
REM  Terminus.cmd - Menu del cliente. Solo guia a Terminus.ps1.
REM  Se eleva a Administrador automaticamente si hace falta.
REM =====================================================================

net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "PS=PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Terminus.ps1""

:menu
cls
echo ==================================================
echo   TERMINUS - Acceso de soporte (Azure Arc)
echo ==================================================
echo   [V] Validar (solo lectura, genera informe)
echo   [I] Instalar  (OpenSSH + clave + agente Arc)
echo   [M] Instalacion manual de OpenSSH (zip)
echo   [R] Reparar
echo   [E] Eliminar TODO y dejar el equipo limpio
echo   [C] Monitor de conexiones
echo   [0] Salir
echo ==================================================
set "option="
set /p option=Elige una opcion:

if /I "%option%"=="V" ( %PS% -Modo Validar  & pause & goto menu )
if /I "%option%"=="I" ( %PS% -Modo Instalar & pause & goto menu )
if /I "%option%"=="M" ( %PS% -Modo Manual   & pause & goto menu )
if /I "%option%"=="R" ( %PS% -Modo Reparar  & pause & goto menu )
if /I "%option%"=="E" ( %PS% -Modo Eliminar & pause & goto menu )
if /I "%option%"=="C" ( start "Terminus - Monitor" %PS% -Modo Monitor & goto menu )
if /I "%option%"=="0" exit /b

echo Opcion no valida, intenta de nuevo.
pause
goto menu
