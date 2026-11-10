@echo off
REM =====================================================================
REM  Terminus.cmd - Menu del cliente. Solo guia a Terminus.ps1.
REM  Se eleva a Administrador automaticamente si hace falta.
REM =====================================================================

REM fltmc solo funciona como Administrador. (No se usa "net session":
REM falla siempre si el servicio Servidor esta parado, p.ej. en TSplus,
REM y provocaba un bucle infinito de ventanas.)
fltmc >nul 2>&1
if not errorlevel 1 goto admin
REM Si ya venimos de elevar y sigue sin ser admin, no volver a elevar (evita bucle).
if /I "%~1"=="/elevado" (
    echo No se han obtenido permisos de Administrador.
    echo Ejecuta Terminus.cmd con boton derecho - Ejecutar como administrador.
    pause
    exit /b 1
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
