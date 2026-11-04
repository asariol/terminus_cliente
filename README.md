# Terminus (cliente)

Instalador para dar acceso de soporte remoto a un servidor Windows a traves de **Azure Arc** (SSH + RDP dentro del tunel), sin abrir puertos de entrada: el equipo solo sale por 443 hacia Microsoft.

## Uso

1. Descargar y descomprimir esta carpeta en el servidor (por ejemplo en `C:\Terminus`).
2. (Opcional) Crear `Terminus.config.local.ps1` con los datos del entorno (ver ejemplo en `Terminus.config.ps1`). Si no existe, se preguntan por pantalla.
3. Ejecutar `Terminus.cmd` (se eleva a Administrador solo).

| Opcion | Que hace |
|---|---|
| **V** Validar | Solo lectura. OpenSSH, permisos, claves, agente Arc y salida 443. Deja un informe junto al script. |
| **I** Instalar | OpenSSH (si falta) + usuario + clave + agente Arc con nombre y etiquetas. Abre el monitor al acabar. |
| **M** Manual | OpenSSH desde zip (Server 2016 o equipos sin Windows Update). |
| **R** Reparar | Permisos, servicio, clave y configuracion del agente. |
| **E** Eliminar | Quita todo (Arc, OpenSSH, claves, reglas). Pide confirmacion escrita y hace copia. |
| **C** Monitor | Conexiones SSH en directo. |

## Seguridad

- Este repositorio no contiene datos de ningun entorno. Los IDs van en el fichero local o se preguntan; el secreto del Service Principal se pide al instalar o, si se pone en el fichero local, se borra automaticamente al terminar el alta.
- El agente Arc se configura solo para SSH (puerto 22), sin extensiones ni Guest Configuration.
- La clave publica solo es valida para conexiones locales (`from="127.0.0.1,::1"`), que es por donde entra Arc.
- Si ya existe un sistema de acceso por SSH, Instalar y Reparar no lo modifican.

Requisitos: Windows Server 2016 o posterior, PowerShell 5.1, salida HTTPS hacia los servicios de Azure Arc.
