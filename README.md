# Tracker SCADA — El Burgo (NCU)

> SCADA de operación que lee las NCU Factiun por Modbus TCP y pinta el estado de cada seguidor en tiempo real sobre el plano de siting. Para O&M / After Sales.

## Qué es

Sistema de supervisión en tiempo real para plantas de seguidores solares Factiun. Hace poll periódico de las NCU por Modbus TCP, almacena en una base de datos de series temporales y visualiza el estado de cada TCU (seguidor) sobre el mismo plano que usa la herramienta de siting (`index.html`).

Reutiliza la arquitectura del SCADA de Gorraiz (Docker + InfluxDB + colector Python), cambiando la fuente de datos de una API web a Modbus industrial.

La NCU actúa como **gateway Modbus** de todos sus TCU en un único espacio de direcciones, por lo que basta **una conexión TCP por NCU** (no una por seguidor). El colector lanza una tarea asíncrona por NCU.

```
 PLANTA FV
 ┌─────────────────────────────────────────────┐
 │  NCU-01 (gateway Modbus)   NCU-02   NCU-N…   │
 │   └─ TCU vía Zigbee         └─ TCU   └─ TCU   │
 │   └─ HSU (viento/nieve)                       │
 └───────────────────┬─────────────────────────┘
                     │  Modbus TCP · 1 conexión/NCU
                     │  poll 30 s · lecturas ≤110 regs · SOLO LECTURA
                     ▼
 MÁQUINA CON DOCKER (PC/oficina con acceso a la LAN de planta)
 ┌─────────────────────────────────────────────┐
 │  collector ──write──> InfluxDB 2.7 <──query── API (FastAPI) │
 │  (asyncio,            (series                 (/live          │
 │   pymodbus)            temporales)             /history       │
 │                                                /meteo)        │
 └───────────────────┬─────────────────────────┘
                     │  HTTP · JSON · fetch /live cada 20 s
                     ▼
 NAVEGADOR (PC / móvil)
 ┌─────────────────────────────────────────────┐
 │  index.html · botón SCADA                    │
 │  mesas coloreadas por estado + tooltip vivo  │
 └─────────────────────────────────────────────┘
```

**Patrón de driver enchufable:** el loop de polling, la decodificación, InfluxDB y la API son idénticos sea cual sea el origen. Solo cambia la clase de driver:

- `simulated` — genera ángulos solares reales con pvlib (backtracking incluido), SoC con ciclo día/noche, TCU offline y uno con eje bloqueado. Permite desarrollar el frontend y validar todo el pipeline **sin hardware**.
- `modbus` — driver real con pymodbus async; mapa de registros configurable en YAML.

## Funcionalidades

- Lee cada NCU de la planta cada X segundos (por defecto 30 s) y normaliza la telemetría de sus TCU: ángulo real, ángulo objetivo, modo (AUTO/MANUAL/OFF), backtracking, SoC/SoH, tensión y temperatura de batería, corriente de motor, alarmas y antigüedad de comunicaciones.
- Guarda histórico en InfluxDB con retención configurable.
- Expone los datos ya digeridos en una API REST simple para el frontend.
- Colorea cada seguidor en el mapa según su **estado de salud** (`health`) y muestra su telemetría al pasar el ratón.
- Es **solo lectura**: el rango Modbus de comandos (40000+: safe positions, modos, ángulo objetivo) queda excluido a propósito para no comprometer la seguridad de la planta.

### Estado `health`

El colector clasifica cada TCU en uno de cinco estados, que determinan el color en el mapa:

| Estado | Color | Significado |
|---|---|---|
| `ok` | Verde | Comunica, sin alarmas, ángulo real ≈ objetivo |
| `warn` | Ámbar | Alarma no crítica, `system_ok`=0, o desviación >5° entre ángulo real y objetivo |
| `alarm` | Rojo | Alarma crítica: eje bloqueado, sobrecorriente de motor, batería crítica, stop, fuera de rango |
| `offline` | Gris | Sin `lastComm` o antigüedad >5 min |
| sin datos | Gris claro | El seguidor existe en el plano pero la API no devolvió telemetría suya |

El estado de comunicaciones lo da la propia NCU mediante el registro `lastComm` por TCU (timestamp Unix), no se infiere.

## Uso

### Frontend (`index.html`)

- **Botón SCADA** (barra de herramientas): activa/desactiva el modo telemetría. Al activarlo pide la URL de la API y la recuerda en el navegador (localStorage).
- Con SCADA activo, las mesas/puntos se colorean por `health` y se actualizan cada 20 s.
- **Chip de estado** (arriba a la izquierda): recuento `ok / warn / alarma / offline` y hora del último dato. Si la API falla, muestra el error y conserva el último dato bueno.
- **Tooltip** al pasar por un seguidor: estado, ángulo real / objetivo, SoC, tensión y temperatura de batería, y alarmas activas.
- Desactivar el botón devuelve el plano al modo siting normal (colores por NCU) sin alterar nada más.

El resto de controles del plano (pan/zoom, asignación, regla, mesas a tamaño real, exportaciones) siguen funcionando igual. No requiere build; es un único fichero HTML autocontenido.

### Puesta en marcha

**Prueba sin hardware (recomendado para empezar):**

1. `cp .env.example .env` y genera el token con `openssl rand -hex 32`.
2. En `plants.yml`, deja `driver: simulated`.
3. `docker compose up -d --build`
4. `docker compose logs -f collector` — el primer ciclo loguea los campos leídos.
5. Abre `index.html`, carga un proyecto (p. ej. El Burgo I), pulsa **SCADA** e introduce `http://localhost:8000`. Verás seguidores en verde, los offline simulados en gris y uno en rojo (eje bloqueado), con el ángulo siguiendo al sol real.

**Conexión a NCU real:**

1. Pon `driver: modbus`, las IP y `port: 503` en `plants.yml`.
2. Ajusta `tcu_count` por NCU.
3. `docker compose up -d --build` y revisa los logs del colector.
4. En `index.html`, botón SCADA → URL de la API (la máquina donde corre el stack).

### Requisitos

- **Docker** y Docker Compose en una máquina con **acceso de red a las IP de las NCU** (misma LAN, VPN o túnel que se use habitualmente para soporte).
- Navegador moderno para abrir `index.html`.
- En las NCU: servidor **Modbus TCP habilitado** y mapa de registros conocido (ver *Notas*; en El Burgo I está pendiente de confirmar con producto).

> Para el modo `simulated` no hace falta acceso a ninguna NCU: basta Docker en el portátil.

### Configuración

Todo lo configurable vive en dos ficheros YAML y un `.env`. **No se toca código** para cambiar de planta o de driver.

`config/plants.yml`:

```yaml
plant:
  id: "el_burgo"            # identificador interno
  name: "PSFV El Burgo I"

polling:
  interval_s: 30            # ciclo de lectura por NCU
  modbus_timeout_s: 3
  max_regs_per_read: 110    # 5 TCU x 22 regs (límite Modbus 125)

driver: "simulated"         # "simulated" | "modbus"
float_word_order: "big"     # orden de palabras F32

ncus:
  - id: "NCU-01"
    host: "10.100.1.XX"     # TODO: IP de la NCU-01 de El Burgo
    port: 503               # OJO: puerto NO estándar en El Burgo (no 502)
    unit_id: 1
    tcu_count: 108          # TODO: nº real de TCU de esta NCU
  - id: "NCU-02"
    host: "10.100.1.56"     # NCU-02 El Burgo (confirmada accesible)
    port: 503
    unit_id: 1
    tcu_count: 107          # TODO: nº real (215 TCU entre las dos)

influxdb:
  url: "http://influxdb:8086"
  org: "factiun"
  bucket: "trackers"
```

`.env` (copiar de `.env.example`):

```
INFLUXDB_TOKEN=...        # generar: openssl rand -hex 32
INFLUXDB_ORG=factiun
INFLUXDB_BUCKET=trackers
INFLUXDB_USERNAME=admin
INFLUXDB_PASSWORD=...
```

Puertos: InfluxDB `8086` · API `8000` · Modbus de la NCU **`503` en El Burgo** (no el 502 estándar).

## Stack

Backend Docker (`tracker-scada.tar.gz`) + frontend de un solo fichero (`index.html`). El backend orquesta 3 servicios: InfluxDB, collector y API.

| Archivo | Qué es |
|---|---|
| `docker-compose.yml` | Orquesta los 3 servicios (InfluxDB, collector, API) |
| `.env.example` | Plantilla de variables (token InfluxDB, credenciales) |
| `config/plants.yml` | NCU de la planta, IPs, nº de TCU, intervalos, driver activo |
| `config/modbus_map.yml` | Mapa de registros (derivado de `NCU_Modbus_Map_R7.xlsx`) |
| `collector/main.py` | Loop asíncrono por NCU + escritura a InfluxDB |
| `collector/decode.py` | Decodificación U16/S16/F32/U32, bitsets de alarmas y clasificación `health` |
| `collector/drivers/modbus_ncu.py` | Driver Modbus TCP real (solo lectura) |
| `collector/drivers/simulated.py` | Driver simulado con pvlib |
| `collector/Dockerfile`, `requirements.txt` | Imagen del colector |
| `api/main.py` | API FastAPI: `/live`, `/history/{ncu}/{tcu}`, `/meteo` |
| `api/Dockerfile`, `requirements.txt` | Imagen de la API |
| `index.html` | Frontend: herramienta de siting + capa SCADA (botón "SCADA") |

### API REST

| Endpoint | Devuelve |
|---|---|
| `GET /live` | Último estado de todos los TCU de la planta (JSON) |
| `GET /live?ncu=NCU-01` | Filtrado por NCU |
| `GET /history/{ncu}/{tcu}?hours=24&fields=tilt_angle,target_angle,soc` | Series temporales de un TCU |
| `GET /meteo` | Última lectura de cada HSU |
| `GET /health` | Healthcheck del servicio |

Respuesta de `/live` (resumen):

```json
{
  "count": 215,
  "trackers": [
    {"ncu":"NCU-01","tcu":1,"health":"ok","tilt_angle":-23.5,
     "target_angle":-23.4,"soc":87,"battery_voltage":13100,
     "temp_battery":22,"main_state":2,"comms_age_s":12.0,"alarms":""}
  ]
}
```

### Esquema InfluxDB

- `tracker_status` — tags: `plant`, `ncu`, `tcu` · fields: `tilt_angle`, `target_angle`, `soc`, `soh`, `battery_voltage`, `battery_current`, `temp_battery`, `temp_pcb`, `motor_current`, `main_state`, `bt_active`, `safe_position`, `system_ok`, `alarms` (texto), `health`, `comms_age_s`.
- `ncu_status` — alarmas globales de viento/nieve, estado de gateways, UPS.
- `meteo` — tags: `ncu`, `hsu` · fields: `wind_speed`, `wind_direction`, `snow_level`, `wind_level`, `alarm_wind`, `alarm_snow`.

### Mapa Modbus (`config/modbus_map.yml`)

Derivado de `NCU_Modbus_Map_R7.xlsx`. Estructura principal:

- **TCU compat** — bloque compacto, base `30500`, 22 registros por TCU, contiguo hasta 200 TCU. Incluye ángulos (F32 en radianes), SoC/SoH, batería, temperaturas, corriente de motor, modo y dos registros de alarmas.
- **lastComm TCU** — base `29500`, U32 por TCU (epoch Unix).
- **HSU** — base `30200` (básico) o `28000` (extendido con piranómetros).
- **NCU** — `30000`–`30105`: estado de gateways, batería UPS, alarmas globales.

> Decodificación de F32: dos registros U16 → IEEE-754. El orden de palabras (`float_word_order`) es configurable porque el Excel no lo especifica.

## Despliegue (URL)

Sin deploy público: el backend Modbus corre en local/oficina (PC con acceso a la LAN de planta), no en la nube. El frontend es `index.html`, un fichero estático autocontenido que se abre en el navegador y apunta a la URL de la API del stack.

> Recomendación: servir el HTML desde el mismo origen que la API (p. ej. un Caddy) para evitar CORS/mixed-content cuando la API no está en `localhost`.

## Notas

### Solución de problemas

| Síntoma | Causa probable | Arreglo |
|---|---|---|
| `Connect` da timeout / `SocketException` | No hay ruta a la NCU, o el puerto Modbus no es el 502 | Comprobar ruta con `Test-NetConnection <ip>`; barrer puertos (en El Burgo es **503**) |
| Ping OK pero puerto 502 `False` | Modbus en puerto no estándar o desactivado | Barrer 502/503/1502/8502…; revisar config de la NCU |
| Conecta pero "Excepción Modbus, código 2" | Dirección no existe en ese firmware (mapa distinto) | Verificar versión de firmware y mapa correspondiente |
| Ángulos F32 disparatados | Orden de palabras incorrecto | Cambiar `float_word_order` de `big` a `little` |
| Lectura entera falla aunque 1 registro responda | Se pide un rango que sale del bloque | Reducir `count` al tamaño real del bloque |
| SoC inverosímil | Solape SoC/RemainingCapacity en `30513` (errata del Excel R7) | Confirmar con firmware qué hay en `30513` |
| CORS / mixed-content al abrir el HTML | API en host distinto sin HTTPS | Servir el HTML desde el mismo origen que la API (p. ej. un Caddy) |

### Estado real de la integración en El Burgo I (proyecto 23003)

Diagnóstico realizado contra la **NCU-02 (`10.100.1.56`)** vía el túnel de soporte (origen `100.65.0.5`, ~300 ms de latencia):

- Ruta de red **OK** (ping responde). La interfaz web está viva en el **puerto 80**.
- El puerto **502 está cerrado**; el servidor **Modbus TCP responde en el puerto 503** (no estándar, decisión de firmware).
- El firmware de El Burgo es **anterior al mapa R7** y **no expone los bloques de TCU del R7**: las lecturas a `30500`, `50000` y `29500` devuelven dirección ilegal (código 2).
- Evidencias del mapa real de ese firmware (con función 03):
  - La convención de direcciones es **exacta** (responde `30000`, no `29999`): no hay offset −1.
  - El **reloj funciona y está en hora**, pero vive en el bloque `30300`–`30349` en campos separados (h/min/día/mes/año), no en el `30104` del R7 (que devuelve 0).
  - Bloque `30200`–`30247` con firma de **diagnóstico de radio** (valores tipo −52, −50 dBm = RSSI Zigbee) y cadenas ASCII embebidas (serie/versión).
  - Bloque grande `46091`–`46601` (~511 registros) **a cero** y de respuesta errática; posible zona de consignas/reservada.
  - **No se localizó ningún bloque con telemetría por TCU.** Es probable que este firmware no la exponga por Modbus (la web sí la muestra, pero por su backend interno).

> **Prueba pendiente (con Modbus Poll):** repetir las lecturas con **función 04 (Input Registers)** en lugar de la 03. Las direcciones tipo 30xxx/40xxx sugieren input registers en la convención clásica; es plausible que la telemetría esté ahí. Probar `FC04 @ 30500 x22` y `FC04 @ 30104 x2`, con formato 32-bit Float/Unsigned y los distintos órdenes de byte. Si también da ilegal en todo, queda confirmado que el firmware no expone TCU por Modbus.

> **TODO (vía documental, camino corto):** obtener de la web de la NCU la **versión de firmware** de El Burgo, y solicitar a producto/firmware (1) el **mapa Modbus correspondiente a esa versión** y (2) la viabilidad de **actualizar las NCU a un firmware con el mapa R7**. Es además una pregunta estándar para After Sales: "versión mínima de NCU para integrar SCADA de cliente".

### Notas técnicas

- **Una conexión TCP por NCU**: el bloque compacto permite leer hasta 200 TCU en ~40 transacciones de ≤110 registros, respetando el límite Modbus de 125 registros por lectura.
- **Solo lectura por diseño**: el driver real no implementa escrituras; el rango de comandos 40000+ queda fuera.
- **Mapeo TCU ↔ índice Modbus** (frontend): por defecto se asigna índice secuencial `1..N` dentro de cada NCU, ordenando por `(GW, número en GW)`. **Es una convención provisional**; la asignación real de direcciones se fija en comisionado. Si difiere, está previsto importar un CSV de mapeo (`ncu;tcu_modbus;nomenclatura`).
- **Validación hecha:** `decode.py` verificado con registros sintéticos (ángulos F32 rad→°, SoC, corrientes con signo, temperaturas Kx10→°C, bitsets de alarmas, clasificación `health`). La capa SCADA del HTML verificada con un harness Node (indexado, colores por estado, tooltips y no-regresión del modo siting).
- **Resiliencia del colector**: loop con reintento y backoff por NCU; el primer ciclo loguea los campos disponibles para validar el mapeo contra el hardware real.

### Limitaciones y mejoras

**Limitaciones actuales**

- La integración con NCU **real está bloqueada** hasta confirmar el mapa Modbus del firmware de El Burgo. El stack funciona end-to-end con el driver simulado.
- El mapeo TCU↔Modbus es una convención por defecto, no validada contra comisionado.
- Pensado para polling; las alarmas se capturan al ritmo del ciclo (no hay push/eventos).

**Mejoras previstas**

- Importación de CSV de mapeo TCU↔dirección Modbus.
- Driver para el mapa antiguo de El Burgo una vez documentado (o tras actualizar a R7).
- Soporte multiplanta en un único panel (el `config` ya lo contempla).
- Gráficas de histórico por TCU en el propio frontend (consumiendo `/history`).
- Downsampling/retención afinada en InfluxDB para histórico largo.
- Despliegue en mini-PC siempre encendido en oficina (el portátil pierde histórico al apagarse).

---

*Factiun · proyecto interno.*
