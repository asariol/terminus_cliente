# Seguridad de Terminus (cliente)

Este documento describe exactamente qué hace el instalador en el servidor del cliente, qué no hace y qué riesgos quedan. Todo lo que se afirma aquí se puede comprobar en `Terminus.ps1` y `Terminus.config.ps1`.

## Resumen

Terminus permite que el equipo de soporte se conecte por RDP a un servidor Windows **sin abrir ningún puerto de entrada**. El servidor solo hace conexiones **salientes por HTTPS (443) hacia Microsoft** (Azure Arc). La conexión del técnico entra por un relay de Microsoft y llega al servidor por `127.0.0.1`.

Para conectarse hacen falta **dos factores independientes**:

1. **Identidad en Microsoft Entra ID con MFA** y pertenencia a un grupo con el rol *Virtual Machine Local User Login* sobre el grupo de recursos. Sin esto, Azure no abre el relay hacia el servidor.
2. **Una clave SSH** (ed25519) que el servidor solo acepta si la conexión llega por el agente de Azure Arc (desde `127.0.0.1`/`::1`) y que solo permite el túnel hacia el RDP local.

Cada apertura de conexión queda registrada en el registro de actividad de Azure con la identidad de la persona (`Microsoft.HybridConnectivity/endpoints/listCredentials/action`).

## Red

| Dirección | Qué | Dónde se ve en el código |
|---|---|---|
| Entrada | **Ninguna.** En instalaciones nuevas se desactiva la regla de firewall `OpenSSH-Server-In-TCP` y `sshd` escucha solo en `127.0.0.1` y `::1`. | `Modo-Instalar`, `Endurecer-Sshd` |
| Salida 443 | Servicios de Azure Arc: `login.microsoftonline.com`, `login.windows.net`, `pas.windows.net`, `management.azure.com`, `*.his.arc.azure.com`, `*.guestconfiguration.azure.com`, `guestnotificationservice.azure.com` y el relay `*.servicebus.windows.net`. Descargas: `aka.ms`, `download.microsoft.com`, `github.com` (solo el zip oficial de OpenSSH cuando Windows no lo trae). Lista completa: [requisitos de red de Azure Arc](https://learn.microsoft.com/azure/azure-arc/servers/network-requirements). | `$HostsArc`, `Instalar-AgenteArc`, `Instalar-OpenSSHManual` |

## Restricciones de la clave SSH

La línea que se añade a `administrators_authorized_keys` (y al `authorized_keys` del usuario del túnel) es, por defecto:

```
from="127.0.0.1,::1",restrict,port-forwarding,command="echo Terminus: acceso solo para el tunel RDP",permitopen="localhost:3389",permitopen="127.0.0.1:3389" ssh-ed25519 AAAA... terminus
```

| Opción | Efecto |
|---|---|
| `from="127.0.0.1,::1"` | La clave solo es válida para conexiones que llegan por el agente de Azure Arc. Desde la red local o Internet no sirve, aunque alguien abriera el puerto 22. |
| `restrict` | Sin terminal, sin reenvío de agente, sin X11, sin redirecciones. |
| `port-forwarding` + `permitopen` | Vuelve a permitir **solo** la redirección hacia el RDP local (puerto 3389). Ningún otro destino. |
| `command="echo ..."` | Cualquier intento de ejecutar un comando o abrir una consola solo muestra ese mensaje. No hay shell remota. |

Este comportamiento se ha verificado con OpenSSH 9.x: el túnel al 3389 funciona; un comando (`id`), una consola, `scp` o un túnel a otro puerto se rechazan; la autenticación por contraseña se rechaza.

`PermitirComandos = $true` (opcional, configuración local) quita `restrict` y `command` para permitir comandos remotos por SSH. Solo se activa si el cliente lo decide; la redirección sigue limitada al 3389 y la clave sigue limitada a `from=`.

## Qué modifica en el servidor

| Cambio | Cuándo | Reversible con |
|---|---|---|
| Activa OpenSSH Server (capacidad de Windows) o lo instala desde el zip oficial de Microsoft (`Win32-OpenSSH`) con **SHA256 verificado**. | Solo si no hay OpenSSH. | `[L]` |
| Añade una línea, marcada con ` terminus`, a `administrators_authorized_keys` y al `authorized_keys` del usuario del túnel. El resto de líneas no se tocan. Copia `.bak` previa. | `[I]`, `[R]` | `[Q]` |
| `sshd_config`: bloque marcado al principio con `ListenAddress 127.0.0.1`, `ListenAddress ::1`, `PasswordAuthentication no`, `ChallengeResponseAuthentication no`. Se valida con `sshd -t`; si no es válido, se restaura la copia. | Solo si no hay otro sistema de acceso por SSH en el equipo. | `[Q]` lo quita |
| Desactiva la regla de firewall de entrada `OpenSSH-Server-In-TCP`. | Instalación nueva sin otro sistema SSH. | Manual |
| Instala el agente de Azure Arc (MSI oficial, **firma Authenticode de Microsoft verificada**) y lo configura: `incomingconnections.ports 22`, `extensions.enabled false`, `guestconfiguration.enabled false`. | `[I]` | `[Q]` |
| Usuario del túnel: se usa uno existente. Solo se crea un usuario local (contraseña aleatoria de 36 caracteres que no se guarda) si se confirma. | `[I]` | `[L]` |
| `C:\Terminus` (scripts) y `C:\ProgramData\Terminus` (logs): permisos solo para Administradores y SYSTEM. | Cada ejecución | — |
| Server 2016/2019: activa TLS 1.2 para .NET (`SchUseStrongCrypto`), necesario para descargar de forma segura. | `[I]` si falta | Manual |

**Qué no hace:** no instala extensiones de Azure, no activa Guest Configuration ni Run Command, no abre puertos de entrada, no guarda contraseñas, no envía datos del servidor a terceros (solo el registro del equipo en Azure Arc: nombre, sistema operativo y etiquetas), no modifica un sistema de acceso SSH anterior (solo añade o quita sus propias líneas).

Con extensiones y Guest Configuration desactivados en el agente, desde Azure no se puede ejecutar código en el servidor: la única vía de entrada es el túnel SSH restringido descrito arriba. Esta configuración del agente es local: solo un administrador del propio servidor la puede cambiar.

## Secretos

- **No se guarda ningún secreto en el servidor.** El alta en Azure se hace por defecto con la cuenta personal del técnico (`azcmagent connect --use-device-code`: código en el navegador + MFA).
- Alternativa: alta con un Service Principal cuyo rol solo permite dar de alta y borrar equipos de Azure Arc del grupo de recursos (no da acceso a los equipos). Solo se usa si su secreto viene en la configuración local; se borra del fichero y del historial de PowerShell al terminar, haya ido bien o mal. Limitación conocida: durante los segundos del alta, el secreto se pasa como argumento a `azcmagent` y un administrador local podría verlo en la lista de procesos. Por eso el modo recomendado es el de la cuenta personal.
- La configuración local (`Terminus.config.local.psd1`) es un fichero de **datos**: se lee con `Import-PowerShellDataFile`, que no ejecuta código.
- La clave **pública** de operadores no está en este repositorio: llega en la configuración local.

## Registro y auditoría

- Azure: cada apertura del túnel queda en el registro de actividad con la identidad Entra ID de la persona (90 días; se puede exportar a Log Analytics para más tiempo).
- Servidor: inicios de sesión SSH en el visor de eventos (`OpenSSH/Operational`) y sesiones RDP en los registros habituales de Windows.
- Terminus: `C:\ProgramData\Terminus\terminus.log`. La opción `[C]` muestra las conexiones en directo.

## Riesgos residuales y cómo se mitigan

| Riesgo | Mitigación |
|---|---|
| La clave privada de operadores es compartida por el equipo de soporte. | Sola no da acceso: sin cuenta Entra ID con MFA en el grupo autorizado no se abre el relay, y por la red la clave no es válida (`from=`). Retirar a una persona del grupo le quita el acceso a todos los servidores al momento. |
| El usuario del túnel es administrador del servidor. | En el modo por defecto la clave no permite shell ni comandos: solo el túnel al RDP, donde la persona tiene que iniciar sesión con credenciales de Windows. |
| Los scripts no están firmados (se ejecutan con `-ExecutionPolicy Bypass`). | El código es abierto y legible. Se recomienda revisarlo y comprobar el hash de la versión descargada antes de ejecutarlo. |
| Dependencia del servicio de Microsoft (Azure Arc). | Si Azure no está disponible no hay acceso remoto; no se abre ninguna vía alternativa. |

## Desinstalación

- `[Q] Quitar`: desconecta y desinstala el agente de Azure Arc (y borra el equipo de Azure), quita la línea de la clave y el bloque de `sshd_config`. OpenSSH y cualquier sistema anterior quedan como estaban.
- `[L] Limpiar`: elimina todo, OpenSSH incluido, previa copia de seguridad y confirmación escrita.
