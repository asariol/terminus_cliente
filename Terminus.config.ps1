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
#        UsuarioLocal   = "<usuario>"
#        Legado = @{
#            Ficheros      = @(".ssh\<prefijo>_rsa*", "Downloads\<prefijo>_rsa*", "<log>.log")
#            ReglaFirewall = "<nombre de la regla>"
#            IPs           = @("<ip del sistema anterior>")
#        }
#    }
#
#  El secreto del Service Principal NO va en ningun fichero: se pide
#  siempre al instalar y no se guarda.
# =====================================================================

$Terminus = @{

    # --- Azure: genericos -------------------------------------------
    ResourceGroup   = "rg-acceso-clientes"
    Location        = "spaincentral"

    # --- Azure: se piden si no estan en la configuracion local ------
    TenantId        = ""
    SubscriptionId  = ""
    SpAppId         = ""
    SpSecret        = ""            # nunca rellenar: se pide al instalar

    # --- Acceso SSH -------------------------------------------------
    UsuarioLocal    = ""            # se pide si no esta en la configuracion local
    # Clave publica de operadores (no es secreta). El comentario final
    # "terminus" identifica la linea: solo se tocan las lineas con esa marca.
    ClavePublica    = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDEe83V2LYrfbWaqdDPZSr88s7asTnY1mAirX6N8Ce/L terminus"
    # La clave solo vale para conexiones locales (Arc llega por 127.0.0.1).
    RestringirLocal = $true

    # --- Instalacion manual de OpenSSH (Server 2016 o sin FoD) -------
    OpenSSHZipUrl    = "https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.5.0.0p1-Beta/OpenSSH-Win64.zip"
    OpenSSHZipSha256 = ""

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
