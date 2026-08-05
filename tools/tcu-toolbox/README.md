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
| **Escribir** | Tabla de variables (todo el mapa 4xxxx: carga, calefactor, comunicaciones, geometría, umbrales, deadbands, safe positions, rangos de tilt, motor, SoC) con verificación tras escribir, reintentos, "reintentar fallidas" y guardado en NVM (40007 bit 15). Campo **Filtro**: escribe `soc`, `tilt`, `zigbee`… y el desplegable de variables se reduce a lo que casa (las filas ya elegidas nunca se pierden). Presets JSON y carga de un **backup como preset** (excluye comandos y fecha/hora). Botón **CSV por TCU...**: escribe valores distintos a cada TCU desde un CSV `TCU;variable;valor` (la variable admite nombre exacto o prefijo único, p. ej. `41010`). Los registros de comando piden **doble confirmación**. Al escribir, el log muestra por TCU el **valor que había antes** de cada variable (`nombre: antes → después`), tanto en la escritura por rango como en el CSV por TCU. |
| **Leer variable** | **Varias variables a la vez** en una **tabla igual que la de Escribir** (v5.2: una fila por variable, con su registro y su tipo al lado; antes era combo + Añadir + lista, que no pegaba con la pestaña de al lado). Admite además los registros de estado 3xxxx. Una columna por variable en el resultado en un rango de TCUs — o en la **Planta completa** (v4.1): recorre todas las NCUs en secuencia con sus rangos automáticos y añade la columna NCU a la vista y al CSV — con resumen de discrepancias por variable (cuántos TCU tienen cada valor, en toda la planta). Campo **Filtro** con contador de coincidencias (busca también en los registros `ESTADO …`), que reduce el desplegable sin perder nunca las filas ya elegidas. Si la **primera** variable de un TCU agota los reintentos sin respuesta, el TCU se da por mudo y no se prueban las demás (v5.2): con cinco variables, 8 s de timeout y 3 reintentos eso son ~24 s en vez de ~2 min por TCU muerto. Un fallo Modbus (dirección ilegal, etc.) no cuenta: ahí el equipo sí contesta y el resto se lee. Export CSV y, desde v4.8, la lectura entra también en el **INFORME HTML** con su resumen de discrepancias. |
| **Volcar TCU** | Todas las variables de un TCU (config + estado + identidad opcional). Export CSV y **backup JSON** con metadatos (planta, IP, TCU, fecha, versión de mapa). Botón **Comparar con backup JSON**: marca en naranja las diferencias con un volcado anterior — ideal para verificar una TCU recién sustituida. **BACKUP NCU**: vuelca todas las TCUs de un rango a una carpeta, un JSON por TCU, con marca de completitud — el seguro antes de tocar nada. |
| **Diagnóstico** | Por defecto en modo **"vía NCU" (rápido)**: lee el bloque compacto que la NCU cachea de sus TCUs (30500+, puerto 502) y sus HSUs (30200+) en lecturas TCP locales — segundos en vez de minutos, con `lastComm` como criterio de OFFLINE (igual que el SCADA) y **una fila por HSU** (viento, nieve, alarmas). Desmarcando "vía NCU" ataca los TCU en directo por Zigbee (más lento; añade las alarmas de hardware 30004/30005 que el bloque compacto no lleva). Escanea un rango de TCUs — o la **Planta completa**: al elegir la entrada "(Planta completa)" del desplegable recorre **todas sus NCUs en secuencia** (cada una con sus gateways y rangos propios; el campo **NCUs** filtra cuáles, p. ej. `1,3-5`) y añade la columna NCU a la vista y a los exports, incluyendo una **fila de salud por NCU** (GW1/GW2 desconectados, UPS, seta, reloj de la NCU — mapa R7.1, puerto 502) — y clasifica cada uno en `OK / AVISO / ALARMA / OFFLINE` con el **mismo criterio de salud que el SCADA** (eje bloqueado, sobrecorriente, batería crítica, seta, fuera de rango ⇒ alarma; resto de bits, `system_ok=0` o desviación >5° ⇒ aviso). El CSV exportado añade las **alarmas desglosadas en columnas 0/1** (filtrables en Excel). Botón **TEST COMM (rápido)** (v4.3): la prueba de campo más rápida — "¿quién habla y quién no?" de **todas las NCUs, TCUs y HSUs** de la selección (incluida la Planta completa). No lee el bloque compacto de cada TCU, solo los `lastComm` que la NCU cachea (2 registros por TCU, 50 TCUs por lectura) más la salud de la NCU: **4 lecturas Modbus por NCU de 75 TCUs en vez de 18**. Da OK / OFFLINE con la antigüedad del último dato, el listado de las mudas por NCU y el tiempo total; no da alarmas ni posiciones (para eso, DIAGNOSTICAR). Su export JSON se marca como `test_comm` para no confundirlo con un diagnóstico en el histórico. Tras el escaneo, la consola imprime el **resumen general por NCU** y la fila **Ver** permite **filtrar la vista del resultado** por NCU y por salud con **casillas que se pueden marcar a la vez** (p. ej. ALARMA + OFFLINE; ninguna marcada = todas) **sin relanzar lecturas** — los exports CSV/JSON llevan siempre el diagnóstico completo. La vista muestra lo esencial de campo: **modo (OFF/MANUAL/AUTO)**, **posición real/objetivo/desviación**, **SoC** y las **alarmas decodificadas bit a bit en texto** (registros 30002–30005). El resto (SoH, tensiones, temperaturas, registros hex) viaja igualmente en el export CSV/JSON. |
| **PEM** | La pestaña de puesta en marcha. **TEST DE MOTOR** por rango: cada TCU pasa a MANUAL, pulsa Oeste y Este midiendo Δángulo y corriente, vuelve a su modo, y da veredicto **PASA / FALLA (no se mueve, sin corriente, sentido invertido) / DUDOSO** — con **guardia de viento** (consulta las HSU vía NCU y se bloquea si hay nivel > 0), parada de motor garantizada y TCUs con alarma crítica saltados. **APLICAR MODO** (OFF/MANUAL/AUTO) y **LIMPIAR ALARMAS** (reset de las alarmas enclavadas, 40007 bit 13) masivos con verificación por efecto en 30001/30006. **STOW / QUITAR STOW** (42000) con verificación de la safe position activa. **Comisionado**: leer el estado (30001 bits 4:3: Factory → Configurado → Motor verificado → COMISIONADO) por rango — o de la **Planta completa vía NCU** (los bits van en el registro de estado que la NCU cachea en su bloque compacto: toda la planta en segundos, sin Zigbee, con columna NCU y los TCUs offline marcados) — y fijarlo (40000 bits 7:5). Todo exportable a CSV. |
| **HSU** | La estación meteo. Botón **BUSCAR HSUs** (v4.0): escanea las NCUs de la selección (Planta completa, (auto) o una entrada suelta) leyendo el bloque compacto que cada NCU cachea (30200+, puerto 502) y lista **qué HSUs hay y de qué NCU cuelga cada una**, con su salud y su viento/nieve; el desplegable permite elegir una — fija su IP y su esclavo si la topología lo trae — o "(todas)" para ver el resumen conjunto. **LEER METEO** y **LEER CONFIG** funcionan sobre **todas las HSUs de la planta de una pasada** (v5.3): con "(todas)" en el desplegable recorren cada una por la IP y el gateway de su NCU, con una cabecera por HSU en la tabla, las mudas marcadas y un resumen de cuántas respondieron y cuántas tienen alarma o viento; LEER CONFIG avisa además si alguna HSU lleva **umbrales distintos** de las demás. Las escrituras (umbrales, reloj, nieve, NVM) siguen pidiendo una HSU concreta a propósito. Las operaciones directas van por su esclavo Modbus (default 185, editable; se preselecciona desde la topología si el fichero de plantas trae `hsu_esclavo`): **meteo en vivo** (viento m/s y km/h, dirección, nieve, lluvia, T/HR, irradiancia) con **alarmas decodificadas**; **config y umbrales de viento** (leer y escribir, con confirmación de seguridad y verificación); **reloj UTC**; **calibración del cero de nieve**; **NVM**; y la **caja negra de 24 h** (viento medio/máx, nieve e irradiancia minuto a minuto) descargada a CSV — para investigar un stow después de que pase. |
| **Flota** | **Auditoría**: compara un rango de TCUs contra un *preset de referencia* (un preset o un backup completo) y lista **solo las desviaciones** (esperado vs leído), con export CSV — el "¿está toda la NCU igual?" en un clic. **Inventario**: FW principal/fábrica, nº de serie, MAC Xbee, HW y fecha de fabricación de todo el rango, con aviso si hay firmwares mezclados y export CSV. Ambas aceptan también la entrada **"(Planta completa)"**: recorren todas las NCUs en secuencia con sus rangos automáticos (los campos de TCU muestran NA) y añaden la columna NCU a la vista, al CSV y al informe HTML. |
| **Firmware** | Planifica la **campaña de actualización** (v4.4). La toolbox **no** actualiza firmware — eso lo hace el *TCU Updater* de Sunner — pero resuelve lo caro: a partir del último **Inventario** y de una **versión objetivo**, lista las TCUs pendientes agrupadas en tramos `desde-hasta` **por NCU y gateway**, que es justo lo que pide el updater (*Add from … to …*). Cada tramo es un **carril**: el updater admite varias ventanas a la vez, una por NCU+gateway, así que la campaña se divide por el número de carriles (con 20 min/TCU, Ayora pasa de ~250 h en serie a las horas del carril más cargado). Muestra la estimación en serie y en paralelo, marca las TCUs que no respondieron al inventario (no se puede actualizar lo que no comunica), exporta el plan a CSV y, al terminar, **VERIFICAR TRAS ACTUALIZAR** relee el FW de las TCUs del plan y dice cuáles subieron y cuáles siguen pendientes. |
| **Utilidades** | **Sincronizar reloj**: escribe la hora del PC en un rango de TCUs (40001–40006 + secuencia 40007 bit0→bit1) y verifica leyendo el reloj real (30079). **Identificación**: FW principal/fábrica, MCU secundario, BQ, HW, Xbee HW/FW, **MAC Xbee**, **número de serie**, fecha de fabricación y lote (bloque 30300+). |

Consola común con colores, botón **CANCELAR** para abortar operaciones largas, y **log automático** a `logs/tcu_toolbox_AAAAMMDD.log`. La ventana es **redimensionable y maximizable** (v4.6): al agrandarla crecen las tablas y la consola, que es lo que interesa en una planta de cientos de TCUs.

**Maquetación de la ventana (v5.1)** — corregida una regresión del tema de la v5.0: los botones pegados al borde derecho (**Añadir** en Leer variable, **LEER**, **Exportar CSV**, **SINCRONIZAR**, **Cargar preset…**) desaparecían, y las tablas quedaban más largas que su pestaña con la barra de desplazamiento por debajo del borde. Los anclajes se calculaban antes de que la ventana estuviera visible, cuando las pestañas que no están seleccionadas todavía no tienen su tamaño definitivo. Ahora se aplican con la ventana ya mostrada, con una guarda que no ancla nada contra un contenedor que no mide lo que debería, y una pasada final que devuelve a su sitio cualquier control que hubiera quedado fuera.

**HSU en Planta completa (v5.1)** — las operaciones directas de HSU (meteo, config, umbrales, reloj, nieve, NVM, caja negra) ya no exigen cambiar la entrada de conexión: si has elegido una HSU en el desplegable de **BUSCAR HSUs**, el programa ya sabe de qué NCU cuelga y usa su IP y el primer gateway de esa NCU, avisando en consola de cuál ha cogido (si cuelga del otro, se pone el puerto a mano).

**Fechas en dd/mm/aaaa (v5.1)** — la fecha de fabricación se pintaba `aa-mm-dd` (`25-06-18`), que se lee como fecha americana. Ahora va como `18/06/2025` en la vista, el CSV, el JSON y el informe.

**Respuestas descolocadas de la NCU (v5.0)** — corregido un fallo de datos serio. Cuando un TCU no contestaba a tiempo, la NCU respondía `GatewayTargetNoResponse` y **después** podía soltar la respuesta tardía del TCU, sellada con el identificador de transacción de la petición que estuviera en curso. Como el identificador cuadraba, la toolbox la daba por buena: a partir de ahí iba **una respuesta por detrás** y cada variable mostraba el valor de la anterior — `41106 east_pitch [m]` con los 0,95993 radianes de `41111 max_tilt` en vez de 6, `min_tilt [deg]` con 343,775 (los 6 m leídos como radianes)… valores plausibles pero falsos, y sin ningún aviso. Ahora, tras cualquier fallo que pueda dejar una trama en camino (timeout, socket roto, o las excepciones de gateway 0x0A/0x0B), la conexión se marca sucia y **se rehace antes de la siguiente petición**, que es la única forma de garantizar que respuesta y petición vuelven a cuadrar. Además, antes de cada petición se vacía lo que hubiera esperando en el socket (con aviso en consola), se comprueba que el código de función de la respuesta es el que se pidió y que trae **exactamente** el número de registros solicitado. Hay prueba de regresión: el simulador reproduce una NCU que va una respuesta por detrás, y sin el arreglo la lectura sale con los valores corridos.

**Aspecto (v5.0)**: la ventana lleva un tema propio — tipografía Segoe UI, fondo claro con los grupos como tarjetas blancas de filete fino, pestañas planas con subrayado azul en la activa, tablas sin cuadrícula con cabecera en versalitas y filas alternas, botones planos (los de acción conservan su color: verde escribir, azul leer, naranja NVM/stow, rojo cancelar) y la consola con la misma paleta oscura que la plataforma web. El tema **solo cambia colores, fuentes y bordes**: no mueve ni un control, así que cada pestaña está donde siempre. Es un tema claro a propósito, porque las filas de las listas se colorean por salud (verde/ámbar/rojo) sobre fondo blanco. Si en algún PC no convence, se vuelve al aspecto anterior añadiendo `"tema": "clasico"` a `config_local.json` — sin tocar el script.

Además, transversales a las pestañas (v3.1):

- **INFORME HTML** (barra inferior): vuelca a un informe HTML autocontenido todo lo hecho en la sesión — diagnóstico de flota, resultados de PEM, auditoría, inventario y, desde v4.8, la **lectura de variables** de la pestaña *Leer variable* (una columna por variable leída, con el mismo **resumen de discrepancias** que la pestaña: qué variables coinciden en todas las TCUs y cuáles tienen valores distintos y en cuántas TCUs cada uno). Cada sección lleva además la **hora en que se hizo**, así que se ve de un vistazo qué es de esta sesión y qué venía de antes — antes, si solo se había leído una variable, el informe sacaba el diagnóstico anterior y parecía que ignoraba la lectura. Con metadatos (planta, IP, fecha, técnico, versiones) y filas coloreadas por estado. Cada tabla lleva una **fila de filtros por columna** (desplegable de valores exactos, o caja "contiene" si hay muchos valores — p. ej. mismas alarmas, misma versión de FW) con contador de filas visibles, y **orden con un clic en la cabecera** (numérico o alfabético, con flecha ▲/▼ indicando por qué columna va). Todo en JS embebido: sigue funcionando sin red, y desde v4.2 también en navegadores antiguos (Internet Explorer / Edge en modo compatibilidad), donde antes el script no llegaba a ejecutarse y por eso la ordenación no respondía. Se guarda en `informes/` y se abre solo: el entregable de la jornada de puesta en marcha.
- **Rollback automático** en escrituras masivas (>3 TCUs, tanto en Escribir como en CSV por TCU): antes de tocar nada se leen los valores actuales y se guardan en `backups/rollback_<fecha>.csv` con formato `TCU;variable;valor` — restaurable tal cual con el botón **CSV por TCU...**. Los registros de comando se excluyen del rollback (reescribirlos relanzaría órdenes). Si el rollback no se puede crear, la toolbox pregunta antes de seguir sin él.
- **Mini-registrador** (Diagnóstico → **BUCLE CSV**): repite el diagnóstico cada X minutos y acumula cada pase (con fecha/hora y las alarmas desglosadas en columnas) en `informes/registro_<fecha>.csv`. Se para con CANCELAR. Para vigilar una TCU intermitente o una tarde de viento sin quedarse mirando.
- **Recordar sesión**: al cerrar se guarda `config_local.json` (planta, IP, puerto, timeout, reintentos, esclavo HSU) y al arrancar se restaura — el PC de planta arranca ya apuntando a su planta.

## Pruebas

`tests/` lleva un simulador Modbus TCP y **243 comprobaciones** de toda la lógica no-GUI, para poder tocar el script sin planta delante:

```bash
cd tests && python3 mb_server.py &
pwsh -NoProfile -File test_toolbox.ps1
```

Entre ellas, la regresión del fallo de las **respuestas descolocadas**: el esclavo 77 del simulador imita una NCU que va una respuesta por detrás, y sin la resincronización la lectura sale con los valores corridos. Detalle en `tests/README.md`.

## Seguimiento PEM (v3.4)

El seguimiento de puesta en marcha de una planta tiene tres piezas:

- **Ficha Excel automática**: `python make_seguimiento.py plantas/<planta>.json` genera `Seguimiento_PEM_<planta>.xlsx` — hoja Resumen con el % de avance por NCU (se calcula sola) y una pestaña por NCU con sus TCUs reales (número y gateway desde la topología), las tres tareas por TCU (*Cold commissioning / Configuración TCU / Prueba movimiento*, desplegable OK/NOK/N.A. con colores), HSUs, fecha, técnico y observaciones. La release de GitHub **adjunta una ficha por planta ya generada** (se regeneran solas en cada release).
- **Exportar desde la toolbox**: botón **SEGUIMIENTO JSON** (pestaña PEM). Combina lo medido en la sesión — **LEER ESTADO** de comisionado → *Cold commissioning*, **Auditoría** de Flota → *Configuración TCU*, **TEST DE MOTOR** → *Prueba movimiento* — en un `seguimiento_pem_<planta>_<fecha>.json` con una fila por TCU (OK / NOK / pendiente + observaciones).
- **Subirlo a la plataforma**: ese JSON se sube en la página **Histórico** de factiun-cartera (mismo botón que los diagnósticos): queda guardado por planta con su % de TCUs al 100 % y **diff contra el seguimiento anterior** (qué tareas se completaron o se rompieron entre visitas).

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

Diagnóstico (`Diagnóstico → JSON`): igual, con `"tipo": "diagnostico_tcu"` y una lista `tcus` con salud, ángulos, batería y alarmas en texto por TCU.

**Todos los JSON de la toolbox se suben al Histórico de la plataforma** (`historico.html` en factiun-cartera), que guarda la evolución por planta en Supabase y calcula el diff contra el registro anterior del mismo tipo (v3.6):

| Tipo | Botón | Diff en la plataforma |
|---|---|---|
| `diagnostico_tcu` | Diagnóstico → JSON | qué TCUs empeoran/mejoran de salud |
| `seguimiento_pem` | PEM → SEGUIMIENTO JSON | qué tareas se completan o se rompen |
| `inventario_tcu` | Flota → Inventario → JSON | cambios de FW y TCUs sustituidas (cambio de nº de serie) |
| `auditoria_tcu` | Flota → Auditoría → JSON | desviaciones nuevas, resueltas y cambiadas (avisa si el preset difiere) |

## Campaña de firmware y captura del protocolo OTA

El firmware de las TCUs lo actualiza el **TCU Updater de Sunner** (Rust + Modbus TCP, GUI sin línea de comandos): pide *NCU IP* y *Gateway port*, reinicia la TCU a bootloader y sube el binario por bloques con CRC32, con reanudación desde dirección. Tarda **~20 min por TCU y va de una en una**, así que una planta grande es inviable en serie (754 TCUs ≈ 250 h).

Lo que aporta la toolbox, sin tocar el firmware:

1. **A quién hay que actualizar**: Inventario → pestaña **Firmware** → plan por NCU y gateway.
2. **Cuántas ventanas lanzar**: cada tramo es un carril independiente (NCU + gateway = red Zigbee distinta). El updater no tiene bloqueo de instancia única: se pueden abrir varias a la vez, una por carril, y la campaña se divide por ese número.
3. **Qué subió de verdad**: VERIFICAR TRAS ACTUALIZAR + un Inventario nuevo, cuyo **diff** en el Histórico de la plataforma deja constancia de qué TCUs pasaron de una versión a otra.

### Actualizar (o capturar) en una planta en producción

⚠️ Durante la actualización la TCU se reinicia **en modo bootloader**: unos 20 minutos en los que **no sigue al sol ni obedece un stow**. Si entra viento en ese rato, ese seguidor no se pone en seguridad. Por eso el botón **PREPARAR 1 TCU (captura OTA)** de la pestaña Firmware, que antes de tocar nada:

1. Consulta las **HSU vía NCU** y avisa si hay viento (nivel > 0 o alarma) — el momento equivocado para dejar una TCU sorda.
2. Comprueba **vía NCU** que esa TCU comunica, que no tiene alarma crítica y que el **SoC no es bajo** (si la batería cae a mitad del OTA, se queda a medias).
3. Hace un **backup completo previo** (`backups/pre_ota_ncu<n>_tcu<n>_<fecha>.json`) anotando el firmware actual.
4. Imprime los datos exactos para el updater (IP de NCU, puerto de gateway, nº de TCU) y el comando listo del proxy de captura.

Recomendación para la primera vez: una TCU **que ya toque actualizar**, que comunique bien, con SoC alto, con viento en calma y con alguien pudiendo ir al seguidor. Si el proxy o el updater se cortan a mitad, el updater soporta reanudar desde la última dirección (*Continuing OTA from address*), pero mejor no estrenarlo con viento.

**`TCU_ProxyOTA.ps1`** — capturador del protocolo OTA, paso previo a cualquier actualizador propio:

```powershell
.\TCU_ProxyOTA.ps1 -Ncu 10.100.1.52 -Puerto 503     # y en el updater: NCU IP 127.0.0.1, port 5020
```

Se coloca entre el updater y la NCU, **reenvía byte a byte sin modificar nada** y registra cada trama Modbus (sentido, unit = nº de TCU, función, dirección, nº de registros y hex) en `capturas/ota_<fecha>.csv`, con un resumen de las direcciones escritas (candidatas al bloque OTA). Con una TCU en banco y una actualización completa capturada queda documentado un protocolo que no está en ningún mapa — imprescindible para diagnosticar por qué una TCU falla siempre al actualizar, y requisito previo para un OTA nativo (que además necesitaría el visto bueno de Sunner sobre los binarios de firmware).

## Seguridad

- Los registros de **comando** (40000, 40007, 40017, 40018, 42000) pueden mover el seguidor o cambiar su modo: la toolbox los marca `[COMANDO]`, pide una **segunda confirmación** y los **excluye** al restaurar un backup.
- "Verificar tras escribir" relee cada registro y compara (en escrituras por máscara compara solo el byte/bit escrito). Además se validan los **rangos min/max documentados en el mapa** (jeita 233–398 K, duties 0–250, rampas 4–82…): un valor fuera de rango ni se envía.
- El guardado en **NVM** es una operación aparte, con su propia confirmación.
- Los ángulos `f32` viajan en **radianes** por Modbus; la toolbox trabaja **siempre en grados** (tipo `f32deg`) y convierte en ambos sentidos, con guardarraíl (±360°). Lo que **no** es un ángulo no se convierte: `west_pitch`/`east_pitch` (separación entre ejes) y `panel_width` son metros (`f32`), y los pulsos, mV o Kelvin van tal cual. La unidad que ves entre corchetes en el nombre es siempre la unidad **mostrada**.
- ⚠️ Errata del manual v6.1: la fila de **41106 east_pitch** dice "Radians 0..π/4", heredado de la fila de arriba; es una distancia como su gemela 41033 (Meters). Confirmado en campo — Ayora lee 6, que en radianes serían 344°, imposible en un campo cuyo máximo declarado es 45°.
- Los registros de configuración con nombre `[hex]` (máscaras de bits: `tracker_options`, `safe_pos_options`, `zigbee_config`…) se **muestran en hexadecimal** como los de estado, y al escribir admiten tanto `0x0A00` como `2560`.

## Notas técnicas

- Las variables de los desplegables van en **orden ascendente por número de registro**; el filtro busca por subcadena sin distinguir mayúsculas y sin interpretar `[ ] * ?` como comodines.
- Modbus TCP con framing MBAP propio (sin dependencias): FC03 lectura, FC16 escritura múltiple, FC22 mask-write para bytes y bits sueltos.
- Tipos soportados: `u16, s16, u16hex, u32, u32hex, f32, f32deg, u8lo, u8hi, bit, dt_bcd (fecha BCD 3 regs), charger, serial`.
- F32/U32 en orden *little-endian word swap* (2-1-4-3) según el mapa: registro N = palabra baja.
- Ante un timeout o socket roto reconecta y reintenta; ante una excepción Modbus (dirección ilegal, gateway sin respuesta…) reintenta sin reconectar.
- Si alguna planta necesitara offset Modicon en las direcciones, se cambia en un solo sitio (`Dir-Trama`).
