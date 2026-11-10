<#
=====================================================================
 Terminus.ps1  -  Acceso remoto de soporte via Azure Arc (cliente)
=====================================================================
 Se lanza desde Terminus.cmd (menu). Uso directo:

   .\Terminus.ps1 -Modo Validar                 (solo lectura, informe a fichero)
   .\Terminus.ps1 -Modo Instalar [-Codigo C001 -Cliente "Gestoria Perez" -Maquina SRV1]
   .\Terminus.ps1 -Modo Manual                  (OpenSSH desde zip, Server 2016 / sin FoD)
   .\Terminus.ps1 -Modo Reparar
   .\Terminus.ps1 -Modo Quitar                  (solo Terminus: deja OpenSSH y el sistema anterior)
   .\Terminus.ps1 -Modo Limpiar                 (limpieza total del equipo, OpenSSH incluido)
   .\Terminus.ps1 -Modo Monitor                 (conexiones en directo)
   .\Terminus.ps1 -Modo Salir                   (borra el secreto del SP si quedo en la config)

 Configuracion:
   Terminus.config.ps1        generica (en el repositorio, igual para todos)
   Terminus.config.local.ps1  opcional, junto al script, NO va al repositorio.
                              Sobrescribe valores de la generica (IDs, usuario,
                              restos del sistema antiguo...).
   Lo que falte se pregunta por pantalla al ejecutar. El secreto del
   Service Principal se pide SIEMPRE y no se guarda nunca.

 Convivencia con un sistema de acceso anterior por SSH:
   - Instalar y Reparar NO tocan nada del entorno antiguo:
       * si OpenSSH ya existe, se usa tal cual (no se reinstala)
       * no se modifican reglas de firewall existentes
       * en administrators_authorized_keys solo se anaden/quitan
         lineas que acaban en " terminus"; el resto se respeta
       * no se tocan los ficheros del sistema anterior (Legado.Ficheros)
   - "Quitar" deshace solo lo de Terminus (agente Arc + clave).
   - "Limpiar" borra todo (anterior y nuevo), previa copia y
     confirmacion escrita.

 Ficheros:
   Log de operaciones : C:\ProgramData\Terminus\terminus.log
   Informe Validar    : junto al script (Terminus_Validacion_<equipo>_<fecha>.txt)
=====================================================================
#>

param(
    [ValidateSet("Validar","Instalar","Manual","Reparar","Quitar","Limpiar","Monitor","Salir")]
    [string]$Modo = "Validar",
    [string]$Codigo,          # codigo de cliente, ej. C001
    [string]$Cliente,         # nombre de cliente, ej. "Gestoria Perez"
    [string]$Maquina,         # nombre corto del equipo, ej. SRV1 (por defecto el hostname)
    [switch]$SinMonitor       # no abrir el monitor al acabar la instalacion
)

$ErrorActionPreference = "Stop"
# Sin barra de progreso: en PowerShell 5.1 hace las descargas (MSI de Arc)
# muchisimo mas lentas.
$ProgressPreference = "SilentlyContinue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

### =================================================================
### BLOQUE 0 - CONFIGURACION Y RUTAS
### =================================================================

$configFile = Join-Path $PSScriptRoot "Terminus.config.ps1"
if (-not (Test-Path $configFile)) {
    Write-Host "No se encuentra Terminus.config.ps1 junto al script." -ForegroundColor Red
    exit 1
}
. $configFile

# Configuracion local (opcional): sobrescribe claves de la generica.
$configLocal = Join-Path $PSScriptRoot "Terminus.config.local.ps1"
if (Test-Path $configLocal) {
    . $configLocal
    if ($TerminusLocal) { foreach ($k in $TerminusLocal.Keys) { $Terminus[$k] = $TerminusLocal[$k] } }
}
if (-not $Terminus.Legado) { $Terminus.Legado = @{} }
foreach ($k in "Ficheros", "IPs") { if (-not $Terminus.Legado[$k]) { $Terminus.Legado[$k] = @() } }

$SID_ADMINS   = "S-1-5-32-544"     # BUILTIN\Administradores (independiente del idioma)
$SID_SYSTEM   = "S-1-5-18"         # NT AUTHORITY\SYSTEM
$MARCA        = "terminus"          # comentario que identifica nuestras lineas de clave

$SshData      = "$env:ProgramData\ssh"
$AdminKeys    = "$SshData\administrators_authorized_keys"
$SshdConfig   = "$SshData\sshd_config"
$DirTerminus  = "$env:ProgramData\Terminus"
$DirTemp      = "$env:TEMP\Terminus"
$AzcmExe      = "$env:ProgramW6432\AzureConnectedMachineAgent\azcmagent.exe"

# Validar es de solo lectura: su log va a un informe junto al script.
if ($Modo -eq "Validar") {
    $stamp   = Get-Date -Format "yyyyMMdd_HHmmss"
    $LogFile = Join-Path $PSScriptRoot "Terminus_Validacion_$($env:COMPUTERNAME)_$stamp.txt"
} else {
    $LogFile = "$DirTerminus\terminus.log"
}

### =================================================================
### BLOQUE 1 - FUNCIONES COMUNES (log, preguntas, entorno)
### =================================================================

# Escribe en pantalla (con color) y en el log (con fecha).
Function EscribeLog {
    param([string]$Mensaje, [string]$Color = "White")
    $t = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    try {
        $dir = Split-Path $script:LogFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        "$t - $Mensaje" | Out-File -Append -FilePath $script:LogFile -Encoding UTF8
    } catch { }
    Write-Host $Mensaje -ForegroundColor $Color
}

# Resultado de una comprobacion: OK / AVISO / ERROR. Lleva la cuenta.
$script:Resumen = @{ OK = 0; AVISO = 0; ERROR = 0 }
Function Resultado {
    param([ValidateSet("OK","AVISO","ERROR","INFO")][string]$Nivel, [string]$Texto)
    $color = @{ OK = "Green"; AVISO = "Yellow"; ERROR = "Red"; INFO = "Gray" }[$Nivel]
    if ($Nivel -ne "INFO") { $script:Resumen[$Nivel]++ }
    EscribeLog ("  [{0,-5}] {1}" -f $Nivel, $Texto) $color
}

Function Titulo { param([string]$Texto) EscribeLog "" ; EscribeLog "== $Texto ==" Cyan }

Function Pregunta {
    param([string]$Texto)
    $r = Read-Host "$Texto (S/N)"
    return ($r -match '^[sSyY]')
}

# Carpeta C:\Terminus solo para Administradores y SYSTEM. Al crearla bajo C:\
# hereda "Usuarios autenticados: modificar": cualquier usuario del servidor
# (p.ej. en un servidor de terminales) podria leer el secreto del SP o
# cambiar los scripts que luego se ejecutan como administrador.
Function Proteger-Carpeta {
    param([string]$Ruta)
    if (-not (Test-Path $Ruta)) { return }
    icacls $Ruta /inheritance:r /grant:r "*${SID_ADMINS}:(OI)(CI)F" "*${SID_SYSTEM}:(OI)(CI)F" /T /C /Q 1>$null 2>$null
    foreach ($r in (Get-Acl $Ruta).Access) {
        try { $sid = $r.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { continue }
        if ($sid -ne $SID_ADMINS -and $sid -ne $SID_SYSTEM) { icacls $Ruta /remove:g "*$sid" /T /C /Q 1>$null 2>$null }
    }
}

Function EsAdministrador {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Version de Windows. Mismo mapa que el script antiguo + puestos de trabajo.
Function Get-InfoSO {
    $os    = Get-CimInstance Win32_OperatingSystem
    $build = [int]($os.BuildNumber)
    $mapa  = @{ 9600 = "Windows Server 2012 R2"; 14393 = "Windows Server 2016"; 17763 = "Windows Server 2019";
                20348 = "Windows Server 2022"; 26100 = "Windows Server 2025" }
    $nombre = if ($os.ProductType -eq 1) { $os.Caption } elseif ($mapa.ContainsKey($build)) { $mapa[$build] } else { $os.Caption }
    [pscustomobject]@{
        Nombre     = $nombre
        Build      = $build
        Servidor   = ($os.ProductType -ne 1)
        Soportado  = ($build -ge 14393)            # 2016 en adelante
        TieneFoD   = ($build -ge 17763)            # OpenSSH como capacidad de Windows
    }
}

# TLS 1.2 para esta sesion (descargas). En 2016/2019 tambien a nivel de
# .NET, igual que hacia el script antiguo (solo si falta).
Function Set-TLS12 {
    param([switch]$Sistema)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (-not $Sistema) { return }
    foreach ($k in "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319","HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319") {
        if (Test-Path $k) {
            $v = (Get-ItemProperty $k -ErrorAction SilentlyContinue).SchUseStrongCrypto
            if ($v -ne 1) {
                Set-ItemProperty -Path $k -Name SchUseStrongCrypto -Value 1 -Type DWord
                EscribeLog "  TLS 1.2 activado para .NET en $k" DarkGray
            }
        }
    }
}

# Nombre de recurso en Azure: sin acentos, espacios ni simbolos. Max 54.
Function Limpia-Nombre {
    param([string]$Texto)
    $n  = $Texto.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $n.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne "NonSpacingMark") { [void]$sb.Append($ch) }
    }
    return ($sb.ToString() -replace '[^A-Za-z0-9_-]', '')
}

# Pide por pantalla los datos que no esten en la configuracion.
# Los IDs no son secretos, pero no se publican en el repositorio.
Function Completar-Datos {
    param([string[]]$Claves)
    $textos = @{
        TenantId       = "Tenant ID de Azure"
        SubscriptionId = "Subscription ID de Azure"
        SpAppId        = "App ID del Service Principal de alta"
        UsuarioLocal   = "Usuario del tunel, ya existente (usuario o DOMINIO\usuario)"
    }
    foreach ($k in $Claves) {
        while (-not $Terminus[$k] -or $Terminus[$k] -match '^0{8}-') {
            if ($k -eq "UsuarioLocal") {
                # Por defecto, el usuario de esta sesion (ya existe y es admin).
                $def = "$env:USERDOMAIN\$env:USERNAME"
                $v = (Read-Host "$($textos[$k]) [Intro = $def]").Trim()
                if (-not $v) { $v = $def }
            } else { $v = (Read-Host $textos[$k]).Trim() }
            if ($k -ne "UsuarioLocal" -and $v -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
                Write-Host "  Formato no valido (se espera un GUID)." -ForegroundColor Yellow; continue
            }
            $Terminus[$k] = $v
        }
    }
}

### =================================================================
### BLOQUE 2 - DETECCION (todo de solo lectura)
### =================================================================

# Estado de OpenSSH Server: nativo (System32), manual (zip) o ninguno.
Function Get-EstadoOpenSSH {
    $svc = Get-CimInstance Win32_Service -Filter "Name='sshd'" -ErrorAction SilentlyContinue
    $cap = $null
    try { $cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*" -ErrorAction Stop | Select-Object -First 1 } catch { }

    $tipo = "NoInstalado"; $ruta = $null
    if ($svc) {
        $ruta = ($svc.PathName -replace '"', '')
        $tipo = if ($ruta -like "*\System32\OpenSSH\*") { "Nativo" } else { "Manual" }
    }
    [pscustomobject]@{
        Tipo        = $tipo
        Ruta        = $ruta
        Carpeta     = if ($ruta) { Split-Path $ruta } else { $null }
        Estado      = if ($svc) { $svc.State } else { $null }
        Arranque    = if ($svc) { $svc.StartMode } else { $null }
        Capacidad   = if ($cap) { [string]$cap.State } else { "NoDisponible" }
        Version     = if ($ruta -and (Test-Path $ruta)) { (Get-Item $ruta).VersionInfo.FileVersion } else { $null }
    }
}

# OpenSSH manual: la carpeta del programa debe ser legible por Usuarios.
# Por cada conexion sshd lanza un proceso con una cuenta sin privilegios;
# si no puede leer la carpeta, muere tras el intercambio de claves y la
# conexion se corta ("Connection closed ... after KEXINIT").
Function Test-AclCarpetaOpenSSH {
    param($ssh)
    if ($ssh.Tipo -ne "Manual" -or -not (Test-Path $ssh.Carpeta)) { return $true }
    foreach ($r in (Get-Acl $ssh.Carpeta).Access) {
        try { $sid = $r.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { continue }
        if ($sid -eq "S-1-5-32-545" -and $r.AccessControlType -eq "Allow" -and
            ($r.FileSystemRights -band [Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq [Security.AccessControl.FileSystemRights]::ReadAndExecute) {
            return $true
        }
    }
    return $false
}

# Devuelve la carpeta del programa a los permisos heredados (los de
# Program Files). Ahi no hay nada secreto: las claves estan en ProgramData.
Function Reparar-AclCarpetaOpenSSH {
    param($ssh)
    if (Test-AclCarpetaOpenSSH $ssh) { return $false }
    icacls $ssh.Carpeta /reset /T /C /Q 1>$null
    EscribeLog "  Permisos de $($ssh.Carpeta) restablecidos (Usuarios con lectura)." Green
    return $true
}

# Estado del agente Arc (azcmagent show en JSON).
Function Get-EstadoArc {
    $ErrorActionPreference = "Continue"
    if (-not (Test-Path $AzcmExe)) { return [pscustomobject]@{ Instalado = $false } }
    $info = $null
    try { $info = (& $AzcmExe show -j 2>$null | Out-String) | ConvertFrom-Json } catch { }
    [pscustomobject]@{
        Instalado = $true
        Estado    = if ($info) { $info.status } else { "Desconocido" }
        Nombre    = if ($info) { $info.resourceName } else { $null }
        Grupo     = if ($info) { $info.resourceGroup } else { $null }
        Version   = if ($info) { $info.agentVersion } else { $null }
    }
}

Function Get-ConfigArc {
    param([string]$Clave)
    $ErrorActionPreference = "Continue"
    try { return ((& $AzcmExe config get $Clave 2>$null) | Out-String).Trim() } catch { return "" }
}

# Lineas de administrators_authorized_keys separadas en nuestras / ajenas.
Function Get-LineasClaves {
    $todas = @()
    if (Test-Path $AdminKeys) { $todas = @(Get-Content $AdminKeys | Where-Object { $_.Trim() -ne "" }) }
    [pscustomobject]@{
        Terminus = @($todas | Where-Object { $_.TrimEnd() -match "\s$MARCA$" })
        Otras    = @($todas | Where-Object { $_.TrimEnd() -notmatch "\s$MARCA$" })
    }
}

# Linea de clave tal como debe quedar segun la configuracion.
Function Get-LineaClaveEsperada {
    $op = @()
    if ($Terminus.RestringirLocal) { $op += 'from="127.0.0.1,::1"' }
    if ($Terminus.OpcionesClave)   { $op += $Terminus.OpcionesClave }
    $k = $Terminus.ClavePublica.Trim()
    if ($op) { $k = ($op -join ",") + " " + $k }
    return $k
}

# Permisos correctos para ficheros que lee sshd: solo SYSTEM y Administradores,
# sin herencia. Devuelve la lista de problemas (vacia = correcto).
Function Test-AclSsh {
    param([string]$Fichero)
    $problemas = @()
    if (-not (Test-Path $Fichero)) { return @("no existe") }
    $acl = Get-Acl $Fichero
    if (-not $acl.AreAccessRulesProtected) { $problemas += "hereda permisos" }
    foreach ($r in $acl.Access) {
        try { $sid = $r.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { $sid = "$($r.IdentityReference)" }
        if ($sid -ne $SID_ADMINS -and $sid -ne $SID_SYSTEM) { $problemas += "acceso para $($r.IdentityReference)" }
    }
    return $problemas
}

# Salida HTTPS (443) hacia los servicios de Microsoft que usa Arc.
# Cualquier respuesta HTTP (aunque sea 4xx) indica que se llega bien.
$HostsArc = @(
    "login.microsoftonline.com", "login.windows.net", "pas.windows.net",
    "management.azure.com", "gbl.his.arc.azure.com",
    "agentserviceapi.guestconfiguration.azure.com",
    "guestnotificationservice.azure.com",
    "aka.ms", "download.microsoft.com"
)
Function Test-Salida443 {
    param([string]$HostName)
    try { [void][Net.Dns]::GetHostAddresses($HostName) } catch { return "DNS" }
    try {
        Invoke-WebRequest -Uri "https://$HostName/" -Method Head -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop | Out-Null
        return "OK"
    } catch {
        if ($_.Exception.Response) { return "OK" }      # respondio con 3xx/4xx: hay salida
        return "BLOQUEADO"
    }
}

# Ficheros del sistema anterior en los perfiles de usuario (patrones en
# Legado.Ficheros, relativos a C:\Users\<usuario>, ej. ".ssh\xxx_rsa*").
Function Get-FicherosLegado {
    foreach ($p in $Terminus.Legado.Ficheros) {
        Get-ChildItem "$env:SystemDrive\Users\*\$p" -Force -ErrorAction SilentlyContinue
    }
}

# Entorno antiguo presente? (solo informativo)
Function Get-EntornoAntiguo {
    $claves = (Get-LineasClaves).Otras.Count
    $regla  = if ($Terminus.Legado.ReglaFirewall) { Get-NetFirewallRule -Name $Terminus.Legado.ReglaFirewall -ErrorAction SilentlyContinue } else { $null }
    $rsa    = @(Get-FicherosLegado)
    [pscustomobject]@{
        Presente   = ($claves -gt 0 -or $regla -or $rsa.Count -gt 0)
        Claves     = $claves
        ReglaSshd  = [bool]$regla
        FicherosRsa = $rsa.Count
    }
}

### =================================================================
### BLOQUE 3 - ACCIONES
### =================================================================

# Deja un fichero con permisos SYSTEM + Administradores (propietario Administradores).
Function Set-AclSsh {
    param([string]$Fichero)
    icacls $Fichero /setowner "*$SID_ADMINS" 1>$null
    icacls $Fichero /inheritance:r 1>$null
    icacls $Fichero /grant:r "*${SID_ADMINS}:F" "*${SID_SYSTEM}:F" 1>$null
    foreach ($r in (Get-Acl $Fichero).Access) {
        try { $sid = $r.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { continue }
        if ($sid -ne $SID_ADMINS -and $sid -ne $SID_SYSTEM) { icacls $Fichero /remove:g "*$sid" 1>$null }
    }
}

# OpenSSH nativo (Windows 2019 en adelante / Windows 10 1809+).
Function Instalar-OpenSSHNativo {
    $cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*" | Select-Object -First 1
    if ($cap.State -ne "Installed") {
        EscribeLog "  Activando la capacidad $($cap.Name) (puede tardar unos minutos)..." Yellow
        Add-WindowsCapability -Online -Name $cap.Name | Out-Null
    }
    Set-Service sshd -StartupType Automatic
    Start-Service sshd
}

# OpenSSH desde el zip de Win32-OpenSSH (Server 2016 o sin acceso a FoD).
Function Instalar-OpenSSHManual {
    $destino = "$env:ProgramFiles\OpenSSH"
    $zip     = "$DirTemp\OpenSSH-Win64.zip"
    New-Item -ItemType Directory -Path $DirTemp -Force | Out-Null

    EscribeLog "  Descargando $($Terminus.OpenSSHZipUrl)" Yellow
    Invoke-WebRequest -Uri $Terminus.OpenSSHZipUrl -OutFile $zip -UseBasicParsing

    if ($Terminus.OpenSSHZipSha256) {
        $h = (Get-FileHash $zip -Algorithm SHA256).Hash
        if ($h -ne $Terminus.OpenSSHZipSha256.ToUpper()) { throw "El hash del zip no coincide ($h). Instalacion cancelada." }
        EscribeLog "  Hash SHA256 verificado." Green
    }

    Expand-Archive -Path $zip -DestinationPath $DirTemp -Force
    if (Test-Path $destino) { Remove-Item $destino -Recurse -Force }
    Move-Item "$DirTemp\OpenSSH-Win64" $destino
    & powershell -NoProfile -ExecutionPolicy Bypass -File "$destino\install-sshd.ps1" | Out-Null

    # PATH de sistema (para ssh-keygen, etc.)
    $path = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ($path -notlike "*$destino*") { [Environment]::SetEnvironmentVariable("Path", "$path;$destino", "Machine") }

    Set-Service sshd -StartupType Automatic
    Start-Service sshd
    EscribeLog "  OpenSSH instalado en $destino" Green
}

# Es miembro de Administradores? (ADSI: evita el fallo de Get-LocalGroupMember
# con SIDs huerfanos). Nombre del grupo segun idioma, a partir del SID.
Function Test-UsuarioAdmin {
    param([string]$Nombre)
    $grupo = (New-Object Security.Principal.SecurityIdentifier $SID_ADMINS).Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
    $miembros = @(([ADSI]"WinNT://$env:COMPUTERNAME/$grupo,group").Invoke("Members") |
                  ForEach-Object { $_.GetType().InvokeMember("Name", "GetProperty", $null, $_, $null) })
    return ($miembros -contains $Nombre)
}

# Tipo de usuario del tunel segun como se escriba en UsuarioLocal:
#   "usuario" o "EQUIPO\usuario"  -> local
#   "DOMINIO\usuario"             -> de dominio (no se crea ni se modifica)
Function Get-UsuarioTunel {
    $n = $Terminus.UsuarioLocal
    $partes = $n.Split('\')
    $dominio = if ($partes.Count -gt 1) { $partes[0] } else { "" }
    $esDominio = $dominio -and $dominio -ne "." -and $dominio -ne $env:COMPUTERNAME
    return [pscustomobject]@{
        Completo  = $n
        Corto     = $partes[-1]
        Dominio   = $esDominio
        EsSesion  = ($n -ieq "$env:USERDOMAIN\$env:USERNAME") -or
                    (-not $esDominio -and $env:USERDOMAIN -eq $env:COMPUTERNAME -and $partes[-1] -ieq $env:USERNAME)
        # Como lo usa ssh: local = nombre corto; dominio = usuario@DOMINIO
        # (sin "\": azcmagent se lo come al guardar la etiqueta)
        ParaSsh   = if ($esDominio) { "$($partes[-1])@$dominio" } else { $partes[-1] }
    }
}

# Usuario del tunel. Se usa uno que YA EXISTA en el equipo del cliente
# (local o de dominio). Solo se crea un usuario local si se confirma.
# Tiene que ser administrador (administrators_authorized_keys).
Function Asegurar-Usuario {
    $t = Get-UsuarioTunel

    # --- Usuario de dominio: no se toca -------------------------
    if ($t.Dominio) {
        if ($t.EsSesion) {
            if (-not (EsAdministrador)) { throw "El usuario '$($t.Completo)' no es administrador de este equipo." }
            EscribeLog "  Usuario de dominio '$($t.Completo)' (el de esta sesion): administrador. No se modifica." Green
        } else {
            EscribeLog "  Usuario de dominio '$($t.Completo)': no se modifica." DarkGray
            EscribeLog "  AVISO: no se puede comprobar desde aqui que sea administrador del equipo; debe serlo." Yellow
        }
        return
    }

    # --- Usuario local -------------------------------------------
    $nombre = $t.Corto
    $u = Get-LocalUser -Name $nombre -ErrorAction SilentlyContinue
    if (-not $u) {
        if (-not (Pregunta "El usuario local '$nombre' no existe. Crearlo (contrasena aleatoria, solo acceso por clave)?")) {
            throw "Indica en UsuarioLocal un usuario que ya exista (local o DOMINIO\usuario)."
        }
        # Contrasena aleatoria larga que no se guarda: el acceso es por clave.
        $set = [char[]]"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!#%+-_=?"
        $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
        $b = New-Object byte[] 32; $rng.GetBytes($b)
        $pw = -join ($b | ForEach-Object { $set[$_ % $set.Length] })
        $pw = "Aa1!" + $pw                                  # garantiza complejidad
        $sec = ConvertTo-SecureString $pw -AsPlainText -Force
        New-LocalUser -Name $nombre -Password $sec -PasswordNeverExpires -AccountNeverExpires `
            -Description "Terminus - acceso de soporte via Azure Arc" | Out-Null
        $pw = $null
        EscribeLog "  Usuario local '$nombre' creado (contrasena aleatoria, acceso solo por clave)." Green
    } else {
        EscribeLog "  Usuario local '$nombre' ya existe: no se modifica." DarkGray
        if (-not $u.Enabled) { EscribeLog "  AVISO: el usuario '$nombre' esta deshabilitado." Yellow }
    }
    if (-not (Test-UsuarioAdmin $nombre)) {
        if ($u -and -not (Pregunta "'$nombre' no es administrador. Anadirlo al grupo Administradores?")) {
            throw "El usuario del tunel tiene que ser administrador."
        }
        Add-LocalGroupMember -SID $SID_ADMINS -Member $nombre
        EscribeLog "  '$nombre' anadido al grupo Administradores." Green
    }
}

# Anade (o actualiza) nuestra linea de clave. Las demas lineas no se tocan.
# authorized_keys del PERFIL del usuario del tunel. Hace falta ademas del de
# administradores porque en OpenSSH antiguos (8.1) con Windows en espanol el
# bloque "Match Group administrators" no aplica (el grupo es "Administradores")
# y sshd solo mira el fichero del usuario. Devuelve $null si no hay perfil.
Function Get-ClavesUsuarioPath {
    try {
        $t   = Get-UsuarioTunel
        $nom = if ($t.Dominio) { $t.Completo } else { $t.Corto }
        $sid = (New-Object Security.Principal.NTAccount $nom).Translate([Security.Principal.SecurityIdentifier]).Value
        $pf  = Get-CimInstance Win32_UserProfile -Filter "SID='$sid'" -ErrorAction SilentlyContinue
        if ($pf -and $pf.LocalPath) { return [pscustomobject]@{ Fichero = "$($pf.LocalPath)\.ssh\authorized_keys"; Sid = $sid } }
    } catch { }
    return $null
}

# Pone (o quita con -Quitar) nuestra linea en el authorized_keys del perfil.
# Las demas lineas (sistema anterior) no se tocan.
Function Set-ClaveUsuario {
    param([switch]$Quitar)
    $u = Get-ClavesUsuarioPath
    if (-not $u) { EscribeLog "  Usuario sin perfil en este equipo: solo administrators_authorized_keys." DarkGray; return }
    $existe = Test-Path $u.Fichero
    $todas  = if ($existe) { @(Get-Content $u.Fichero | Where-Object { $_.Trim() -ne "" }) } else { @() }
    $otras  = @($todas | Where-Object { $_.TrimEnd() -notmatch "\s$MARCA$" })
    $mias   = @($todas | Where-Object { $_.TrimEnd() -match "\s$MARCA$" })
    $esperada = Get-LineaClaveEsperada

    if ($Quitar) {
        if (-not $mias) { return }
        $nuevo = $otras
    } else {
        if ($mias.Count -eq 1 -and $mias[0].Trim() -eq $esperada) { EscribeLog "  Clave Terminus ya presente en $($u.Fichero)." DarkGray; return }
        $nuevo = @($otras) + $esperada
    }
    if ($existe) { Copy-Item $u.Fichero "$($u.Fichero).terminus_$(Get-Date -Format yyyyMMddHHmmss).bak" -Force }
    else { New-Item -ItemType Directory -Path (Split-Path $u.Fichero) -Force | Out-Null }
    [IO.File]::WriteAllText($u.Fichero, (($nuevo -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
    if (-not $existe) {
        # Fichero nuevo: solo el usuario, SYSTEM y Administradores (sshd lo exige)
        icacls $u.Fichero /inheritance:r 1>$null
        icacls $u.Fichero /grant:r "*$($u.Sid):F" "*${SID_ADMINS}:F" "*${SID_SYSTEM}:F" 1>$null
    }
    if ($Quitar) { EscribeLog "  Clave Terminus quitada de $($u.Fichero)." Green }
    else         { EscribeLog "  Clave Terminus en $($u.Fichero) ($($otras.Count) lineas ajenas conservadas)." Green }
}

Function Asegurar-Clave {
    if ($Terminus.ClavePublica -match "PEGAR_AQUI") { throw "Falta la clave publica en Terminus.config.ps1." }
    if (-not (Test-Path $SshData)) { New-Item -ItemType Directory -Path $SshData -Force | Out-Null }

    $esperada = Get-LineaClaveEsperada
    $lineas   = Get-LineasClaves
    if ($lineas.Terminus.Count -eq 1 -and $lineas.Terminus[0].Trim() -eq $esperada) {
        EscribeLog "  Clave Terminus ya presente." DarkGray
    } else {
        if (Test-Path $AdminKeys) {
            Copy-Item $AdminKeys "$AdminKeys.terminus_$(Get-Date -Format yyyyMMddHHmmss).bak" -Force
        }
        $nuevo = @($lineas.Otras) + $esperada
        # UTF-8 sin BOM y saltos LF: es lo que espera sshd.
        [IO.File]::WriteAllText($AdminKeys, (($nuevo -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
        EscribeLog "  Clave Terminus escrita ($($lineas.Otras.Count) lineas antiguas conservadas)." Green
    }
    Set-AclSsh $AdminKeys
    EscribeLog "  Permisos de administrators_authorized_keys: SYSTEM + Administradores." Green
    Set-ClaveUsuario
}

# Agente Arc: instalar MSI (firma verificada) y aplicar configuracion minima.
Function Instalar-AgenteArc {
    if (-not (Test-Path $AzcmExe)) {
        New-Item -ItemType Directory -Path $DirTemp -Force | Out-Null
        $msi = "$DirTemp\AzureConnectedMachineAgent.msi"
        EscribeLog "  Descargando agente Azure Arc..." Yellow
        Invoke-WebRequest -Uri $Terminus.ArcMsiUrl -OutFile $msi -UseBasicParsing

        $firma = Get-AuthenticodeSignature $msi
        if ($firma.Status -ne "Valid" -or $firma.SignerCertificate.Subject -notmatch "O=Microsoft Corporation") {
            throw "La firma del MSI no es valida de Microsoft ($($firma.Status)). Instalacion cancelada."
        }
        EscribeLog "  Firma del MSI verificada (Microsoft)." Green

        $p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList "/i `"$msi`" /qn /l*v `"$DirTerminus\arc_msi.log`""
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "msiexec devolvio $($p.ExitCode). Ver $DirTerminus\arc_msi.log" }
        EscribeLog "  Agente Azure Arc instalado." Green
    } else {
        EscribeLog "  Agente Azure Arc ya instalado." DarkGray
    }
    Configurar-AgenteArc
}

# Configuracion "solo acceso": SSH por el puerto 22, sin extensiones ni
# politicas de invitado (evita costes y cambios no deseados en el cliente).
Function Configurar-AgenteArc {
    $ErrorActionPreference = "Continue"
    & $AzcmExe config set incomingconnections.ports 22         | Out-Null
    & $AzcmExe config set extensions.enabled false             | Out-Null
    & $AzcmExe config set guestconfiguration.enabled false     | Out-Null
    EscribeLog "  Agente configurado: puerto 22, extensiones OFF, guest configuration OFF." Green
}

# Borra el secreto del SP de todo lo que pueda quedar en disco:
#  - la linea SpSecret de Terminus.config.local.ps1 (si se puso alli)
#  - las lineas del historial de PowerShell que lo contengan (al pegar
#    la configuracion en la consola, PSReadLine la guarda en un fichero)
# Se ejecuta siempre tras el alta, haya ido bien o mal.
Function Borrar-Secreto {
    param([string]$Valor)
    if (-not $Valor) { return }
    $local = Join-Path $PSScriptRoot "Terminus.config.local.ps1"
    if (Test-Path $local) {
        $lineas = Get-Content $local
        if ($lineas -match '^\s*SpSecret\s*=') {
            $lineas | Where-Object { $_ -notmatch '^\s*SpSecret\s*=' } | Set-Content $local -Encoding ASCII
            EscribeLog "  Secreto eliminado de Terminus.config.local.ps1" Green
        }
    }
    $hist = "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
    if (Test-Path $hist) {
        $h = Get-Content $hist
        # Tambien la linea de instalacion ($TerminusBloque='<base64>'): lleva el
        # secreto codificado, no en claro.
        $resto = @($h | Where-Object { -not ($_.Contains($Valor) -or $_ -match 'TerminusBloque') })
        if ($resto.Count -ne @($h).Count) {
            $resto | Set-Content $hist -Encoding UTF8
            EscribeLog "  Secreto eliminado del historial de PowerShell" Green
        }
    }
}

# Alta del equipo en Azure con nombre y etiquetas.
Function Conectar-AgenteArc {
    param([string]$NombreRecurso, [Collections.IDictionary]$Etiquetas)
    $ErrorActionPreference = "Continue"     # azcmagent escribe en stderr

    $estado = Get-EstadoArc
    if ($estado.Estado -eq "Connected") {
        EscribeLog "  Ya conectado a Azure como '$($estado.Nombre)'." DarkGray
        if ($estado.Nombre -ne $NombreRecurso) {
            EscribeLog "  AVISO: el nombre pedido es '$NombreRecurso'. Para renombrar: opcion [Q] Quitar y volver a instalar." Yellow
        }
        return
    }

    $secreto = $Terminus.SpSecret
    if ($secreto) { EscribeLog "  Secreto tomado de la configuracion local (se borrara al terminar)." DarkGray }
    else {
        $s = Read-Host "Secreto del Service Principal de alta (no se guarda)" -AsSecureString
        $secreto = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
    }
    $tags = ($Etiquetas.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ","

    EscribeLog "  Conectando a Azure como '$NombreRecurso'..." Yellow
    & $AzcmExe connect `
        --service-principal-id     $Terminus.SpAppId `
        --service-principal-secret $secreto `
        --tenant-id                $Terminus.TenantId `
        --subscription-id          $Terminus.SubscriptionId `
        --resource-group           $Terminus.ResourceGroup `
        --location                 $Terminus.Location `
        --resource-name            $NombreRecurso `
        --tags                     $tags `
        --cloud AzureCloud 2>&1 | Out-File -Append "$DirTerminus\arc_connect.log" -Encoding UTF8
    $codigo = $LASTEXITCODE
    Borrar-Secreto $secreto
    $secreto = $null
    if ($codigo -ne 0) { throw "azcmagent connect fallo (codigo $codigo). Ver $DirTerminus\arc_connect.log" }
    EscribeLog "  Equipo dado de alta en Azure: $NombreRecurso" Green
}

### =================================================================
### BLOQUE 4 - MODOS
### =================================================================

# ---------------------------------------------------------------
# VALIDAR - solo lectura. No cambia nada en el equipo.
# ---------------------------------------------------------------
Function Modo-Validar {
    $ErrorActionPreference = "Continue"      # solo lectura: seguir aunque algo falle
    Completar-Datos "UsuarioLocal"
    $so = Get-InfoSO
    EscribeLog "TERMINUS - VALIDACION (solo lectura)  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" Cyan
    EscribeLog "Equipo: $env:COMPUTERNAME   Ejecutado por: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)" DarkGray

    Titulo "Sistema operativo"
    if ($so.Soportado) { Resultado OK "$($so.Nombre) (build $($so.Build))" }
    else               { Resultado ERROR "$($so.Nombre) (build $($so.Build)) fuera de alcance (minimo Server 2016)" }
    if (-not $so.Servidor) { Resultado AVISO "Es un puesto de trabajo, no un servidor" }
    if ($PSVersionTable.PSVersion.Major -ge 5) { Resultado OK "PowerShell $($PSVersionTable.PSVersion)" }
    else { Resultado ERROR "PowerShell $($PSVersionTable.PSVersion) (se necesita 5.1)" }

    Titulo "OpenSSH Server"
    $ssh = Get-EstadoOpenSSH
    switch ($ssh.Tipo) {
        "NoInstalado" { Resultado AVISO "No instalado (capacidad de Windows: $($ssh.Capacidad))" }
        default       {
            Resultado OK "$($ssh.Tipo) - $($ssh.Ruta) (version $($ssh.Version))"
            # Versiones antiguas (p.ej. 8.1) con Windows en espanol no aplican
            # "Match Group administrators": la clave va tambien al perfil del usuario.
            if ($ssh.Version -and [version]($ssh.Version -replace '[^0-9.]', '') -lt [version]"8.9") {
                Resultado INFO "OpenSSH antiguo: la clave Terminus se pondra tambien en el authorized_keys del usuario"
            }
        }
    }
    if ($ssh.Tipo -ne "NoInstalado") {
        if ($ssh.Estado -eq "Running") { Resultado OK "Servicio sshd en ejecucion" } else { Resultado ERROR "Servicio sshd: $($ssh.Estado)" }
        if ($ssh.Arranque -eq "Auto")  { Resultado OK "Arranque automatico" }     else { Resultado AVISO "Arranque: $($ssh.Arranque)" }
        if ($ssh.Tipo -eq "Manual") {
            if (Test-AclCarpetaOpenSSH $ssh) { Resultado OK "Permisos de $($ssh.Carpeta) correctos" }
            else { Resultado ERROR "$($ssh.Carpeta) sin lectura para Usuarios: las conexiones se cortan (lo corrigen [I] y [R])" }
        }
        $escucha = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue
        if ($escucha) { Resultado OK "Escuchando en 22 ($((($escucha.LocalAddress) | Select-Object -Unique) -join ', '))" }
        else          { Resultado ERROR "Nada escucha en el puerto 22" }
    }

    if (Test-Path $SshdConfig) {
        $cfg = Get-Content $SshdConfig
        if ($cfg -match '^\s*PubkeyAuthentication\s+no')        { Resultado ERROR "sshd_config: PubkeyAuthentication no" }
        if ($cfg -match '^\s*AllowTcpForwarding\s+no')          { Resultado ERROR "sshd_config: AllowTcpForwarding no (el tunel RDP no funcionaria)" }
        if ($cfg -match '^\s*Match\s+Group\s+administrators')   { Resultado OK "sshd_config: bloque 'Match Group administrators' presente" }
        else                                                    { Resultado AVISO "sshd_config: falta 'Match Group administrators'" }
    }

    Titulo "Usuario y claves"
    $t = Get-UsuarioTunel
    $u = if ($t.Dominio) { $null } else { Get-LocalUser -Name $t.Corto -ErrorAction SilentlyContinue }
    if ($t.Dominio) {
        if ($t.EsSesion) { Resultado $(if (EsAdministrador) { "OK" } else { "ERROR" }) "Usuario de dominio '$($t.Completo)' (esta sesion), administrador: $(EsAdministrador)" }
        else             { Resultado INFO "Usuario de dominio '$($t.Completo)': comprobar que es administrador del equipo" }
    } elseif ($u) {
        $esAdmin = Test-UsuarioAdmin $t.Corto
        Resultado $(if ($u.Enabled) { "OK" } else { "ERROR" }) "Usuario '$($u.Name)' $(if ($u.Enabled) {'habilitado'} else {'DESHABILITADO'})"
        Resultado $(if ($esAdmin) { "OK" } else { "AVISO" }) "Administrador: $([bool]$esAdmin)"
    } else { Resultado AVISO "Usuario local '$($t.Corto)' no existe (al instalar se pregunta si crearlo; mejor usar uno existente)" }

    $lin = Get-LineasClaves
    if (Test-Path $AdminKeys) {
        Resultado INFO "administrators_authorized_keys: $($lin.Otras.Count) clave(s) ajenas, $($lin.Terminus.Count) de Terminus"
        if ($lin.Terminus.Count -eq 1 -and $lin.Terminus[0].Trim() -eq (Get-LineaClaveEsperada)) { Resultado OK "Clave Terminus correcta" }
        elseif ($lin.Terminus.Count -eq 0) { Resultado AVISO "Clave Terminus no presente" }
        else { Resultado AVISO "Clave Terminus distinta de la configurada o duplicada" }
        $cu = Get-ClavesUsuarioPath
        if ($cu -and (Test-Path $cu.Fichero)) {
            $hay = @(Get-Content $cu.Fichero | Where-Object { $_.TrimEnd() -match "\s$MARCA$" }).Count
            Resultado INFO "authorized_keys del usuario ($($cu.Fichero)): clave Terminus $(if ($hay) {'presente'} else {'no presente'})"
        }
        $p = Test-AclSsh $AdminKeys
        if ($p.Count -eq 0) { Resultado OK "Permisos de administrators_authorized_keys correctos" }
        else { Resultado ERROR "Permisos incorrectos: $($p -join '; ')" }
    } else { Resultado AVISO "No existe administrators_authorized_keys" }

    Titulo "Agente Azure Arc"
    $arc = Get-EstadoArc
    if (-not $arc.Instalado) { Resultado AVISO "No instalado" }
    else {
        Resultado $(if ($arc.Estado -eq "Connected") { "OK" } else { "ERROR" }) "Estado: $($arc.Estado)  Recurso: $($arc.Nombre)  Version: $($arc.Version)"
        $puertos = Get-ConfigArc "incomingconnections.ports"
        Resultado $(if ($puertos -match '\b22\b') { "OK" } else { "ERROR" }) "incomingconnections.ports: $puertos"
        $ext = Get-ConfigArc "extensions.enabled"
        Resultado $(if ($ext -match 'false') { "OK" } else { "AVISO" }) "extensions.enabled: $ext"
        $gc  = Get-ConfigArc "guestconfiguration.enabled"
        Resultado $(if ($gc -match 'false') { "OK" } else { "AVISO" }) "guestconfiguration.enabled: $gc (si esta activo puede tener coste)"
        foreach ($s in "himds","arcproxy","GCArcService","ExtensionService") {
            $svc = Get-Service $s -ErrorAction SilentlyContinue
            if ($svc) { Resultado INFO "Servicio $s : $($svc.Status)" }
        }
    }

    Titulo "Salida a Microsoft por 443"
    $proxy = (netsh winhttp show proxy) -join " "
    if ($proxy -match "Direct access|Acceso directo|directo") { Resultado INFO "Proxy WinHTTP: acceso directo" }
    else { Resultado AVISO "Hay proxy WinHTTP configurado: el agente Arc necesitara 'azcmagent config set proxy.url'" }
    Set-TLS12
    foreach ($h in $HostsArc) {
        $r = Test-Salida443 $h
        switch ($r) {
            "OK"        { Resultado OK    "$h" }
            "DNS"       { Resultado ERROR "$h - no se resuelve (DNS)" }
            default     { Resultado ERROR "$h - sin respuesta por 443 (firewall/proxy)" }
        }
    }
    Resultado INFO "El relay SSH usa *.servicebus.windows.net (comodin, no se puede probar directamente)"
    if ($arc.Instalado) {
        EscribeLog "  Comprobacion oficial del agente (azcmagent check):" DarkGray
        (& $AzcmExe check --location $Terminus.Location 2>&1 | Out-String) -split "`n" |
            Where-Object { $_.Trim() } | ForEach-Object { EscribeLog "    $_" Gray }
    }

    Titulo "Entorno antiguo (informativo, no se modifica)"
    $old = Get-EntornoAntiguo
    if ($old.Presente) {
        Resultado INFO "Detectado: $($old.Claves) clave(s) ajenas, regla firewall anterior: $($old.ReglaSshd), ficheros del sistema anterior: $($old.FicherosRsa)"
    } else { Resultado INFO "No se detecta entorno antiguo" }

    Titulo "Resumen"
    EscribeLog ("  OK: {0}   AVISOS: {1}   ERRORES: {2}" -f $Resumen.OK, $Resumen.AVISO, $Resumen.ERROR) $(if ($Resumen.ERROR) { "Red" } elseif ($Resumen.AVISO) { "Yellow" } else { "Green" })
    EscribeLog "  Informe guardado en: $LogFile" DarkGray
}

# ---------------------------------------------------------------
# INSTALAR - OpenSSH (si falta) + usuario + clave + agente Arc
# ---------------------------------------------------------------
Function Modo-Instalar {
    $so = Get-InfoSO
    EscribeLog "TERMINUS - INSTALACION  ($($so.Nombre), build $($so.Build))" Cyan
    if (-not $so.Soportado) { throw "Sistema no soportado. Minimo Windows Server 2016." }
    Completar-Datos "TenantId", "SubscriptionId", "SpAppId", "UsuarioLocal"

    # --- 1. Datos del cliente -----------------------------------
    if (-not $Codigo)  { $script:Codigo  = Read-Host "Codigo de cliente (ej. C001)" }
    if (-not $Cliente) { $script:Cliente = Read-Host "Nombre de cliente (ej. Gestoria Perez)" }
    if (-not $Maquina) {
        $m = Read-Host "Nombre corto del equipo [Intro = $env:COMPUTERNAME]"
        $script:Maquina = if ($m) { $m } else { $env:COMPUTERNAME }
    }
    $nombreRecurso = "{0}-{1}-{2}" -f (Limpia-Nombre $Codigo), (Limpia-Nombre $Cliente), (Limpia-Nombre $Maquina)
    if ($nombreRecurso.Length -gt 54) { $nombreRecurso = $nombreRecurso.Substring(0, 54) }
    $etiquetas = [ordered]@{
        Codigo   = ($Codigo  -replace '[,=]', ' ').Trim()
        Cliente  = ($Cliente -replace '[,=]', ' ').Trim()
        Equipo   = $env:COMPUTERNAME
        Terminus = "v1"
        UsuarioTunel = (Get-UsuarioTunel).ParaSsh  # lo lee Tunnel-Open del operador
    }
    EscribeLog ""
    EscribeLog "  Nombre en Azure : $nombreRecurso" White
    EscribeLog "  Etiquetas       : $(($etiquetas.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')" White
    if (-not (Pregunta "Continuar con la instalacion?")) { EscribeLog "Cancelado." Yellow; return }

    # --- 2. Requisitos de red ------------------------------------
    Titulo "1/5 Salida a Microsoft (443)"
    Set-TLS12 -Sistema:($so.Build -le 17763)
    $fallos = @($HostsArc | Where-Object { (Test-Salida443 $_) -ne "OK" })
    if ($fallos) { throw "Sin salida 443 hacia: $($fallos -join ', '). Revisar firewall/proxy del cliente (ver opcion V)." }
    EscribeLog "  Salida correcta hacia los $($HostsArc.Count) servicios." Green

    # --- 3. OpenSSH ----------------------------------------------
    Titulo "2/5 OpenSSH Server"
    $old = Get-EntornoAntiguo      # se mira ANTES de anadir nuestra clave
    $ssh = Get-EstadoOpenSSH
    $instaladoAhora = $false
    if ($ssh.Tipo -ne "NoInstalado") {
        EscribeLog "  OpenSSH $($ssh.Tipo) ya presente ($($ssh.Ruta)): se usa tal cual." DarkGray
        [void](Reparar-AclCarpetaOpenSSH $ssh)
        if ($ssh.Estado -ne "Running") { Set-Service sshd -StartupType Automatic; Start-Service sshd; EscribeLog "  Servicio sshd arrancado." Green }
    } elseif ($so.TieneFoD) {
        try { Instalar-OpenSSHNativo; $instaladoAhora = $true }
        catch {
            EscribeLog "  No se pudo activar OpenSSH nativo: $($_.Exception.Message)" Red
            if (Pregunta "Instalar OpenSSH desde zip (manual)?") { Instalar-OpenSSHManual; $instaladoAhora = $true } else { throw "OpenSSH no instalado." }
        }
    } else {
        EscribeLog "  $($so.Nombre) no incluye OpenSSH: se instala desde zip." Yellow
        Instalar-OpenSSHManual; $instaladoAhora = $true
    }

    # Arc entra por 127.0.0.1: en un cliente nuevo (sin sistema antiguo) no
    # hace falta el puerto 22 abierto desde fuera. Con sistema antiguo no se toca.
    if ($instaladoAhora -or -not $old.Presente) {
        $regla = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
        if ($regla -and $regla.Enabled -eq "True") {
            Disable-NetFirewallRule -Name "OpenSSH-Server-In-TCP"
            EscribeLog "  Regla de firewall OpenSSH-Server-In-TCP desactivada (Arc no necesita entrada)." Green
        }
    }

    # --- 4. Usuario y clave -------------------------------------
    Titulo "3/5 Usuario y clave"
    Asegurar-Usuario
    Asegurar-Clave
    Restart-Service sshd
    EscribeLog "  sshd reiniciado." DarkGray

    # --- 5. Agente Arc -------------------------------------------
    Titulo "4/5 Agente Azure Arc"
    Instalar-AgenteArc
    Conectar-AgenteArc -NombreRecurso $nombreRecurso -Etiquetas $etiquetas

    # --- 6. Comprobacion final ----------------------------------
    Titulo "5/5 Comprobacion"
    $arc = Get-EstadoArc
    $ssh = Get-EstadoOpenSSH
    EscribeLog "  sshd      : $($ssh.Estado)" $(if ($ssh.Estado -eq "Running") { "Green" } else { "Red" })
    EscribeLog "  Azure Arc : $($arc.Estado)  ($($arc.Nombre))" $(if ($arc.Estado -eq "Connected") { "Green" } else { "Red" })
    EscribeLog ""
    EscribeLog "  Pendiente (administrador Azure): Habilitar-Acceso.ps1 -Maquina $($arc.Nombre)" Yellow
    EscribeLog "  Log: $LogFile" DarkGray

    if (-not $SinMonitor) {
        Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Modo Monitor"
        EscribeLog "  Monitor de conexiones abierto en otra ventana." DarkGray
    }
}

# ---------------------------------------------------------------
# MANUAL - solo OpenSSH desde zip (para equipos sin capacidad FoD)
# ---------------------------------------------------------------
Function Modo-Manual {
    EscribeLog "TERMINUS - INSTALACION MANUAL DE OPENSSH" Cyan
    $ssh = Get-EstadoOpenSSH
    if ($ssh.Tipo -ne "NoInstalado") {
        EscribeLog "  Ya hay un sshd instalado ($($ssh.Tipo): $($ssh.Ruta)). No se instala otro." Yellow
        return
    }
    Set-TLS12 -Sistema:((Get-InfoSO).Build -le 17763)
    Instalar-OpenSSHManual
    EscribeLog "  Siguiente paso: opcion [I] Instalar (detectara este OpenSSH y lo usara)." Yellow
}

# ---------------------------------------------------------------
# REPARAR - deja todo en el formato Terminus sin tocar lo antiguo
# ---------------------------------------------------------------
Function Modo-Reparar {
    EscribeLog "TERMINUS - REPARACION" Cyan
    Completar-Datos "UsuarioLocal"
    $reiniciar = $false

    Titulo "OpenSSH"
    $ssh = Get-EstadoOpenSSH
    if ($ssh.Tipo -eq "NoInstalado") { throw "OpenSSH no esta instalado. Usar la opcion [I] Instalar." }
    if ($ssh.Arranque -ne "Auto") { Set-Service sshd -StartupType Automatic; EscribeLog "  sshd en arranque automatico." Green }
    if (Reparar-AclCarpetaOpenSSH $ssh) { $reiniciar = $true }

    # Claves de host: si los permisos estan mal, sshd no arranca.
    foreach ($k in Get-ChildItem "$SshData\ssh_host_*_key" -ErrorAction SilentlyContinue) {
        if ((Test-AclSsh $k.FullName).Count -gt 0) { Set-AclSsh $k.FullName; EscribeLog "  Permisos corregidos: $($k.Name)" Green; $reiniciar = $true }
    }

    # sshd_config: solo se anade el bloque estandar si falta (con copia).
    if (Test-Path $SshdConfig) {
        $cfg = Get-Content $SshdConfig
        if (-not ($cfg -match '^\s*Match\s+Group\s+administrators')) {
            EscribeLog "  Falta el bloque 'Match Group administrators' en sshd_config." Yellow
            if (Pregunta "Anadir el bloque estandar de Microsoft?") {
                Copy-Item $SshdConfig "$SshdConfig.terminus_$(Get-Date -Format yyyyMMddHHmmss).bak"
                Add-Content $SshdConfig "`nMatch Group administrators`n       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys" -Encoding ASCII
                EscribeLog "  Bloque anadido (copia .bak creada)." Green; $reiniciar = $true
            }
        }
    }

    Titulo "Usuario y clave"
    Asegurar-Usuario
    Asegurar-Clave
    $reiniciar = $true

    Titulo "Agente Azure Arc"
    if (Test-Path $AzcmExe) {
        foreach ($s in "himds") {
            $svc = Get-Service $s -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne "Running") { Start-Service $s; EscribeLog "  Servicio $s arrancado." Green }
        }
        Configurar-AgenteArc
        $arc = Get-EstadoArc
        if ($arc.Estado -eq "Connected") { EscribeLog "  Conectado como $($arc.Nombre)." Green }
        else { EscribeLog "  Estado '$($arc.Estado)': hay que volver a dar de alta (opcion [Q] y luego [I])." Red }
    } else {
        EscribeLog "  Agente no instalado. Usar la opcion [I] Instalar." Yellow
    }

    if ($reiniciar) { Restart-Service sshd; EscribeLog "  sshd reiniciado." DarkGray }
    EscribeLog ""
    EscribeLog "  Reparacion terminada. Recomendado: opcion [V] para comprobar." Green
}

# Desconecta y desinstala el agente Arc (comun a Quitar y Limpiar).
# Borrar el recurso en Azure es opcional: pide el secreto del SP.
Function Quitar-AgenteArc {
    param($arc)
    if ($arc.Instalado) {
        if ($arc.Estado -eq "Connected") {
            $hecho = $false
            if (Pregunta "Borrar tambien el recurso en Azure (pide el secreto del SP)?") {
                Completar-Datos "SpAppId"
                $sec = $Terminus.SpSecret                  # de la config local, si esta
                if (-not $sec) {
                    $s = Read-Host "Secreto del Service Principal" -AsSecureString
                    $sec = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
                }
                & $AzcmExe disconnect --service-principal-id $Terminus.SpAppId --service-principal-secret $sec 2>&1 | Out-Null
                $hecho = ($LASTEXITCODE -eq 0)
                Borrar-Secreto $sec; $sec = $null
            }
            if (-not $hecho) {
                & $AzcmExe disconnect --force-local-only 2>&1 | Out-Null
                EscribeLog "  Desconectado solo en local. El administrador debe borrar '$($arc.Nombre)' en Azure." Yellow
            } else { EscribeLog "  Recurso '$($arc.Nombre)' eliminado de Azure." Green }
        }
        $prod = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like "Azure Connected Machine Agent*" } | Select-Object -First 1
        if ($prod) {
            Start-Process msiexec.exe -Wait -ArgumentList "/x $($prod.PSChildName) /qn" | Out-Null
            EscribeLog "  Agente desinstalado." Green
        }
    } else { EscribeLog "  No instalado." DarkGray }
    foreach ($d in "$env:ProgramData\AzureConnectedMachineAgent", "$env:ProgramData\GuestConfig", "$env:ProgramW6432\AzureConnectedMachineAgent") {
        if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Quita solo las lineas de clave de Terminus. Las demas se conservan.
Function Quitar-ClaveTerminus {
    Set-ClaveUsuario -Quitar
    $lin = Get-LineasClaves
    if ($lin.Terminus.Count -eq 0) { EscribeLog "  No hay clave Terminus." DarkGray; return }
    Copy-Item $AdminKeys "$AdminKeys.terminus_$(Get-Date -Format yyyyMMddHHmmss).bak" -Force
    [IO.File]::WriteAllText($AdminKeys, ((@($lin.Otras) -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
    Set-AclSsh $AdminKeys
    EscribeLog "  Clave Terminus quitada ($($lin.Otras.Count) lineas del sistema anterior conservadas)." Green
}

# ---------------------------------------------------------------
# QUITAR - solo Terminus (agente Arc + clave). OpenSSH, usuario y el
# sistema anterior quedan como estaban. Sirve para volver atras.
# ---------------------------------------------------------------
Function Modo-Quitar {
    $ErrorActionPreference = "Continue"
    EscribeLog "TERMINUS - QUITAR TERMINUS (se conserva OpenSSH y el sistema anterior)" Cyan
    $arc = Get-EstadoArc
    Write-Host "  Se quitara: agente Azure Arc ($(if ($arc.Instalado) { "$($arc.Estado) $($arc.Nombre)" } else { 'no instalado' })) y la clave Terminus."
    if (-not (Pregunta "Continuar?")) { EscribeLog "Cancelado." Yellow; return }

    Titulo "1/2 Agente Azure Arc"
    Quitar-AgenteArc $arc
    Titulo "2/2 Clave Terminus"
    Quitar-ClaveTerminus
    if (Get-Service sshd -ErrorAction SilentlyContinue) { Restart-Service sshd -ErrorAction SilentlyContinue }
    EscribeLog ""
    EscribeLog "  Terminus quitado. OpenSSH y el sistema anterior siguen igual." Green
}

# ---------------------------------------------------------------
# LIMPIAR - limpieza total del equipo (Terminus + OpenSSH + sistema anterior)
# ---------------------------------------------------------------
Function Modo-Limpiar {
    $stamp  = Get-Date -Format "yyyyMMdd_HHmmss"
    $backup = "$env:SystemDrive\TerminusBackup_$stamp"
    $script:LogFile = "$backup\terminus_limpieza.log"     # C:\ProgramData\Terminus se borra

    Completar-Datos "UsuarioLocal"
    $ssh = Get-EstadoOpenSSH
    $arc = Get-EstadoArc
    $old = Get-EntornoAntiguo

    Write-Host ""
    Write-Host "=================== ATENCION ===================" -ForegroundColor Red
    Write-Host " LIMPIEZA TOTAL: se quita TODO el acceso remoto de este equipo:" -ForegroundColor Red
    Write-Host "  - Agente Azure Arc   : $(if ($arc.Instalado) { "$($arc.Estado) $($arc.Nombre)" } else { 'no instalado' })"
    Write-Host "  - OpenSSH Server     : $($ssh.Tipo) $($ssh.Ruta)"
    Write-Host "  - Carpeta $SshData (claves de host y autorizadas)"
    Write-Host "  - Reglas de firewall de OpenSSH / sshd"
    Write-Host "  - Restos del sistema anterior (ficheros de Legado.Ficheros)"
    Write-Host " El sistema antiguo DEJARA DE FUNCIONAR en este equipo." -ForegroundColor Red
    Write-Host " Antes se copia todo a: $backup" -ForegroundColor Yellow
    Write-Host "================================================" -ForegroundColor Red
    $conf = Read-Host "Escribe LIMPIAR para continuar"
    if ($conf -cne "LIMPIAR") { Write-Host "Cancelado." -ForegroundColor Yellow; return }
    $ErrorActionPreference = "Continue"      # limpieza: seguir aunque algo falle
    # El usuario con el que se ejecuta no se puede borrar (normalmente es el mismo).
    $t = Get-UsuarioTunel
    $uLocal = if ($t.Dominio) { $null } else { Get-LocalUser -Name $t.Corto -ErrorAction SilentlyContinue }
    if ($t.EsSesion) {
        Write-Host "  El usuario '$($t.Completo)' es el de esta sesion: no se borra." -ForegroundColor Yellow
        $borrarUsuario = $false
    } elseif (-not $uLocal -or $uLocal.Description -notlike "Terminus*") {
        Write-Host "  El usuario '$($t.Completo)' no lo creo Terminus: no se borra." -ForegroundColor DarkGray
        $borrarUsuario = $false
    } else {
        $borrarUsuario = Pregunta "Eliminar tambien el usuario local '$($Terminus.UsuarioLocal)' y su perfil?"
    }

    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    Proteger-Carpeta $backup        # contendra claves privadas de host y del sistema anterior
    EscribeLog "TERMINUS - LIMPIEZA TOTAL  $stamp" Cyan

    # --- 1. Copia de seguridad ----------------------------------
    Titulo "1/6 Copia de seguridad"
    if (Test-Path $SshData)     { Copy-Item $SshData "$backup\ssh" -Recurse -Force }
    if (Test-Path $DirTerminus) { Copy-Item $DirTerminus "$backup\Terminus" -Recurse -Force }
    $restos = @(Get-FicherosLegado)
    if ($restos) { New-Item -ItemType Directory -Path "$backup\antiguo" -Force | Out-Null }
    foreach ($r in $restos) {
        # Nombre plano: C:\Users\x\.ssh\f -> Users_x_.ssh_f
        $dest = Join-Path "$backup\antiguo" ($r.FullName.Substring(3) -replace '[\\:]', '_')
        try   { Copy-Item $r.FullName $dest -Recurse -Force -ErrorAction Stop }
        catch { EscribeLog "  AVISO: no se pudo copiar $($r.FullName): $($_.Exception.Message)" Yellow }
    }
    EscribeLog "  Copia en $backup (contiene claves privadas: borrarla cuando ya no haga falta)." Yellow

    # --- 2. Agente Arc --------------------------------------------
    Titulo "2/6 Agente Azure Arc"
    Quitar-AgenteArc $arc

    # --- 3. OpenSSH ----------------------------------------------
    Titulo "3/6 OpenSSH Server"
    foreach ($s in "sshd", "ssh-agent") { Stop-Service $s -Force -ErrorAction SilentlyContinue }
    if ($ssh.Tipo -eq "Manual") {
        $un = Join-Path $ssh.Carpeta "uninstall-sshd.ps1"
        if (Test-Path $un) { & powershell -NoProfile -ExecutionPolicy Bypass -File $un | Out-Null }
        sc.exe delete sshd 1>$null 2>$null
        Remove-Item $ssh.Carpeta -Recurse -Force -ErrorAction SilentlyContinue
        $path = ([Environment]::GetEnvironmentVariable("Path", "Machine") -split ';' | Where-Object { $_ -and $_ -ne $ssh.Carpeta }) -join ';'
        [Environment]::SetEnvironmentVariable("Path", $path, "Machine")
        EscribeLog "  OpenSSH manual eliminado ($($ssh.Carpeta))." Green
    }
    if ($ssh.Capacidad -eq "Installed") {
        try {
            Get-WindowsCapability -Online -Name "OpenSSH.Server*" | Remove-WindowsCapability -Online -ErrorAction Stop | Out-Null
            EscribeLog "  Capacidad OpenSSH Server eliminada (puede pedir reinicio)." Green
        } catch {
            # En algunas versiones (2025) viene integrado: se deshabilita.
            Set-Service sshd -StartupType Disabled -ErrorAction SilentlyContinue
            EscribeLog "  No se puede quitar la capacidad: servicio sshd deshabilitado." Yellow
        }
    }

    # --- 4. Datos y firewall -------------------------------------
    Titulo "4/6 Datos de SSH y firewall"
    if (Test-Path $SshData) { Remove-Item $SshData -Recurse -Force -ErrorAction SilentlyContinue; EscribeLog "  $SshData eliminado." Green }
    $nombres = @("OpenSSH-Server-In-TCP") + @($Terminus.Legado.ReglaFirewall | Where-Object { $_ })
    $reglas = @(Get-NetFirewallRule -Name $nombres -ErrorAction SilentlyContinue)
    $reglas += @(Get-NetFirewallRule -DisplayName "OpenSSH*" -ErrorAction SilentlyContinue)
    foreach ($r in ($reglas | Sort-Object Name -Unique)) {
        Remove-NetFirewallRule -Name $r.Name; EscribeLog "  Regla de firewall eliminada: $($r.DisplayName)" Green
    }

    # --- 5. Restos del sistema antiguo ---------------------------
    Titulo "5/6 Restos del entorno antiguo"
    foreach ($r in $restos) { Remove-Item $r.FullName -Recurse -Force -ErrorAction SilentlyContinue; EscribeLog "  Eliminado: $($r.FullName)" Green }
    if (-not $restos) { EscribeLog "  No hay restos." DarkGray }

    # --- 6. Usuario y carpeta Terminus ---------------------------
    Titulo "6/6 Usuario y carpetas"
    if ($borrarUsuario) {
        $u = Get-LocalUser -Name $Terminus.UsuarioLocal -ErrorAction SilentlyContinue
        if ($u) {
            Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -eq $u.SID.Value } | Remove-CimInstance -ErrorAction SilentlyContinue
            Remove-LocalUser -Name $Terminus.UsuarioLocal
            EscribeLog "  Usuario '$($Terminus.UsuarioLocal)' y su perfil eliminados." Green
        }
    }
    foreach ($d in $DirTerminus, $DirTemp) { if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue } }

    EscribeLog ""
    EscribeLog "  Equipo limpio. Log y copia en $backup" Green
    EscribeLog "  Si se ha quitado la capacidad de Windows, reiniciar antes de reinstalar." Yellow
}

# ---------------------------------------------------------------
# MONITOR - conexiones SSH en directo (sustituye a check-tunnel)
# ---------------------------------------------------------------
Function Modo-Monitor {
    $ultimoArc = [datetime]::MinValue
    $arc = $null
    while ($true) {
        # El estado de Arc tarda: se consulta cada 60 s.
        if (((Get-Date) - $ultimoArc).TotalSeconds -ge 60) { $arc = Get-EstadoArc; $ultimoArc = Get-Date }

        $todas = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue)
        $sesiones = foreach ($c in ($todas | Where-Object { $_.LocalPort -eq 22 })) {
            $local = ($c.RemoteAddress -eq "127.0.0.1" -or $c.RemoteAddress -eq "::1")
            $origen = if ($local) { "Terminus (Arc)" }
                      elseif ($Terminus.Legado.IPs -contains $c.RemoteAddress) { "Sistema anterior" }
                      else { "Otro" }
            # En las de Arc, el otro extremo es el proceso del agente.
            $peer = if ($local) { $todas | Where-Object { $_.LocalPort -eq $c.RemotePort -and $_.RemotePort -eq 22 } | Select-Object -First 1 } else { $null }
            [pscustomobject]@{
                Origen   = $origen
                Remoto   = "$($c.RemoteAddress):$($c.RemotePort)"
                Proceso  = if ($peer) { (Get-Process -Id $peer.OwningProcess -ErrorAction SilentlyContinue).ProcessName } else { "" }
                Desde    = $c.CreationTime
            }
        }
        $sesiones = @($sesiones)

        Clear-Host
        $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Write-Host "TERMINUS - Conexiones de soporte" -ForegroundColor Cyan
        Write-Host "Fecha: $now   Equipo: $env:COMPUTERNAME" -ForegroundColor DarkGray
        $sshd = Get-Service sshd -ErrorAction SilentlyContinue
        $himds = Get-Service himds -ErrorAction SilentlyContinue
        Write-Host ("sshd: {0}   himds: {1}   Azure Arc: {2} {3}" -f
            $(if ($sshd) { $sshd.Status } else { "no instalado" }),
            $(if ($himds) { $himds.Status } else { "no instalado" }),
            $(if ($arc.Instalado) { $arc.Estado } else { "no instalado" }),
            $(if ($arc.Nombre) { "($($arc.Nombre))" } else { "" })) -ForegroundColor DarkGray
        Write-Host ""

        if ($sesiones.Count -gt 0) {
            Write-Host "CONEXIONES ACTIVAS: $($sesiones.Count)" -ForegroundColor Green
            $sesiones | Format-Table -AutoSize | Out-String | Write-Host
            $Host.UI.RawUI.WindowTitle = "Terminus - $($sesiones.Count) conexion(es)"
        } else {
            Write-Host "SIN CONEXIONES ACTIVAS" -ForegroundColor Yellow
            $Host.UI.RawUI.WindowTitle = "Terminus - sin conexiones"
        }
        if ($arc.Instalado -and $arc.Estado -ne "Connected") {
            Write-Host "AVISO: el agente Arc no esta conectado ($($arc.Estado))" -ForegroundColor Red
        }
        Write-Host "Ctrl+C para salir" -ForegroundColor DarkGray
        Start-Sleep -Seconds $Terminus.IntervaloCheck
    }
}

### =================================================================
### BLOQUE 5 - EJECUCION
### =================================================================

if (-not (EsAdministrador)) {
    Write-Host "Hay que ejecutar como Administrador (Terminus.cmd lo hace solo)." -ForegroundColor Red
    exit 1
}

# Solo si es la carpeta de instalacion (X:\Terminus), no una de pruebas.
if ($PSScriptRoot -match '^[A-Za-z]:\\Terminus$') { Proteger-Carpeta $PSScriptRoot }

try {
    switch ($Modo) {
        "Validar"  { Modo-Validar }
        "Instalar" { Modo-Instalar }
        "Manual"   { Modo-Manual }
        "Reparar"  { Modo-Reparar }
        "Quitar"   { Modo-Quitar }
        "Limpiar"  { Modo-Limpiar }
        "Monitor"  { Modo-Monitor }
        "Salir"    { }                 # solo borra el secreto (bloque finally)
    }
} catch {
    EscribeLog "ERROR: $($_.Exception.Message)" Red
    EscribeLog "Detalle en: $LogFile" DarkGray
    $script:Fallo = $true
} finally {
    # El secreto no se queda en disco aunque la instalacion falle a medias
    # (para reintentar, volver a pegar la configuracion de Bitwarden).
    if ($Modo -in "Instalar", "Quitar", "Limpiar", "Salir" -and $Terminus.SpSecret) { Borrar-Secreto $Terminus.SpSecret }
}
if ($script:Fallo) { exit 1 }
exit 0
