# Terminus (cliente)

Instalador para dar acceso de soporte remoto a un servidor Windows a traves de **Azure Arc** (SSH + RDP dentro del tunel), sin abrir puertos de entrada: el equipo solo sale por 443 hacia Microsoft.

## Uso

Lo normal: en PowerShell como Administrador, pegar la **linea de instalacion** que entrega el administrador. Descarga esta carpeta en `C:\Terminus`, escribe `Terminus.config.local.ps1` (los datos del entorno van dentro de la linea, en base64) y abre el menu.

A mano:

1. Descargar y descomprimir esta carpeta en el servidor en `C:\Terminus`.
2. (Opcional) Crear `Terminus.config.local.ps1` con los datos del entorno (ver ejemplo en `Terminus.config.ps1`). Lo que falte se pregunta por pantalla.
3. Ejecutar `Terminus.cmd` (se eleva a Administrador solo).

| Opcion | Que hace |
|---|---|
| **V** Validar | Solo lectura. OpenSSH, permisos, claves, agente Arc y salida 443. Deja un informe junto al script. |
| **I** Instalar | OpenSSH solo si falta (si ya existe se usa tal cual) + usuario + clave + agente Arc con nombre y etiquetas. No toca un sistema de acceso anterior. Abre el monitor al acabar. |
| **M** Manual | OpenSSH desde zip (Server 2016 o equipos sin Windows Update). |
| **R** Reparar | Permisos, servicio, clave y configuracion del agente. |
| **Q** Quitar | Solo Terminus: agente Arc y su clave. OpenSSH y el sistema anterior quedan igual. |
| **L** Limpiar | Limpieza total del equipo (Arc, OpenSSH, claves, reglas, restos del sistema anterior). Pide confirmacion escrita y hace copia. |
| **C** Monitor | Conexiones SSH en directo. |

## Usuario del tunel

Se usa un usuario que **ya exista** en el servidor y sea administrador: local (`usuario`) o de dominio (`DOMINIO\usuario`). Por defecto se propone el de la sesion. Solo se crea un usuario local nuevo si se confirma. El usuario queda guardado en Azure como etiqueta `UsuarioTunel` y el operador lo toma de ahi, asi que cada cliente puede tener uno distinto.

## OpenSSH

- Si ya hay un `sshd` (nativo en `System32\OpenSSH` o instalado a mano en `Program Files` / `Program Files (x86)`) se usa tal cual.
- Si no hay: en 2019/2022/2025 se activa la capacidad de Windows; en 2016 (o si falla) se instala desde el zip oficial, con el hash SHA256 comprobado.
- La clave se pone en `administrators_authorized_keys` y tambien en el `authorized_keys` del perfil del usuario: en versiones antiguas de OpenSSH con Windows en espanol el bloque `Match Group administrators` no se aplica.

## Seguridad

- Este repositorio no contiene datos de ningun entorno. Los IDs van en el fichero local o se preguntan.
- El secreto del Service Principal se pide al instalar o, si esta en el fichero local, se borra al terminar (haya ido bien o mal), tambien del historial de PowerShell.
- La carpeta `C:\Terminus` se deja solo para Administradores y SYSTEM al ejecutar (al crearla bajo `C:\` cualquier usuario podria modificarla).
- El agente Arc se configura solo para SSH (puerto 22), sin extensiones ni Guest Configuration.
- La clave publica solo vale para conexiones locales (`from="127.0.0.1,::1"`, que es por donde entra Arc) y solo permite redirigir al RDP local (`permitopen`), sin reenvio de agente ni X11.
- Si ya existe un sistema de acceso por SSH, Instalar y Reparar no lo modifican: solo se anaden o quitan las lineas de clave marcadas con ` terminus`.
- La copia de seguridad de Limpiar (`C:\TerminusBackup_<fecha>`) contiene claves privadas: queda solo para Administradores y hay que borrarla cuando ya no haga falta.

Requisitos: Windows Server 2016 o posterior, PowerShell 5.1, salida HTTPS hacia los servicios de Azure Arc.
