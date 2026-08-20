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
- **Mide su propio tráfico**: cuenta los bytes de cada ciclo (Modbus contra la NCU y subida a InfluxDB) y los publica como una serie más, para saber qué cuesta el SCADA en la LAN de planta y **cuánto sube a la nube cada planta**. Ver [Medidor de tráfico](#medidor-de-tráfico).
- Es **solo lectura**: el rango Modbus de comandos (40000+: safe positions, modos, ángulo objetivo) queda excluido a propósito para no comprometer la seguridad de la planta.
- Cuando sí hay que **escribir** en un TCU (configuración, reloj, NVM), el complemento de campo es **[TCU Toolbox](tools/tcu-toolbox/)** (`tools/tcu-toolbox/`): herramienta offline en PowerShell que habla con los TCU vía el passthrough Modbus de la NCU, comparte las plantas de `config/plants.yml` (vía `make_plantas.py`) y replica este mismo modelo de `health` en su pestaña de diagnóstico.

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

### Medidor de tráfico

Dos preguntas con la misma respuesta: **qué mete el SCADA en la LAN de planta** (por si el enlace a las NCU es un túnel flojo o un 4G) y **cuánto subiría a la nube cada planta** (por si hay que contratar el plan de datos). Se resuelven con el mismo modelo de bytes, para que la estimación y la medida sean comparables:

| | Qué cuenta | Dónde |
|---|---|---|
| **Medida** | Bytes reales de cada transacción Modbus y de cada escritura a InfluxDB, ciclo a ciclo | `collector/traffic.py` (`TrafficMeter`), serie `traffic`, `GET /traffic` |
| **Estimación** | El mismo modelo aplicado sobre la configuración, sin tocar hierro | `python tools/trafico.py` |
| **Visor** | Las dos cosas en una página: flota, planes de subida, calculadora, malla y lo medido en vivo | [`trafico.html`](trafico.html) |

Es tráfico **contabilizado**, no capturado: se calcula del tamaño real de cada ADU y de cada payload, no de un sniffer. El modelo:

```
petición  FC03 = MBAP(7) + FC(1) + dirección(2) + nº registros(2)  = 12 B
respuesta      = MBAP(7) + FC(1) + byte count(1) + 2·nº registros  = 9 + 2n B
+ IPv4+TCP (40 B por segmento) + handshake y cierre (7 segmentos por ciclo y NCU)
nube           = line protocol comprimido (gzip) + cabeceras HTTP/TLS (500 B por escritura)
```

Los tamaños de bloque no van a mano: salen de **`config/modbus_map.yml`**, el mismo mapa que lee el driver — 22 registros por TCU en el bloque compat (base 30500), 2 por `lastComm` (29500) y 10 por HSU (30200; 30 si la HSU es la extendida del bloque 28000) —, y el troceo, de `max_regs_per_read` en `plants.yml`. Si cambia el mapa, la estimación se mueve con él y el banco lo comprueba. Lo único que sigue viniendo del código son las dos lecturas de estado de la NCU (30002 y 30100..30105), porque el driver las tiene fijas.

Lo que **no** cuenta, y conviene saberlo: los ACK puros (viajan montados en el segmento siguiente; como mucho 40 B por transacción, siempre a la baja), la trama Ethernet (18 B más por trama: lo que se factura en un 4G es la carga IP) y el retorno de la nube (el colector solo escribe).

**Flota completa, con polling cada 30 s** (`python tools/trafico.py`). El inventario sale del **plano del propio SCADA** (`index.html`), donde cada TCU declara de qué NCU y de qué gateway cuelga:

| Planta | NCU | TCU | LAN MB/día | Nube MB/día | Nube GB/mes |
|---|---:|---:|---:|---:|---:|
| San José 24019 | 21 | 2289 | 501,1 | 269,8 | 8,09 |
| Panbianco 25004.2 | 12 | 1476 | 319,8 | 166,4 | 4,99 |
| Ayora 24025 | 16 | 754 | 182,1 | 131,6 | 3,95 |
| Benante 25004 | 6 | 730 | 158,6 | 82,6 | 2,48 |
| Páramo 25019 | 4 | 396 | 87,7 | 48,3 | 1,45 |
| El Burgo I 23003 | 2 | 215 | 47,9 | 25,5 | 0,76 |
| El Polvorín 25082 | 2 | 119 | 27,9 | 18,4 | 0,55 |
| Fayón 24007 | 1 | 24 | 6,8 | 6,4 | 0,19 |
| Túnez 24021 | 1 | 19 | 5,9 | 6,0 | 0,18 |
| Bagnarelli 24030 | 1 | 17 | 5,9 | 5,8 | 0,17 |
| **Total** | **66** | **6039** | **1343,6** | **760,7** | **22,8** |

> **San José va por el plano: 2289 TCU** (decidido el 2026-08-20). El `config_tcu_sunner_sanjose.csv` lista 2186 configurados; la diferencia de 103 queda como pregunta para comisionado, pero para tráfico manda el plano, que es lo que el colector va a pollear. `tools/test_trafico.py` lo fija: contrasta el recuento de cada planta con el que anuncia su propio botón en la herramienta («2289 TCU · 21 NCU»), las diez.

> El inventario **no** sale de `tools/tcu-toolbox/plantas/*.json`: ese fichero solo lleva las NCU que alguien declaró para la herramienta de campo, y estaba corto — en San José faltaban 5 de las 21 (1686 TCU en vez de 2289) y no aparecían Páramo, Benante, Panbianco ni El Polvorín. El plano del SCADA es el mismo que pinta la capa de telemetría, así que lo que sale aquí es lo que se va a pollear de verdad.

Tres cosas que se leen en esa tabla:

- **La mayor de la flota sube 8 GB/mes** y las diez juntas 23. Con eso, una SIM de 10 GB cubre la planta más grande y el problema sigue siendo la cobertura, no los datos.
- En las plantas pequeñas **manda la cabecera, no el dato**: Fayón sube 6,4 MB/día con 24 TCU y Túnez 6,0 con 19, porque cada escritura HTTP paga sus ~500 B pase lo que pase. Por eso el colector manda NCU y meteo en un solo POST.
- El gzip hace el trabajo: de 2021 MB/día crudos en San José a 270 comprimidos.

La sensibilidad al ritmo es lineal — `python tools/trafico.py --intervalo 10,30,60,300` la pinta —, así que bajar el polling a 10 s multiplica por 3 la factura y subirlo a 5 min la divide por 10.

### Planes de subida: leer a un ritmo y subir a otro

El ritmo de polling manda en seguridad y en el mapa de estados, así que no siempre se puede tocar. Pero **subir no es leer**: el colector puede seguir sondeando cada 30 s, guardar todo en el InfluxDB local de planta y mandar a la nube solo el dato minutal. `python tools/trafico.py --planes` compara los planes; en El Burgo I:

| Sube cada | Campos | De la ventana | MB/día | GB/mes | vs hoy |
|---|---|---|---:|---:|---:|
| 30 s (cada ciclo) | todo (17) | último valor | 25,5 | 0,76 | 100 % |
| 30 s | operación (8) | último valor | 14,0 | 0,42 | 55 % |
| 1 min | todo | último valor | 12,7 | 0,38 | 50 % |
| 1 min | todo | media/mín/máx | 32,9 | 0,99 | **129 %** |
| 1 min | operación | último valor | 7,0 | 0,21 | 27 % |
| 5 min | todo | último valor | 2,5 | 0,08 | 10 % |
| 15 min | mínimo (4) | último valor | 0,4 | 0,01 | 1 % |

Lo que hay que mirar de esa tabla es la fila en negrita: **agregar sale caro**. Media, mínimo y máximo triplican los campos numéricos, así que subir minutal agregado cuesta *más* que subir cada 30 s el último valor. Si lo que se quiere es ahorrar, se sube el último valor y el detalle se queda en planta; si lo que se quiere es no perder los picos de viento o de corriente de motor, se paga.

En flota, a 30 s el total son 22,8 GB/mes; minutal, 11,4; a 5 min, 2,3; y minutal con solo los campos de operación, 6,5.

Los planes de campos son tres y viven en `PRESETS` (`collector/traffic.py`): `todo` (los 17 que escribe hoy), `operacion` (health, alarmas, ángulos, SoC, estado y edad de comunicaciones) y `minimo` (health, alarmas, SoC y ángulo real).

### Lo que pesa cada campo

`python tools/trafico.py --campos` lo mide quitando cada campo y volviendo a comprimir. No es su longitud, es su **dispersión**:

| Campo | B crudos/TCU | B gz/TCU |
|---|---:|---:|
| `panel_voltage` | 20,0 | 3,97 |
| `battery_voltage` | 22,0 | 3,44 |
| `comms_age_s` | 16,7 | 3,23 |
| `soc` | 7,0 | 2,01 |
| `target_angle` | 18,0 | 0,29 |

`target_angle` ocupa 18 B crudos y 0,3 comprimidos porque vale lo mismo en los 108 seguidores de la NCU; `panel_voltage`, que baila en cada uno, cuesta trece veces más siendo igual de largo. Cualquier decisión de "quitamos campos para ahorrar" hay que tomarla con esta columna, no con la del crudo.

**Malla Zigbee (NCU ↔ TCU).** `--zigbee` añade el tráfico de radio entre equipos: volumen por gateway y **ocupación del canal** (250 kbps compartidos), que es lo que de verdad limita. Con un refresco de 60 s, la malla mayor de la flota (72 TCU en un gateway de Ayora) ocupa ~4 % del aire. Ojo: **esto es un modelo, no una medida** — la NCU no expone contadores de radio y los parámetros (`ZB_*` en `collector/traffic.py`: saltos medios, reintentos, tamaño de trama) están puestos a la vista para ajustarlos en campo con las capturas de `cobertura-zigbee`.

**Visor (`trafico.html`).** Un único HTML sin CDN ni build, como el resto: tabla de flota con el reparto por NCU, mandos para el plan de subida (cada cuánto, qué campos y último valor o agregado), KPIs de GB/mes, calculadora para una planta que aún no existe, ocupación de aire de la peor malla de cada planta y un panel que consulta `GET /traffic` para poner lo medido al lado de lo estimado. Los bytes por ciclo de cada NCU van **horneados** por `python tools/gen_trafico.py --write` con el modelo de Python, así el visor no puede desviarse del medidor; el banco comprueba las dos cosas (que el puerto JS del modelo da lo mismo, y que el inventario del fichero está al día).

Banco de pruebas: `python tools/test_trafico.py` (sin pytest). Comprueba el troceo y el tamaño de las ADU, que **lo estimado coincide exactamente con lo que el driver contabiliza** en un ciclo real del simulado, y que el line protocol de ejemplo del estimador es carácter a carácter el que genera `influxdb_client`.

El medidor se apaga con `traffic.enabled: false` en `config/plants.yml`. Cuesta un punto por NCU y ciclo (~250 B, contabilizado también).

## Uso

### Frontend (`index.html`)

- **Botón SCADA** (barra de herramientas): activa/desactiva el modo telemetría. Al activarlo pide la URL de la API y la recuerda en el navegador (localStorage).
- Con SCADA activo, las mesas/puntos se colorean por `health` y se actualizan cada 20 s.
- **Chip de estado** (arriba a la izquierda): recuento `ok / warn / alarma / offline` y hora del último dato. Si la API falla, muestra el error y conserva el último dato bueno. Debajo, el **tráfico** de las últimas 24 h (LAN y nube, MB/día y GB/mes), refrescado cada 10 ciclos; si la API es anterior a `/traffic`, la línea no aparece y no molesta.
- **Tooltip** al pasar por un seguidor: estado, ángulo real / objetivo, SoC, tensión y temperatura de batería, y alarmas activas.
- Desactivar el botón devuelve el plano al modo siting normal (colores por NCU) sin alterar nada más.

El resto de controles del plano (pan/zoom, asignación, regla, mesas a tamaño real, exportaciones) siguen funcionando igual. No requiere build; es un único fichero HTML autocontenido.

#### Plantas

Las **siete** plantas con layout: El Burgo I 23003, Ayora 24025, San José 24019, Páramo 25019, Fayón 24007, Bagnarelli 24030 y Túnez 24021. Se abren con su botón o directamente con `?planta=burgo|ayora|sanjose|paramo|fayon|bagnarelli|tunez` (mismo parámetro que el siting, la Cobertura y el Layout 2D).

Los datos de planta **no se editan aquí**. El origen es el layout del DWG, en `cobertura-zigbee/<planta>_layout.json`:

```
layout del DWG ──gen_siting.mjs──> Siting/index.html ──sync_plantas.mjs──> SCADA/index.html
```

- `node tools/sync_plantas.mjs` — dice qué difiere respecto al siting; con `--write`, lo iguala.
- `node tools/test_plantas.mjs` — abre las dos apps en un navegador headless y exige que las siete plantas carguen con las mismas cifras (motores, NCU, HSU, repetidores, bloques, cotas de mesa y giro). Necesita `playwright-core`.

Cuando cambie un layout, `Siting/tools/gen_siting.mjs <planta> --write --destino=ambos` escribe en las dos a la vez.

La librería de Excel (SheetJS) va en `lib/`, no en un CDN: esto se abre en la LAN de una planta, que normalmente no tiene salida a internet.

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
| `collector/traffic.py` | Medidor de tráfico: modelo de bytes, contador por ciclo y estimación por planta |
| `collector/decode.py` | Decodificación U16/S16/F32/U32, bitsets de alarmas y clasificación `health` |
| `collector/drivers/modbus_ncu.py` | Driver Modbus TCP real (solo lectura) |
| `collector/drivers/simulated.py` | Driver simulado con pvlib |
| `collector/Dockerfile`, `requirements.txt` | Imagen del colector |
| `api/main.py` | API FastAPI: `/live`, `/history/{ncu}/{tcu}`, `/meteo`, `/meteo/history`, `/traffic` |
| `api/Dockerfile`, `requirements.txt` | Imagen de la API |
| `index.html` | Frontend: herramienta de siting + capa SCADA (botón "SCADA") |
| `trafico.html` | Visor del medidor de tráfico: flota, calculadora, malla Zigbee y medido en vivo |
| `lib/xlsx.full.min.js` | SheetJS local (sin CDN: la LAN de planta no tiene internet) |
| `tools/sync_plantas.mjs` | Trae al SCADA las plantas del siting (mismo plano, mismos datos) |
| `tools/test_plantas.mjs` | Banco: las 7 plantas cargan y cargan igual que en el siting |
| `tools/trafico.py` | Estimador de tráfico por planta y por flota (LAN, nube, malla Zigbee) |
| `tools/gen_trafico.py` | Hornea en `trafico.html` los bytes por ciclo de cada NCU (fuente: el modelo) |
| `tools/test_trafico.py` | Banco del medidor: modelo de bytes, estimación ≡ medida, line protocol |
| `tools/test_modbus_map.py` | Banco del mapa: el subconjunto contra el R7 publicado (bloques, offsets, tipos, alarmas) |

### API REST

| Endpoint | Devuelve |
|---|---|
| `GET /live` | Último estado de todos los TCU de la planta (JSON) |
| `GET /live?ncu=NCU-01` | Filtrado por NCU |
| `GET /history/{ncu}/{tcu}?hours=24&fields=tilt_angle,target_angle,soc` | Series temporales de un TCU |
| `GET /meteo` | Última lectura de cada HSU |
| `GET /traffic?hours=24&ncu=NCU1` | Tráfico medido: LAN de planta y subida a la nube, por NCU y total |
| `GET /meteo/history?hours=720&every=10m&hsu=1` | Series de las HSU (viento, dirección, temperatura, GHI) sobre un único eje de tiempos |
| `GET /health` | Healthcheck del servicio |

`/meteo/history` es lo que convierte a las HSU en dato de análisis y no solo de pantalla: lo consume
el simulador de abanderamiento del Panel
([`sim-viento.html`](https://imoriana3.github.io/proyectos/sim-viento.html)) para estudiar un
emplazamiento **con el viento medido en la planta** en vez de con reanálisis. Dos cosas que hay que
saber del dato que devuelve: los escalares se agregan por media en cada ventana, pero la **dirección
se toma como último valor** (promediar rumbos exige media circular: entre 350° y 10° la media
aritmética da 180°, el rumbo contrario), y **sin filtrar `hsu` o `ncu` se mezclan todas las HSU** de
la planta.

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
- `traffic` — tags: `plant`, `ncu` · fields: `lan_up_b`, `lan_down_b`, `lan_b`, `modbus_tx`, `connections`, `cloud_raw_b`, `cloud_gz_b`, `cloud_points`, `cloud_writes`, `period_s`. Un punto por NCU y ciclo, con el coste de ESE ciclo (no acumulados): la proyección a día/mes la hace `/traffic` sobre el tiempo realmente medido, así un colector parado no infla la cuenta.
- `meteo` — tags: `ncu`, `hsu` · fields: `wind_speed`, `wind_direction`, `snow_level`, `wind_level`, `alarm_wind`, `alarm_snow`.

### Mapa Modbus (`config/modbus_map.yml`)

Derivado de `NCU_Modbus_Map_R7.xlsx`. Estructura principal:

- **TCU compat** — bloque compacto, base `30500`, 22 registros por TCU, contiguo hasta 200 TCU. Incluye ángulos (F32 en radianes), SoC/SoH, batería, temperaturas, corriente de motor, modo y dos registros de alarmas.
- **lastComm TCU** — base `29500`, U32 por TCU (epoch Unix).
- **HSU** — base `30200` (básico) o `28000` (extendido con piranómetros).
- **NCU** — `30000`–`30105`: estado de gateways, batería UPS, alarmas globales.

**Contrastado con el mapa publicado.** `python tools/test_modbus_map.py` compara este subconjunto con el R7 ya extraído a JSON del repo de Cobertura Zigbee (`tools/modbus_src/ncu_r7_hsu_r23.json`, el mismo que genera la ficha [Mapa Modbus](https://imoriana3.github.io/cobertura-zigbee/modbus.html) del Panel): bases y tamaños de bloque, offset y tipo de cada campo del bloque compat **y de las dos hojas de HSU** (básica 30200 y extendida 28000, con las tres irradiancias), y los bits de alarma que deciden el `health`. 51 comprobaciones, en verde. Las tres diferencias son **erratas conocidas del documento** y están declaradas con su motivo en el propio banco:

- `30513` solapa `StateOfCharge` (U8 bajo) y `RemainingCapacity` (U16); el colector lee el SoC del byte bajo, confirmado en R7.1.
- El MSR del TCU figura como U8 pero coloca `MainState` en los bits 9..8 y `SafePosition` en 15..13, así que se lee el registro entero y se extraen los bits.
- El MSR de la HSU, igual: declarado U8 y a la vez definido sobre los bits 15..0.

El otro mapa de la plataforma, el del TCU (`tcu_v6.json`, del PDF de Sunner v6), **no entra aquí a propósito**: describe el espacio propio del TCU, al que se llega por el passthrough de la NCU. Es el que usa la [TCU Toolbox](tools/tcu-toolbox/), no el colector, que solo lee el bloque que la NCU republica.

Si no tienes el otro repo clonado al lado, el banco lo dice y sale sin dar nada por bueno (`--fuente` acepta la ruta).

> Decodificación de F32: dos registros U16 → IEEE-754. El orden de palabras (`float_word_order`) es configurable porque el Excel no lo especifica.

## Despliegue (URL)

`trafico.html` es una página estática y se publica con el repo (GitHub Pages); el resto no. Sin deploy público: el backend Modbus corre en local/oficina (PC con acceso a la LAN de planta), no en la nube. El frontend es `index.html`, un fichero estático autocontenido que se abre en el navegador y apunta a la URL de la API del stack.

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
