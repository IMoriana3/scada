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

## PROPUESTA para cerrar la seguridad comercial

1. Un proveedor de identidad para las cuentas nominales; MFA obligatorio para
   administrar, escribir y consultar secretos. Recuperación con identidad
   verificada, revocación y auditoría. No copiar contraseñas entre productos.
2. RLS y API con pertenencia explícita de usuario a cliente/plant_id y roles de
   lectura/técnico/administrador. Probar con dos clientes, roles y API directa.
   No deducir plant_id desde nombres o posiciones.
3. Sacar credenciales de VPN/NCU/GW de respuestas generales y exportaciones.
   Usar un almacén de secretos con permisos, rotación y registro de acceso.
4. Agente/servicio protegido que verifique identidad y autorización por orden,
   con credenciales de servicio propias, revocables y limitadas. El script
   editable y el token común no deben ser la frontera comercial.
5. Para operación sin conexión: permisos offline firmados, de alcance y duración
   acotados. Acordar el comportamiento al caducar durante una secuencia; no
   interrumpir a ciegas una maniobra ni presentar el bloqueo Windows como MFA.

DECISIÓN de entrega: mantener etiqueta de piloto. Elevar a MASTER la identidad
compartida, el alcance por planta y el servicio de autorización (06_PLANT,
05_CONTROL, 07_SCADA). No se han rotado credenciales reales, cambiado roles de
producción ni enviado órdenes físicas. Las propuestas anteriores no constan
como activadas.

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
- https://supabase.com/docs/guides/auth/password-security
- https://supabase.com/docs/guides/database/postgres/row-level-security
- https://supabase.com/docs/reference/javascript/auth-signout

Límite del proveedor verificado en https://github.com/supabase/auth/blob/master/internal/api/password.go (MaxPasswordLength=72, len de Go en bytes).
