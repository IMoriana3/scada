# Adquisición El Burgo I — propuesta de arranque (fase 0, sin código)

> Respuesta al prompt de arranque del SCADA de El Burgo I (13,96 MWp, proyecto 23003).
> Tres entregables: estructura de repo + contrato de dato, lista de documentos con la
> decisión que desbloquea cada uno, y supuestos del prompt que hay que revisar.
>
> **Nota previa:** el repo `imoriana3/scada-elburgo` no existe (o esta sesión no tiene
> acceso). Este documento va en `scada/docs/` como sitio provisional; la decisión
> repo-nuevo vs subdirectorio está en Supuestos frágiles, punto 9.

---

## 0. Lo que ya tenemos y el prompt daba por pendiente

Antes de pedir documentos, inventario de lo que ya está en los repos. Cambia el plan.

**`SolarGPTfull/Template Burgo I_01.xlsx`** — es, en gran parte, la "tabla de strings"
que el prompt anuncia como pendiente de subir:

- Hoja **NOMENCLATURA** (215 filas): `NCU · SLAVE · CT · INVERSOR · SEGUIDOR ·
  CONSTRUCCIÓN · INGENIERIA · TIPOLOGÍA`. Es exactamente la clave común entre las tres
  nomenclaturas que pide el prompt (`1.1.1` ↔ `TR C 1` ↔ `151` ↔ NCU 1 / esclavo 1),
  ya construida, **a nivel mesa**.
- Hoja **TCU** (219 filas): coordenadas UTM, TCU, NCU, IP de NCU, GW, esclavo, CT,
  inversor, nº seguidor, grupo, tipología.
- Hoja **STRING** (860 strings): nomenclatura `CT.INV.mesa.string` con 4 esquinas UTM
  por string. El string→mesa es implícito en la propia nomenclatura.

Números que salen de ahí (medidos sobre el fichero, no supuestos):

| Dato | Valor |
|---|---|
| Inversores | 36, en 2 CT × 18 (`I-1.1…1.18`, `I-2.1…2.18`) |
| Mesas por inversor | **29 inversores con 6 · 4 con 5 · 3 con 7** |
| Strings | 860 = 215 mesas × 4 strings |
| Strings por inversor | 20–28 (máx. admisible 30) ✓ |
| Tipologías de mesa | 112 interior sin rótula · 67 interior con rótula · 8+10 exterior · **18 CORTO** |
| Módulos por string | 28 (parámetro de la hoja STRING) |

**`cobertura-zigbee/`**: `elburgo_layout.json` (215 trackers + 36 rótulos de inversor +
redes del DWG — el plano para el mapa limpio/mixto ya existe), `elburgo_cotas.json`
(levantamiento topográfico medido: la base para elegir testigos "donde el terreno se
aparta del plano"), `elburgo_real.geojson` y `elburgo_zigbee_horario.json` (malla Zigbee
medida).

**`scada/`** (este repo): colector Modbus TCP→NCU completo (asyncio, driver enchufable,
InfluxDB, API), con lecciones ya pagadas que este proyecto hereda: hora del dato ≠ hora
de escritura, eventos como flancos, `comms_age` como resta NCU−NCU, medidor de tráfico,
bancos sin hierro.

**⚠️ Hecho medido que condiciona todo el plano seguidor** (README de `scada`, diagnóstico
contra la NCU-02 `10.100.1.56`): el firmware de las NCUs de El Burgo es **anterior al mapa
R7 y no expone telemetría por TCU vía Modbus** (lecturas a 30500/29500 → dirección ilegal;
Modbus vive en el puerto 503; direccionamiento exacto, sin offset −1). Hoy la única vía de
telemetría de seguidor con histórico es la **descarga nocturna de CSVs del webserver de la
NCU** (TCU cada ~10 s, NCU a 1 Hz; pieza ya hecha: `scada/tools/descarga_logs_ncu.py`), y
la retención de la NCU tiene huecos: **lo que no se baja cada día, se pierde**.

---

## 1. Estructura de repo y contrato de dato

### 1.1 Estructura propuesta

```
scada-elburgo/
├── README.md
├── CONTRATO.md               # interfaz con las otras sesiones (o alta en scada/CONTRATO.md)
├── config/
│   ├── planta.yml            # inventario: EMU, inversores POR DEVANADO y CT, NCUs, meteo, contadores
│   ├── sungrow_sg320hx.yml   # mapa Modbus del inversor — TODO(doc): Communication Protocol
│   ├── logger4000.yml        # direccionamiento tras el logger, sesiones, límites — TODO(doc): manual EMU200A
│   └── topologia/
│       ├── nomenclatura.csv  # generado del Excel: mesa ↔ inversor ↔ NCU/slave ↔ plano ↔ TCU_ID
│       ├── mppt_mesa.csv     # LA tabla: mppt_id → [mesa_ids], limpio|mixto — TODO(doc): string→conector MPPT
│       └── testigos.yml      # MPPT/strings testigo elegidos, cada uno con su motivo (borde/centro/relieve)
├── contracts/
│   ├── sample.md             # contrato de dato normativo (§1.2)
│   └── sample.schema.json    # validable en colector, bus e histórico
├── collector/
│   ├── main.py               # scheduler, sellado de hora, salud propia, backoff
│   ├── drivers/
│   │   ├── sungrow_logger.py # Modbus TCP → Logger4000 · SOLO LECTURA, sin código de escritura
│   │   ├── ncu_modbus.py     # reuso del de scada/ (cuando el firmware NCU exponga TCU)
│   │   └── simulated.py      # desarrollo sin hierro, como en scada/
│   └── publish.py            # MQTT/TLS, batching por dispositivo, reintentos
├── historian/
│   ├── writer.py             # suscriptor del bus → Parquet particionado (crudo, reprocesable)
│   └── hot.py                # hoja caliente: últimos N días para consulta rápida / HMI futura
├── tools/
│   ├── gen_topologia.py      # extractor: Excel + unifilares → nomenclatura.csv + mppt_mesa.csv
│   ├── mapa_limpio_mixto.py  # mapa de planta coloreado limpio vs mixto (sobre elburgo_layout.json)
│   ├── medir_cadencia.py     # comisionado: ¿cada cuánto refresca de verdad el logger cada registro?
│   └── test_*.py             # bancos sin hierro, mismo estilo que scada/tools/
└── docker-compose.yml        # mosquitto (TLS) + collector + historian
```

Decisiones que la estructura fija:

- **El mapa Modbus vive en YAML versionado, no en código** (patrón ya rodado en
  `scada/config/modbus_map.yml`): el banco compara el YAML contra el documento del
  fabricante, y la versión del mapa viaja en cada muestra (§1.2).
- **Driver simulado desde el día uno**: todo el pipeline (bus, histórico, bancos) se
  desarrolla y valida sin esperar al Communication Protocol.
- **`historian/` separado de `collector/`**: se hablan solo por el bus. Si el histórico
  cae, el colector no se entera; si el colector cae, el histórico lo nota por ausencia
  (métrica de salud), no por acoplamiento.
- **Escritura Modbus: no hay módulo.** No es un flag en `false`: el código no existe.

### 1.2 Contrato de dato (`Sample`)

Unidad de publicación: **bloque por dispositivo y ciclo** (no mensaje por señal — la
lección medida del repo scada: en mensajes pequeños mandan las cabeceras). Una muestra
individual es una fila del bloque.

```json
{
  "v": 1,
  "planta": "23003",
  "fuente": "logger4000",
  "dispositivo": "I-2.7",
  "ts": 1755772800123,
  "ts_fuente": null,
  "mapa": "sg320hx@a1b2c3d",
  "calidad": "ok",
  "senales": {
    "mppt1_corriente": { "val": 12.83, "raw": 1283 },
    "mppt1_tension":   { "val": 1180.0, "raw": 11800 }
  }
}
```

| Campo | Regla |
|---|---|
| `ts` | **Hora del dato en UTC (epoch ms), sellada por el colector al completar la lectura del bloque.** Nunca la hora de escritura ni la de reintento. Es el sello único que cruza eléctrico y seguidor: todo lo que entra por este colector lo pone el mismo reloj (host con NTP). |
| `ts_fuente` | La hora que declare el equipo, si la declara (reloj del logger, `lastComm` de NCU). No sustituye a `ts`: se publica para poder **medir la deriva** de cada fuente (`deriva_s = ts − ts_fuente`), no para usarla. Lección del bug `comms_age`: mezclar relojes en silencio dio una flota entera por offline. |
| `mapa` | Nombre + versión (git) del YAML con el que se decodificó. Con `raw` + `mapa`, cualquier cifra de una pantalla es trazable hasta registro, escalado y hora — y un escalado mal entendido se reprocesa del crudo, no se pierde. |
| `raw` | Valor de registro sin escalar. Siempre presente. |
| `val` | Valor en unidad de ingeniería. Unidades y escalados viven en el YAML del mapa, no en cada mensaje. |
| `calidad` | `ok · parcial · stale · sin_lectura`. Un bloque incompleto se publica como `parcial` con las señales que llegaron; la ausencia es dato (patrón `null` explícito, no omisión — como la API de scada). |
| `senales` | Los **nombres** canónicos los fija `contracts/`; los registros de origen, el YAML. `TODO(doc)`: la lista real sale del Communication Protocol. |

Topics MQTT: `elburgo/<plano>/<fuente>/<dispositivo>` con `plano ∈ dc | seguidor | meteo
| red | salud`. El colector publica también su propia salud (`salud/collector`): ciclo,
retardos, reintentos, sesiones — el histórico del colector es la primera herramienta de
depuración del histórico de la planta.

Histórico Parquet: partición `plano/fecha=YYYY-MM-DD/fuente=`, una fila por señal y
muestra (bloque aplanado), **sin agregados destructivos**. Los testigos (de
`config/topologia/testigos.yml`) se persisten a la cadencia máxima que dé el logger; el
resto puede diezmarse **en el historian y dejándolo anotado**, nunca en el colector — lo
que el colector no publica no existe.

### 1.3 La tabla `mppt → mesa`: estado real

Mejor de lo previsto. De la cadena `string → mesa → inversor → NCU/esclavo → plano →
nomenclatura de construcción`, **todo existe ya en el Excel**. Lo único que falta es
**string → conector/MPPT del inversor**, y eso es exactamente lo que hay que exigir al
as-built eléctrico. Con ese dato, `gen_topologia.py` cierra `mppt_mesa.csv` y el mapa
limpio/mixto sale solo (el plano ya está en `elburgo_layout.json`).

Lo que los números ya permiten afirmar (ver §2, supuesto 3): con mesas/inversor ∈
{5, 6, 7}, los tres inversores de 7 mesas tienen **al menos un MPPT mixto seguro**, y los
cuatro de 5 mesas pueden tener el caso inverso — una mesa repartida entre dos MPPT — que
también rompe la comparación por mesa y el prompt no contempla.

---

## 2. Documentos necesarios y qué decisión desbloquea cada uno

Por orden de urgencia real, no de aparición en el prompt:

| # | Documento | Decisión que desbloquea | Sin él |
|---|---|---|---|
| 1 | **Unifilar DC / tabla de strings as-built con la asignación string → conector MPPT** | Cierra `mppt_mesa.csv` con bandera limpio/mixto — lo único no reconstruible a posteriori. Resuelve además la ambigüedad de las 18 mesas CORTO (§2.7) | La tabla queda a nivel inversor (ya la tenemos); el proyecto entero de calibración pierde su resolución |
| 2 | **Communication Protocol SG3x0HX-20** (no el manual de usuario) | Nombres, registros, escalados y **si existe corriente por string o solo por MPPT** (supuesto 2); convenio dirección−1; registros de energía/estado | No hay driver Sungrow. `sungrow_sg320hx.yml` queda en TODO(doc) |
| 3 | **Manual EMU200A / Logger4000, capítulo de integración a terceros** | Nº de sesiones Modbus TCP concurrentes (valida "cliente único"); direccionamiento de los 36 inversores tras el logger (¿unit id = dirección de comunicación?); límite de registros por lectura; **cadencia de refresco interna del logger sobre MPLC** — que es la que fija la resolución real del histórico, no el registro (supuesto 4) | No se puede dimensionar el ciclo de lectura ni prometer resolución a los testigos |
| 4 | **Unifilar AC/MV** | Qué devanado alimenta cada grupo de inversores → `planta.yml` con la restricción de no mezclar devanados por canal; y cómo casan 2 puertos MPLC del EMU con 2 CT × ¿cuántos devanados? | La config anti-mezcla de devanados (innegociable del prompt) no se puede escribir |
| 5 | **Arquitectura de red de planta** (IPs, VLANs, dónde hay salida a internet) | Dónde corre el colector y dónde el broker; si el histórico crudo duerme en planta u oficina | No se puede desplegar nada real |
| 6 | **Config actual del EMU200A en El Burgo** | Qué canales RS485 están de verdad libres; **si iSolarCloud está activo** (consume sesiones/ancho del logger que el colector no controla) | La cuenta de sesiones puede fallar por un cliente invisible |
| 7 | **Modelos y mapas de contadores, CTs y estación meteo** | Drivers RS485 de la fase 1b; sin irradiancia no hay soiling calibrado | La fase 4 (analítica) se queda sin denominador |
| 8 | **Versión de firmware de las NCUs + su mapa Modbus, o plan de actualización a R7** | Si el plano seguidor entra en tiempo real por Modbus o solo por CSV nocturno (hecho medido en §0) | El cruce ángulo↔corriente queda a resolución de CSV (~10 s, sellado por la NCU) — que no es poco, pero hay que decidirlo sabiéndolo |
| 9 | **Datasheet del módulo y detalle de strings en mesas CORTO** | Cierra los kWp por mesa (65 kWp es derivado) y la geometría de los testigos | Solo afecta a análisis, no a adquisición |

Regla mantenida: ningún registro, dirección ni escalado se inventa. Cada hueco queda
`TODO(doc: <documento de esta tabla>)` en el código y la config.

---

## 3. Supuestos del prompt que me parecen frágiles

1. **"Colgar las NCUs de los canales RS485 del EMU"** — es el supuesto más frágil, por
   tres lados: (a) la NCU es un *servidor* Modbus TCP por Ethernet; que pueda actuar de
   esclavo RS485 bajo el Logger4000 no está documentado en ningún sitio; (b) aunque
   pudiera, el firmware actual **no expone telemetría por TCU vía Modbus** (medido, §0) —
   por RS485 el logger vería tan poco como vemos hoy por TCP; y (c) meter el plano
   seguidor por dentro del logger añade su caché y su cadencia desconocida justo en la
   serie que queremos a máxima resolución. **El objetivo real — mismo sellado de hora —
   no exige mismo cable: exige mismo reloj.** Se consigue sellando en el colector (un
   host, NTP), que lee el logger por TCP y las NCUs por TCP como ya hace la flota, y
   publica la deriva de cada fuente. Los RS485 libres del EMU quedan mejor empleados en
   meteo, contadores y CTs, que sí son esclavos RS485 nativos.

2. **"El equipo monitoriza corriente por string"** — que los códigos de fallo estén
   indexados por string (264–283, 1548–1579) prueba que el inversor *detecta* por string,
   no que *publique una medida* de corriente por string en Modbus. En la familia HX es
   plausible que la telemetría continua sea por MPPT y lo de string sean solo eventos.
   No cambia la arquitectura, pero sí la promesa de resolución de los testigos: hay que
   leerlo en el Communication Protocol antes de prometer nada (documento 2).

3. **"Habitualmente 1 MPPT = 1 mesa"** — el Excel lo acota: 29 de 36 inversores tienen 6
   mesas para 6 MPPT (limpio posible), pero **3 tienen 7 mesas** (≥1 MPPT mixto seguro
   cada uno) y **4 tienen 5** — y ahí el riesgo es el inverso y el prompt no lo
   contempla: una mesa repartida entre dos MPPT también invalida la comparación
   mesa-a-mesa, y no la detecta la bandera `limpio|mixto` tal como está definida.
   Propongo tres valores: `limpio · mixto (1 MPPT ← 2 mesas) · partido (1 mesa → 2 MPPT)`.

4. **"La máxima resolución que dé el logger" se asume utilizable** — la resolución real
   la fija la cadena MPLC + caché del logger: 36 inversores × ~24 strings por un medio
   compartido sobre el cable de AC. Puede ser 1 min o peor, y ninguna decisión de diseño
   nuestra la mejora. Además de leer el manual (documento 3), en comisionado hay que
   **medirla** (`tools/medir_cadencia.py`: leer en bucle y cronometrar cuándo cambia cada
   registro) y dejarla escrita en `logger4000.yml`.

5. **La estimación por mesa "~65 kWp, 4 strings de 28 módulos"** — confirmada por el
   Excel para las mesas largas (4 strings/mesa en las 215, 28 módulos/string como
   parámetro). Pero para las **18 mesas CORTO no cuadra**: el propio Excel les lista 4
   strings de los que solo 2 llevan coordenadas, y esas coordenadas abarcan ~32,6 m sobre
   una mesa de 16 m. Huele a strings compartidos entre dos mesas cortas — que es
   exactamente el caso "mesa corta = MPPT con 2 mesas sin pérdida de resolución" que el
   prompt pedía verificar, pero hay que confirmarlo con el as-built (documento 1), no
   deducirlo de un template que se contradice.

6. **"El histórico es irrecuperable, luego lo urgente es el colector"** — cierto, pero la
   conclusión se queda corta: **ya estamos perdiendo histórico de seguidor cada semana**.
   Las NCUs graban CSV diarios (TCU ~10 s, NCU 1 Hz) con retención corta y con variables
   que ni el mapa R7 expone (`motor_current_peak`, consumo diario de motor,
   backtracking…). La descarga está resuelta (`scada/tools/descarga_logs_ncu.py`, una
   petición ZIP por NCU y día) y solo falta programarla. **Es la acción de día uno, antes
   que cualquier línea del colector Sungrow: dos NCUs, un cron, cero riesgo.** Y ojo al
   sellado: esos CSV van con el reloj de la NCU — la deriva hay que medirla y anotarla
   (la verificación foto↔película del importador ya existe para eso).

7. **"El colector es el primer y único cliente Modbus del logger"** — correcto como
   principio, pero "único" no depende solo de nosotros: si el EMU200A tiene la subida a
   iSolarCloud activa, ese cliente interno ya existe y consume recursos del logger.
   Contar con él (documento 6) y decidir explícitamente si se deja vivo o se pide su
   desconexión.

8. **Cadencia TCU→NCU 7–15 s "confirmado"** — la cadencia medida en los CSV de El Burgo
   es ~11,7 s reales con **huecos** (61 min perdidos en un día en el enlace radio de una
   TCU, mientras el registro de la NCU a 1 Hz no perdió ninguno). Para el cruce
   ángulo↔corriente conviene asumir desde el diseño que la serie de seguidor tiene
   agujeros y que la disponibilidad por muestra es un dato más, no una sorpresa.

9. **"Repo nuevo `imoriana3/scada-elburgo`"** — no existe o esta sesión no tiene acceso.
   Decidir: crearlo y autorizarlo (mi preferencia: este sistema tiene ciclo de vida y
   público distintos del tracker-SCADA), o adoptar un subdirectorio en `scada`. Mientras,
   esta propuesta vive aquí. Si acaba en repo propio, el reparto de `scada/CONTRATO.md`
   necesita una fila nueva: hoy nadie "lidera" la adquisición eléctrica.

---

## Primer movimiento propuesto (cuando se apruebe esta propuesta)

1. **Día uno, sin esperar a ningún documento:** programar la descarga nocturna de CSVs de
   las 2 NCUs (supuesto 6) — deja de perderse histórico de seguidor ya.
2. Fase 0 tal como la define el prompt: esqueleto, `contracts/`, extractor de
   `nomenclatura.csv` desde el Excel (todo lo que no depende de documentos pendientes).
3. Con el documento 1: `mppt_mesa.csv` + mapa limpio/mixto/partido.
4. Con los documentos 2 y 3: driver Sungrow y medida de cadencia real en comisionado.
