# =====================================================================
#  Terminus.config.ps1  -  Configuracion GENERICA (repositorio publico)
# =====================================================================
#  Aqui solo va lo que es igual en todas las instalaciones y no es
#  sensible. Lo especifico de cada entorno va en un fichero
#  Terminus.config.local.ps1 junto al script (no se publica) o se
#  pregunta por pantalla al ejecutar.
#
#  Ejemplo de Terminus.config.local.ps1:
#
#    $TerminusLocal = @{
#        TenantId       = "<guid>"
#        SubscriptionId = "<guid>"
#        SpAppId        = "<guid>"
#        UsuarioLocal   = "<usuario>"   # opcional: usuario o DOMINIO\usuario
#        SpSecret       = '<secreto>'   # opcional, entre comillas simples.
#                                       # Se BORRA del fichero (y del historial
#                                       # de PowerShell) al terminar el alta.
#        Legado = @{
#            Ficheros      = @(".ssh\<prefijo>_rsa*", "Downloads\<prefijo>_rsa*", "<log>.log")
#            ReglaFirewall = "<nombre de la regla>"
#            IPs           = @("<ip del sistema anterior>")
#        }
#    }
#
#  El secreto del Service Principal no se guarda: si no esta en la
#  configuracion local se pide al instalar, y si esta, se borra al acabar
#  (haya ido bien o mal). La carpeta C:\Terminus se deja solo para
#  Administradores y SYSTEM al ejecutar.
# =====================================================================

$Terminus = @{

    # --- Azure: genericos -------------------------------------------
    ResourceGroup   = "rg-acceso-clientes"
    Location        = "spaincentral"

    # --- Azure: se piden si no estan en la configuracion local ------
    TenantId        = ""
    SubscriptionId  = ""
    SpAppId         = ""
    SpSecret        = ""            # nunca aqui (repositorio publico)

    # --- Acceso SSH -------------------------------------------------
    # Usuario del tunel: uno que ya exista en el equipo del cliente y sea
    # administrador ("usuario" local o "DOMINIO\usuario"). Vacio = se pregunta
    # (Intro = el de la sesion). Se guarda como etiqueta UsuarioTunel en Azure
    # y el operador lo lee de ahi: no hace falta el mismo usuario en todos.
    UsuarioLocal    = ""
    # Clave publica de operadores (no es secreta). El comentario final
    # "terminus" identifica la linea: solo se tocan las lineas con esa marca.
    ClavePublica    = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDEe83V2LYrfbWaqdDPZSr88s7asTnY1mAirX6N8Ce/L terminus"
    # Restricciones de la clave en authorized_keys:
    #  - solo conexiones locales (Arc llega por 127.0.0.1 / ::1): no sirve
    #    por el puerto 22 publico aunque este abierto
    #  - solo permite redirigir al RDP local (permitopen); sin agente ni X11.
    #    Los comandos remotos (ssh/scp) siguen funcionando.
    RestringirLocal = $true
    OpcionesClave   = 'permitopen="localhost:3389",permitopen="127.0.0.1:3389",no-agent-forwarding,no-X11-forwarding'

    # --- Instalacion manual de OpenSSH (Server 2016 o sin FoD) -------
    OpenSSHZipUrl    = "https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.5.0.0p1-Beta/OpenSSH-Win64.zip"
    # SHA256 del zip oficial (v9.5.0.0p1-Beta). Si se cambia la URL, cambiar el hash.
    OpenSSHZipSha256 = "BD48FE985D400402C278C485DB20E6A82BC4C7F7D8E0EF5A81128F523096530C"

    # --- Agente Azure Arc -------------------------------------------
    ArcMsiUrl       = "https://aka.ms/AzureConnectedMachineAgent"

    # --- Sistema de acceso anterior (vacio = no se busca nada) -------
    Legado = @{
        Ficheros      = @()
        ReglaFirewall = ""
        IPs           = @()
    }

    # --- Monitor de conexiones --------------------------------------
    IntervaloCheck  = 5
}
