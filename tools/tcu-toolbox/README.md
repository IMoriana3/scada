# TCU Toolbox — configuración y diagnóstico de TCUs Sunner (offline)

> Herramienta de campo para O&M: escribe, lee, respalda y diagnostica los TCU de los seguidores a través del gateway Modbus TCP de la NCU. **100 % offline**: un `.ps1` + un `.bat`, sin instalar nada (PowerShell viene con Windows), sin red fuera de la LAN de planta.

Es el complemento de **escritura** del SCADA de este repo: el SCADA es solo-lectura a propósito; cuando hay que *cambiar* algo en un TCU (configuración, reloj, NVM) se usa esta toolbox desde el portátil conectado a la LAN de planta.

## Arranque

1. Copia la carpeta `tcu-toolbox/` al portátil de campo (los JSON de plantas van dentro, en `plantas/`).
2. Doble clic en `TCU_Toolbox.bat` (no requiere admin).
3. Elige planta (o rellena IP/puerto a mano) y usa las pestañas.

Mapas de registros: **SUNNER TCU v6.1 (FW v1.4.3)**, **NCU R7.1** (salud de la NCU: puerto 502, unit 1) y **HSU R23** (estación meteo). La NCU actúa de gateway: el *unit id* Modbus es el número de TCU; en El Burgo el passthrough escucha en los puertos 503 (GW1) y 504 (GW2) de cada NCU.

### Entradas "(auto)": adiós al error de puerto

Cuando una NCU tiene varios gateways, el desplegable ofrece además una entrada **"… (auto)"** que cubre la NCU completa: la toolbox resuelve sola el puerto de cada TCU según los rangos (p. ej. en El Burgo NCU1, la TCU 30 va al 503 y la 80 al 504) y recorre los gateways **en secuencia** en las operaciones por rango (Escribir, Leer, Diagnóstico, Reloj, NVM). Los TCU que no caen en ningún gateway (p. ej. el hueco 108 de NCU2) se saltan con aviso. Nota de campo: la **TCU 109 de NCU2** está declarada como fila suelta del GW2 — rangos sacados de los `.bat` de Sunner, pendiente de confirmar en planta.

## Pestañas

| Pestaña | Qué hace |
|---|---|
| **Escribir** | Tabla de variables (todo el mapa 4xxxx: carga, calefactor, comunicaciones, geometría, umbrales, deadbands, safe positions, rangos de tilt, motor, SoC) con verificación tras escribir, reintentos, "reintentar fallidas" y guardado en NVM (40007 bit 15). Campo **Filtro**: escribe `soc`, `tilt`, `zigbee`… y el desplegable de variables se reduce a lo que casa (las filas ya elegidas nunca se pierden). Presets JSON y carga de un **backup como preset** (excluye comandos y fecha/hora). Botón **CSV por TCU...**: escribe valores distintos a cada TCU desde un CSV `TCU;variable;valor` (la variable admite nombre exacto o prefijo único, p. ej. `41010`). Los registros de comando piden **doble confirmación**. |
| **Leer variable** | **Varias variables a la vez** (lista con Añadir/Quitar; una columna por variable) en un rango de TCUs, con resumen de discrepancias por variable (cuántos TCU tienen cada valor). Campo **Filtro** con contador de coincidencias (busca también en los registros `ESTADO …`). Export CSV. |
| **Volcar TCU** | Todas las variables de un TCU (config + estado + identidad opcional). Export CSV y **backup JSON** con metadatos (planta, IP, TCU, fecha, versión de mapa). Botón **Comparar con backup JSON**: marca en naranja las diferencias con un volcado anterior — ideal para verificar una TCU recién sustituida. **BACKUP NCU**: vuelca todas las TCUs de un rango a una carpeta, un JSON por TCU, con marca de completitud — el seguro antes de tocar nada. |
| **Diagnóstico** | Por defecto en modo **"vía NCU" (rápido)**: lee el bloque compacto que la NCU cachea de sus TCUs (30500+, puerto 502) y sus HSUs (30200+) en lecturas TCP locales — segundos en vez de minutos, con `lastComm` como criterio de OFFLINE (igual que el SCADA) y **una fila por HSU** (viento, nieve, alarmas). Desmarcando "vía NCU" ataca los TCU en directo por Zigbee (más lento; añade las alarmas de hardware 30004/30005 que el bloque compacto no lleva). Escanea un rango de TCUs — o la **PLANTA completa**: al elegir la entrada "(PLANTA completa)" del desplegable recorre **todas sus NCUs en secuencia** (cada una con sus gateways y rangos propios; el campo **NCUs** filtra cuáles, p. ej. `1,3-5`) y añade la columna NCU a la vista y a los exports, incluyendo una **fila de salud por NCU** (GW1/GW2 desconectados, UPS, seta, reloj de la NCU — mapa R7.1, puerto 502) — y clasifica cada uno en `OK / AVISO / ALARMA / OFFLINE` con el **mismo criterio de salud que el SCADA** (eje bloqueado, sobrecorriente, batería crítica, seta, fuera de rango ⇒ alarma; resto de bits, `system_ok=0` o desviación >5° ⇒ aviso). El CSV exportado añade las **alarmas desglosadas en columnas 0/1** (filtrables en Excel). Tras el escaneo, la consola imprime el **resumen general por NCU** y la fila **Ver** permite **filtrar la vista del resultado** por NCU y por salud (todas / solo problemas / ALARMA / AVISO / OFFLINE / OK) **sin relanzar lecturas** — los exports CSV/JSON llevan siempre el diagnóstico completo. La vista muestra lo esencial de campo: **modo (OFF/MANUAL/AUTO)**, **posición real/objetivo/desviación**, **SoC** y las **alarmas decodificadas bit a bit en texto** (registros 30002–30005). El resto (SoH, tensiones, temperaturas, registros hex) viaja igualmente en el export CSV/JSON. |
| **PEM** | La pestaña de puesta en marcha. **TEST DE MOTOR** por rango: cada TCU pasa a MANUAL, pulsa Oeste y Este midiendo Δángulo y corriente, vuelve a su modo, y da veredicto **PASA / FALLA (no se mueve, sin corriente, sentido invertido) / DUDOSO** — con **guardia de viento** (consulta las HSU vía NCU y se bloquea si hay nivel > 0), parada de motor garantizada y TCUs con alarma crítica saltados. **APLICAR MODO** (OFF/MANUAL/AUTO) y **CLEAR ALARMAS** (40007 bit 13) masivos con verificación por efecto en 30001/30006. **STOW / QUITAR STOW** (42000) con verificación de la safe position activa. **Comisionado**: leer el estado (30001 bits 4:3: Factory → Configurado → Motor verificado → COMISIONADO) por rango y fijarlo (40000 bits 7:5). Todo exportable a CSV. |
| **HSU** | La estación meteo, por su esclavo Modbus (default 185, editable; se preselecciona desde la topología si el fichero de plantas trae `hsu_esclavo`): **meteo en vivo** (viento m/s y km/h, dirección, nieve, lluvia, T/HR, irradiancia) con **alarmas decodificadas**; **config y umbrales de viento** (leer y escribir, con confirmación de seguridad y verificación); **reloj UTC**; **calibración del cero de nieve**; **NVM**; y la **caja negra de 24 h** (viento medio/máx, nieve e irradiancia minuto a minuto) descargada a CSV — para investigar un stow después de que pase. |
| **Flota** | **Auditoría**: compara un rango de TCUs contra un *preset de referencia* (un preset o un backup completo) y lista **solo las desviaciones** (esperado vs leído), con export CSV — el "¿está toda la NCU igual?" en un clic. **Inventario**: FW principal/fábrica, nº de serie, MAC Xbee, HW y fecha de fabricación de todo el rango, con aviso si hay firmwares mezclados y export CSV. Ambas aceptan también la entrada **"(PLANTA completa)"**: recorren todas las NCUs en secuencia con sus rangos automáticos (los campos de TCU muestran NA) y añaden la columna NCU a la vista, al CSV y al informe HTML. |
| **Utilidades** | **Sincronizar reloj**: escribe la hora del PC en un rango de TCUs (40001–40006 + secuencia 40007 bit0→bit1) y verifica leyendo el reloj real (30079). **Identificación**: FW principal/fábrica, MCU secundario, BQ, HW, Xbee HW/FW, **MAC Xbee**, **número de serie**, fecha de fabricación y lote (bloque 30300+). |

Consola común con colores, botón **CANCELAR** para abortar operaciones largas, y **log automático** a `logs/tcu_toolbox_AAAAMMDD.log`.

Además, transversales a las pestañas (v3.1):

- **INFORME HTML** (barra inferior): vuelca a un informe HTML autocontenido todo lo hecho en la sesión — diagnóstico de flota, resultados de PEM, auditoría e inventario — con metadatos (planta, IP, fecha, técnico, versiones) y filas coloreadas por estado. Se guarda en `informes/` y se abre solo: el entregable de la jornada de puesta en marcha.
- **Rollback automático** en escrituras masivas (>3 TCUs, tanto en Escribir como en CSV por TCU): antes de tocar nada se leen los valores actuales y se guardan en `backups/rollback_<fecha>.csv` con formato `TCU;variable;valor` — restaurable tal cual con el botón **CSV por TCU...**. Los registros de comando se excluyen del rollback (reescribirlos relanzaría órdenes). Si el rollback no se puede crear, la toolbox pregunta antes de seguir sin él.
- **Mini-registrador** (Diagnóstico → **BUCLE CSV**): repite el diagnóstico cada X minutos y acumula cada pase (con fecha/hora y las alarmas desglosadas en columnas) en `informes/registro_<fecha>.csv`. Se para con CANCELAR. Para vigilar una TCU intermitente o una tarde de viento sin quedarse mirando.
- **Recordar sesión**: al cerrar se guarda `config_local.json` (planta, IP, puerto, timeout, reintentos, esclavo HSU) y al arrancar se restaura — el PC de planta arranca ya apuntando a su planta.

## Vínculo con la plataforma (sin dejar de ser offline)

- **Mismo programa para todas las plantas, un fichero por planta**: el desplegable muestra **solo** las plantas de los ficheros cargados (no hay lista integrada en el script). Al arrancar se cargan todos los JSON/CSV de la subcarpeta `plantas/`, más un `plantas.json`/`plantas.csv` clásicos si existen; el botón **Cargar...** **reemplaza** la lista por las NCUs del fichero que elijas (y ofrece guardarlo en `plantas/` para próximas sesiones) — quita de `plantas/` los ficheros de plantas que no quieras ver. Así el programa nunca cambia por añadir plantas: solo se descargan ficheros. El CSV (separado por `;`, editable desde Excel sin necesitar Office en el PC de campo) usa una fila por gateway:

  ```
  Planta;NCU;IP;Puerto;TCU_ini;TCU_fin
  El Burgo I;NCU1;10.100.1.52;503;1;56
  El Burgo I;NCU1;10.100.1.52;504;57;108
  ```

  La fuente de verdad es el mismo `config/plants.yml` que usa el collector del SCADA: cada NCU declara ahí sus gateways passthrough (clave `gateways`, que el collector ignora):

  ```yaml
  gateways:
    - { puerto: 503, tcu_ini: 1,  tcu_fin: 56 }
    - { puerto: 504, tcu_ini: 57, tcu_fin: 108 }
  ```

  Un workflow de GitHub Actions (`.github/workflows/plantas-toolbox.yml`) regenera y commitea `plantas/<id_planta>.json` automáticamente en cada cambio de `plants.yml`. **No edites esos JSON a mano**: cambia `plants.yml` y deja que se regeneren (o lanza `python make_plantas.py` en local). Cada despliegue del SCADA (una planta) aporta su fichero; en el portátil de campo se pueden acumular los de varias plantas en `plantas/`.

- **Tabla de topología editable (recomendado para el resto de plantas)**: la hoja "Direcciones IP" del Excel maestro vive como tabla web editable en **factiun-cartera** (`ips.html`, "IPs de plantas", mismo login que la cartera). Sus botones **⬇ JSON toolbox** / **⬇ CSV toolbox** descargan los ficheros de plantas en el formato exacto de esta herramienta — solo topología, nunca credenciales. Alternativa offline: `python make_plantas.py --excel <Excel> [--excluir 23003]` lee esa misma hoja y genera `plantas/<nº>-<planta>.json` (⚠️ el Excel lleva contraseñas: **no subirlo nunca a este repo**, que es público; solo los JSON generados).

- **Exportes canónicos**: los backups (`{"tipo":"backup_tcu", ...}`) y diagnósticos (`{"tipo":"diagnostico_tcu", ...}`) llevan planta, IP, TCU, fecha y versión de mapa, de modo que cualquier pieza de la plataforma (SCADA, gemelo, informes) puede ingerirlos sin ambigüedad.

- **Mismo modelo de salud**: la clasificación `ok/warn/alarm/offline` replica la del collector (`collector/decode.py`), así lo que ves en campo con la toolbox coincide con lo que pinta el SCADA en el plano.

Nada de esto requiere conexión: los ficheros viajan en el propio portátil o en un USB.

## Formatos

`plantas.json`:

```json
{ "version": 1, "plantas": [
  { "nombre": "El Burgo I NCU1 GW1", "ip": "10.100.1.52", "puerto": 503, "tcu_ini": 1, "tcu_fin": 56 }
] }
```

Backup (`Volcar TCU → Backup JSON`):

```json
{ "tipo": "backup_tcu", "mapa": "SUNNER v6.1 (FW 1.4.3)", "planta": "El Burgo I NCU1 GW1",
  "ip": "10.100.1.52", "puerto": 503, "tcu": 12, "fecha": "2026-08-04 10:31:00",
  "variables": [ { "variable": "41010 longitud [deg]", "valor": "-1.685", "grupo": "config" } ] }
```

Diagnóstico (`Diagnóstico → JSON`): igual, con `"tipo": "diagnostico_tcu"` y una lista `tcus` con salud, ángulos, batería y alarmas en texto por TCU. Estos JSON se pueden subir al **Histórico de diagnósticos** de la plataforma (`historico.html` en factiun-cartera): guarda la evolución por planta en Supabase y calcula el **diff contra el diagnóstico anterior** (qué TCUs empeoraron o mejoraron).

## Seguridad

- Los registros de **comando** (40000, 40007, 40017, 40018, 42000) pueden mover el seguidor o cambiar su modo: la toolbox los marca `[COMANDO]`, pide una **segunda confirmación** y los **excluye** al restaurar un backup.
- "Verificar tras escribir" relee cada registro y compara (en escrituras por máscara compara solo el byte/bit escrito). Además se validan los **rangos min/max documentados en el mapa** (jeita 233–398 K, duties 0–250, rampas 4–82…): un valor fuera de rango ni se envía.
- El guardado en **NVM** es una operación aparte, con su propia confirmación.
- Los ángulos `f32` viajan en radianes por Modbus; la toolbox trabaja **siempre en grados** y convierte en ambos sentidos, con guardarraíl (±360°).

## Notas técnicas

- Las variables de los desplegables van en **orden ascendente por número de registro**; el filtro busca por subcadena sin distinguir mayúsculas y sin interpretar `[ ] * ?` como comodines.
- Modbus TCP con framing MBAP propio (sin dependencias): FC03 lectura, FC16 escritura múltiple, FC22 mask-write para bytes y bits sueltos.
- Tipos soportados: `u16, s16, u16hex, u32, u32hex, f32, f32deg, u8lo, u8hi, bit, dt_bcd (fecha BCD 3 regs), charger, serial`.
- F32/U32 en orden *little-endian word swap* (2-1-4-3) según el mapa: registro N = palabra baja.
- Ante un timeout o socket roto reconecta y reintenta; ante una excepción Modbus (dirección ilegal, gateway sin respuesta…) reintenta sin reconectar.
- Si alguna planta necesitara offset Modicon en las direcciones, se cambia en un solo sitio (`Dir-Trama`).
