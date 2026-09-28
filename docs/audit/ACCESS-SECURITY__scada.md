TASK_ID: ACCESS-SECURITY__scada
Repository: IMoriana3/scada

# Contraseñas y límites de acceso — revisión 2026-09-28

Estado: correcciones propuestas. No acredita seguridad comercial ni despliegue.
Toolbox: base PR scada #277, f80a812cf01f3fc05a7d4fb91f4d40a9ff462e14.
Online: base PR factiun-cartera #274, 755712c11cbeba392746c095596b9b5686a6c384.

## HECHOS del código revisado

| Evidencia | Clasificación | Corrección / estado |
|---|---|---|
| Toolbox `Usuario-Validar` comparaba Base64 con igualdad de PowerShell no sensible a mayúsculas. El agente usaba el mismo tipo de comparación para X-Token. | BUG | Comparación por bytes, sin salida temprana por contenido. Token comparado sobre SHA256 de tamaño fijo. |
| Toolbox usaba PBKDF2-SHA1 con 100.000 iteraciones, sin versión explícita. | LEGACY | Nuevas claves: PBKDF2-SHA256, 600.000 iteraciones, sal aleatoria de 16 bytes. Lectura del formato anterior y migración tras verificar la clave. |
| El cambio de contraseña no solicitaba la actual y no había límite de intentos. | BUG | Cambio con contraseña actual; cinco fallos bloquean cinco minutos, con estado persistido y error genérico. Alta/baja exigen reautenticación del administrador actual. |
| Borrar usuarios.json permitía repetir el alta inicial. | BUG | Marcador de instalación inicializada y recuperación desde copia; no se recomienda borrar cuentas como recuperación. El propietario de Windows aún puede alterar ambos archivos y el script. |
| `toolbox.html` guardaba el token de agente en localStorage. | BUG | Se elimina el valor legado sin leerlo. Token solo en memoria del formulario; nunca localStorage/sessionStorage. HTTPS remoto; HTTP solo loopback. |
| Los clientes online usaban persistencia predeterminada de Supabase. | LEGACY | Cliente común con sessionStorage, limpieza de los tokens persistentes legados, comprobación getUser, 15 minutos de inactividad y 8 horas de límite UI. Renovar el JWT no reinicia esos límites. |
| CORS del agente aceptaba cualquier origen. | BUG | Lista explícita `origenes_permitidos`; por defecto solo el origen web Factiun existente. CORS no autentica clientes nativos. |
| Toolbox declara expresamente que sus archivos/roles locales no son una frontera frente al propietario del equipo. | INTENCIONAL, limitación del producto | Se mantiene esta limitación visible. Hash más fuerte y firma de scripts no la convierten en autorización de servidor. |
| El agente recibe X-Usuario como texto declarado por el cliente y autentica con un token compartido. | INTENCIONAL/LEGACY | Sigue pendiente identidad individual verificada y permisos por operación/planta. No se presenta X-Usuario como autor autenticado. |
| INSTRUCCIONES.md online describe RLS para todo usuario autenticado; `ips.html` pide `topologia.select('*')`. | HECHO documental; permisos desplegados UNKNOWN | No se ha inspeccionado el Supabase de producción. Enmascarar una celda no equivale a proteger un secreto en el servidor. |

## Política compartida y diferencias

`contracts/access-v1.json` fija contraseñas nuevas de 15–128 caracteres,
comparación exacta, verificación de la actual y ausencia de tokens persistentes.
Diferencia INTENCIONAL: Supabase limita las claves a 72 bytes UTF-8; la web
rechaza el exceso antes de enviarlo, sin truncarlo. Se mantiene el proveedor.
Las dos copias y sus casos se comprueban con el control de paridad existente.
No se crea otro proveedor de identidad: online conserva Supabase Auth; Toolbox
mantiene su autenticación local existente como transición para el piloto.

La migración permite reconocer hashes antiguos; el diálogo exige cambiar una
contraseña antigua demasiado corta antes de completar la entrada. No se guarda
la clave en claro ni se envía al servidor para migrar la cuenta local.

La caducidad web es higiene de la interfaz. sessionStorage sigue siendo legible
por JavaScript y algunos navegadores pueden restaurarlo. No protege frente a
XSS, navegador comprometido o una copia previa del token. Al salir se solicita
revocación antes de borrar la sesión local; si falla la red no se garantiza la
revocación remota. Los JWT emitidos pueden valer hasta que caduquen.

La nueva ventana de cambio de contraseña online verifica la actual con el
proveedor y envía `current_password`; tras cambiarla solicita cierre global.
También debe activarse el requisito equivalente en Supabase: un control web
no obliga a un cliente que llame directamente a la API.

La migración de credenciales no puede deshacerse hacia un ejecutable que solo
conoce SHA1: el instalador rechaza ese retorno conservando ambas carpetas.
Usuarios, marcador y contador de acceso se preservan al actualizar. La versión
11.94 ya descargada sigue teniendo las limitaciones anteriores.

## Requisito obligatorio: Toolbox sin Internet

Confirmado por el usuario el 2026-09-28: la Toolbox debe poder funcionar offline.
El alta local, inicio de sesión, cambio de contraseña, administración autorizada,
recuperación y operaciones permitidas no exigirán Supabase, una cuenta web,
activación online ni renovar periódicamente un permiso emitido en la nube.
La comunicación con equipos sigue requiriendo su enlace local de planta.

Este requisito corrige la propuesta anterior de hacer depender la Toolbox de
cuentas web y permisos offline de duración limitada. Online mantiene su
proveedor existente; cualquier vinculación o sincronización futura será
opcional y no copiará contraseñas. Una baja remota no puede garantizarse en un
PC desconectado; debe existir revocación por un administrador local autorizado.

### Diseño propuesto, todavía no implementado

- Un servicio en el propio PC verifica la contraseña y los permisos por
  operación. La interfaz se ejecuta con un usuario estándar de Windows y no
  decide la autorización efectiva mediante su JSON, su script ni un rol enviado
  por el cliente. Se conservan cuentas nominales locales de la aplicación.
- El servicio administra hashes, roles, sesiones, intentos y registro de
  acciones en almacenamiento protegido con permisos de Windows. Su código,
  configuración, canal local de comunicación y servicio también requieren
  permisos explícitos. El instalador requerirá elevación; el uso habitual no.
  Cifrar o cambiar de extensión usuarios.json no proporciona esta separación.
- La modificación, sustitución o borrado de archivos de la interfaz no puede
  conceder acceso, restablecer los intentos ni reabrir el alta del administrador.
  La recuperación exige un administrador local autorizado y deja registro.
- Las operaciones sobre los equipos pasan por el servicio con validación de
  alcance de planta y operación. Debe impedirse también el acceso directo
  alternativo a Modbus y a los demás transportes de control mediante los
  controles de Windows/red adecuados al despliegue. Un servicio de login
  aislado no protege un canal de órdenes que siga abierto al operador.
- Las credenciales de equipos se mantienen fuera de la interfaz. La migración
  desde usuarios.json requiere que el administrador autorizado valide los
  roles: el archivo anterior es modificable y no acredita por sí solo permisos.
- El servicio deniega nuevas operaciones sin autorización válida; se definirá
  con CONTROL cómo terminar de forma segura las secuencias ya iniciadas.
  El funcionamiento offline no desactiva controles de seguridad de equipos.
- El administrador de Windows forma parte del entorno de confianza. No se
  promete resistencia frente a quien controla el sistema operativo; esa
  garantía exigiría una frontera adicional fuera de ese PC. Los registros
  locales tampoco son inmutables frente a dicho administrador.

Aceptación pendiente: probar en Windows con Internet bloqueado y transporte
de planta simulado, incluyendo primer uso, reinicio, contraseñas, recuperación,
cambio/baja de roles, manipulación del JSON/script, reinicio del limitador y
envío directo de órdenes por un cliente alternativo. Verificar que un usuario
estándar no puede modificar el servicio ni su almacenamiento. No se han
ejecutado estos ensayos ni instalado un servicio con este cambio documental.

## PROPUESTA para cerrar la seguridad comercial

1. Toolbox: implementar el servicio local y los criterios offline anteriores.
   Online: mantener Supabase con identidad individual, recuperación verificada,
   revocación y MFA para acciones sensibles. Si se añade un segundo factor a la
   Toolbox, debe funcionar también sin Internet y disponer de recuperación
   local protegida; el bloqueo de Windows no se presenta como MFA.
2. RLS y API online con pertenencia explícita a cliente/plant_id y roles de
   lectura/técnico/administrador. Probar con dos clientes, roles y API directa.
   Aplicar el mismo alcance de permisos en el servicio local; no deducir
   plant_id desde nombres o posiciones.
3. Sacar credenciales de VPN/NCU/GW de respuestas generales y exportaciones.
   Usar almacenes protegidos con permisos, rotación y registro de acceso.
4. El agente online debe verificar identidad individual y permisos por orden,
   con credenciales de servicio propias, revocables y limitadas. El token
   común y X-Usuario declarado por el cliente siguen pendientes de sustituir.

DECISIÓN de entrega: mantener etiqueta de piloto. El requisito offline queda
fijado; el servicio local, el alcance por planta y la protección de los
transportes requieren implementación y revisión transversal (06_PLANT,
05_CONTROL, 07_SCADA). PR relacionadas: scada #278 y factiun-cartera #275.
No se han rotado credenciales reales, cambiado roles de producción ni enviado
órdenes físicas. Las propuestas anteriores no constan como activadas.

## Validación

Pruebas nuevas: política común, vector KDF independiente Python/.NET, mayúsculas,
fallos persistidos tras reinicio, migración, reautenticación y rechazo de acceso
con registro corrupto; cliente web con proveedor simulado, caducidad, revocación
antes de limpieza y verificación de identidad antes de abrir datos. Se añaden
casos HTTP del agente y ventanas WinForms reales a Windows CI (5.1 y 7).

Las pruebas de navegador requieren Chromium, Leaflet, Chart.js y un servidor
local. Los dobles del proveedor se actualizan para getUser, sin eliminar su
verificación del código real. Una ejecución que no arranca no es un aprobado.
Consultar la PR para los resultados del commit exacto y las limitaciones.

Referencias primarias revisadas:
- https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html
- https://learn.microsoft.com/en-us/windows/win32/services/service-security-and-access-rights
- https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights
- https://supabase.com/docs/guides/auth/password-security
- https://supabase.com/docs/guides/database/postgres/row-level-security
- https://supabase.com/docs/reference/javascript/auth-signout

Límite del proveedor verificado en https://github.com/supabase/auth/blob/master/internal/api/password.go (MaxPasswordLength=72, len de Go en bytes).
