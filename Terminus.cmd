@echo off
REM =====================================================================
REM  Terminus.cmd - Menu del cliente. Solo guia a Terminus.ps1.
REM  Se eleva a Administrador automaticamente si hace falta.
REM =====================================================================

REM Comprobacion de Administrador con PowerShell (la misma que usa Terminus.ps1).
REM "net session" y "fltmc" fallan en algunos servidores (TSplus) aunque se sea admin.
powershell -NoProfile -Command "if(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){exit 0}else{exit 1}"
if not errorlevel 1 goto admin
REM Si ya venimos de elevar, no volver a elevar (evita bucle): se sigue y
REM Terminus.ps1 avisara si de verdad faltan permisos.
if /I "%~1"=="/elevado" (
    echo AVISO: no se detectan permisos de Administrador. Se continua igualmente.
    whoami /groups | findstr /i "S-1-5-32-544 S-1-16-12288"
    pause
    goto admin
)
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '/elevado' -Verb RunAs"
exit /b
:admin

set "PS=PowerShell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Terminus.ps1""

:menu
cls
echo ==================================================
echo   TERMINUS - Acceso de soporte (Azure Arc)
echo ==================================================
echo   [V] Validar (solo lectura, genera informe)
echo   [I] Instalar Terminus
echo       (usa el OpenSSH existente, no toca el sistema anterior)
echo   [M] Instalacion manual de OpenSSH (zip)
echo   [R] Reparar
echo   [Q] Quitar Terminus (deja OpenSSH y el sistema anterior)
echo   [L] Limpieza TOTAL del equipo (todo, OpenSSH incluido)
echo   [C] Monitor de conexiones
echo   [0] Salir
echo ==================================================
set "option="
set /p option=Elige una opcion:

if /I "%option%"=="V" ( %PS% -Modo Validar  & pause & goto menu )
if /I "%option%"=="I" ( %PS% -Modo Instalar & pause & goto menu )
if /I "%option%"=="M" ( %PS% -Modo Manual   & pause & goto menu )
if /I "%option%"=="R" ( %PS% -Modo Reparar  & pause & goto menu )
if /I "%option%"=="Q" ( %PS% -Modo Quitar   & pause & goto menu )
if /I "%option%"=="L" ( %PS% -Modo Limpiar  & pause & goto menu )
if /I "%option%"=="C" ( start "Terminus - Monitor" %PS% -Modo Monitor & goto menu )
if /I "%option%"=="0" exit /b

echo Opcion no valida, intenta de nuevo.
pause
goto menu
