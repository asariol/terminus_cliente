# =====================================================================
#  Terminus.config.ps1  -  Configuracion GENERICA (repositorio publico)
# =====================================================================
#  Aqui solo van valores por defecto, iguales en todas las instalaciones
#  y sin ningun dato sensible ni de ningun entorno concreto.
#
#  Los datos de cada entorno van en Terminus.config.local.psd1, junto al
#  script. Es un fichero de DATOS (se lee con Import-PowerShellDataFile:
#  no se ejecuta ningun codigo de el) y no se publica nunca. Ejemplo:
#
#    @{
#        TenantId       = '<guid>'
#        SubscriptionId = '<guid>'
#        ClavePublica   = 'ssh-ed25519 AAAA... terminus'   # clave PUBLICA de operadores
#        UsuarioLocal   = '<usuario>'      # opcional: usuario o DOMINIO\usuario
#        # Opcional. Sin secreto, el alta se hace con la cuenta personal del
#        # operador (inicio de sesion con codigo + MFA): es la forma recomendada.
#        SpAppId        = '<guid>'
#        SpSecret       = '<secreto>'      # se BORRA del fichero y del historial al terminar
#        PermitirComandos = $false         # solo tunel RDP (por defecto $true: tambien comandos por SSH)
#        Legado = @{                        # restos de un sistema de acceso anterior (solo se detectan)
#            Ficheros      = @('.ssh\<prefijo>_rsa*')
#            ReglaFirewall = '<nombre de la regla>'
#            IPs           = @('<ip del sistema anterior>')
#        }
#    }
#
#  Todo lo que falte se pregunta por pantalla al ejecutar.
# =====================================================================

$Terminus = @{

    # --- Azure ------------------------------------------------------
    ResourceGroup   = "rg-acceso-clientes"
    Location        = "spaincentral"
    TenantId        = ""            # configuracion local o se pregunta
    SubscriptionId  = ""            # configuracion local o se pregunta
    SpAppId         = ""            # opcional (alta con Service Principal)
    SpSecret        = ""            # NUNCA aqui: solo en la configuracion local, y se borra al usarlo

    # --- Acceso SSH -------------------------------------------------
    # Usuario del tunel: uno que ya exista en el equipo y sea administrador
    # ("usuario" local o "DOMINIO\usuario"). Vacio = se pregunta (Intro = el
    # de la sesion). Se guarda como etiqueta UsuarioTunel en Azure.
    UsuarioLocal    = ""
    # Clave PUBLICA de operadores (no es secreta, pero no se publica aqui):
    # llega en la configuracion local. Su comentario final "terminus"
    # identifica la linea: solo se tocan las lineas con esa marca.
    ClavePublica    = ""

    # Restricciones de la clave en authorized_keys (ver SECURITY.md):
    #  - from="127.0.0.1,::1": solo vale para conexiones que entran por el
    #    agente de Azure Arc (local). Desde la red no sirve aunque el puerto
    #    22 estuviera abierto.
    #  - PermitirComandos = $true (por defecto): tunel RDP + comandos remotos
    #    por SSH (automatizaciones, sustituto de Jenkins). Sin reenvio de
    #    agente ni X11; redireccion solo al RDP local.
    #  - PermitirComandos = $false (si el cliente lo pide): solo tunel RDP.
    #    "restrict" (sin terminal, agente, X11 ni redirecciones),
    #    "port-forwarding" + "permitopen" solo hacia el RDP local, y
    #    "command" fijo: cualquier intento de ejecutar algo solo muestra un
    #    mensaje. No hay consola remota.
    RestringirLocal  = $true
    PermitirComandos = $true

    # Endurecer sshd si en el equipo no hay otro sistema de acceso por SSH:
    # escucha solo en 127.0.0.1/::1 y sin contrasenas (solo claves).
    EndurecerSshd   = $true

    # --- Instalacion manual de OpenSSH (Server 2016 o sin FoD) -------
    OpenSSHZipUrl    = "https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.5.0.0p1-Beta/OpenSSH-Win64.zip"
    # SHA256 del zip oficial (v9.5.0.0p1-Beta). Si se cambia la URL, cambiar el hash.
    OpenSSHZipSha256 = "BD48FE985D400402C278C485DB20E6A82BC4C7F7D8E0EF5A81128F523096530C"

    # --- Agente Azure Arc (MSI oficial; se comprueba la firma de Microsoft)
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
