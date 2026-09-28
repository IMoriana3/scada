# SCADA online y Factiun Toolbox

Requisito del producto: toda mejora se evalúa e implementa en ambos entornos
cuando resuelve la misma necesidad. Un cambio común no se considera terminado
con una sola interfaz actualizada. Las diferencias justificadas se registran aquí.

SCADA online: `IMoriana3/factiun-cartera`, `seguimiento-pem.html`.
Toolbox: `IMoriana3/scada`, `tools/tcu-toolbox`. El visor `scada/index.html`
es otra superficie; no sustituye la revisión de la aplicación online.

## Entrega 11.94 / operations-v1

| Capacidad | Toolbox | Online | Estado y siguiente cierre |
|---|---|---|---|
| Calidad y procedencia | Conserva origen capturado, adquisición y edad del dato | Distingue diagnóstico importado, histórico y hora anclada | Criterio común: desconocido no equivale a OK ni a tiempo real |
| Gestión de intervención | Responsable, nota, abierto/en curso/cerrado; evidencia persistida al cerrar | Estados existentes; cierre de alarma usa la misma política y guarda diagnóstico y locator | Contrato y casos comunes; la inspección manual online se documenta como manual |
| Cierre verificado | Diagnóstico OK y adquisición + edad de origen <= 300 s | Misma regla; rechaza histórico, origen ambiguo y modificación concurrente del estado | Implementado; guardas de aplicación, no autorización de servidor ni prueba física |
| Acuse | Reconocimiento independiente | Acuse independiente | Un acuse no resuelve la avería |
| Histórico y tendencias | CSV original, ángulo/consigna, envolvente que conserva picos, huecos y PNG | Consulta CSV, varios días y comparación de equipos existentes | Parcial: faltan varios días y segunda TCU en Toolbox; no declarar paridad completa |
| Alta y topología | Importación guiada, IP/NCU/GW, solapes, cliente único y totales | Editor/exportador de topología existente | Falta validar ida y vuelta con todos los campos/plantas de un piloto |
| Identidad/ubicación | Locator capturado con planta, IP, NCU y equipo | Locator explícito por planta/NCU/equipo | No se crea asset_id a partir de nombres; vinculación con ubicación pendiente |
| Informes | HTML con calidad, alcance, responsable, estado y notas | Partes e informes existentes | Falta plantilla de entrega común y aprobación con cliente |
| Incidencias entre dispositivos | Registro local persistente | Registro compartido en servicio online | No existe aún sincronización bidireccional de los registros |
| Distribución y recuperación | Paquete de cliente sin plantas internas, manifiesto, instalación por versiones y retorno | Despliegue web del servicio existente | Diferencia de entorno; firma del editor y aceptación Windows/cliente pendientes |
| Demostración y soporte | Carpeta aislada, datos sintéticos, transporte bloqueado y paquete técnico sin datos de planta | Sin demostración aislada equivalente validada | Pendiente online; no confundir demo con ensayo de campo |
| Órdenes físicas | Control de rol y registro antes de enviar Modbus | No se habilitan órdenes remotas en esta entrega | Diferencia de seguridad y entorno; no copiar botones de movimiento sin arquitectura autorizada |

## Cómo mantenerlo

1. Incluir en cada PR el recorrido afectado, la contraparte y su PR/commit.
2. Cambiar el contrato y sus casos antes de divergir en estados, edades,
   unidades, alarmas, permisos o identidad. El original está en `scada/contracts`;
   `factiun-cartera/contracts` conserva la copia exacta revisada.
3. Ejecutar `node tests/test_operations_contract.js` en ambos repositorios y
   `test_client.ps1` en Toolbox. Comprobar las copias con
   `node tools/check_operations_parity.js /ruta/al/otro/repositorio`.
   Falta de contraparte o discrepancia devuelve error; no se descarga código ni
   se usan credenciales desde este control.
4. Revisar el recorrido real en Windows y navegador. Los vectores compartidos
   comprueban la política, no garantizan paridad de todas las pantallas.
5. Publicar ambos cambios comunes como una entrega coordinada. Una diferencia
   temporal debe tener motivo, impacto visible y tarea de cierre en esta tabla.

No se activa CI de pago en el repositorio privado. Sus pruebas se ejecutan
localmente y se adjunta el resultado a la PR. El control entre repositorios
necesita ambas copias disponibles; no se presenta como una protección de GitHub.

## Aceptación comercial aún pendiente

La edición es candidata a piloto acompañado. Requiere pruebas Windows/WinForms,
ensayo con firmware/equipos reales y operador externo, firma corporativa,
revisión de distribución/licencias y acuerdo de instalación/formación/soporte.
La matriz de firmware no constituye una certificación. Los logs locales no son
inmutables; falta completar valores previos/posteriores y verificación física
por operación. La política de cierre del navegador no sustituye las reglas de
autorización, concurrencia y auditoría del servidor.

## Acceso 11.95 / access-v1

| Capacidad | Toolbox | Online / agente | Estado |
|---|---|---|---|
| Nueva contraseña y cambio | 15–128, actual obligatoria, PBKDF2-SHA256/600k | Minimo comun; Supabase limita a 72 bytes UTF-8, actual verificada | Implementado en clientes; exigir política desde Supabase pendiente |
| Intentos fallidos | Cinco fallos / cinco minutos, persistidos | Límites del proveedor y perímetro | Configuración real online UNKNOWN; no sustituirla por un contador JS |
| Sesiones | Login local, reautenticación para administrar cuentas | sessionStorage, 15 min inactividad / 8 h UI; token agente solo en memoria | Caducidad del servidor y bloqueo local durante maniobras pendientes |
| Identidad y permisos | Archivos locales modificables por dueño del PC | Supabase y token de servicio compartido | Diferencia explícita; MFA, RLS por cliente/planta y agente con identidad individual pendientes |
| Funcionamiento sin Internet | Requisito obligatorio: acceso, cuentas, recuperación y operaciones autorizadas locales; servicio Windows protegido pendiente | La web mantiene su proveedor online | INTENCIONAL: la Toolbox no dependerá de login web ni renovaciones en la nube; no confundir requisito con protección ya implementada |
| Actualización | Conserva cuentas/limitador; bloquea retorno incompatible con hashes v2 | Se retiran tokens persistentes del navegador | La retirada local no revoca copias previas; rotación operativa pendiente |

No declarar seguridad comercial por tener login, roles visuales o este contrato.
Ver `docs/audit/ACCESS-SECURITY__scada.md`.

Diferencia INTENCIONAL: el proveedor online admite un maximo de 72 bytes UTF-8; se rechaza el exceso sin recortar. Toolbox admite hasta 128 caracteres. No se sustituye el hash del proveedor ni se crean contrasenas alternativas.
