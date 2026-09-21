# SCADA / operations contract audit

## Audit metadata

| Field | Value |
|---|---|
| TASK_ID | `07-SCADA__scada` |
| TARGET_CHAT | `07_SCADA` |
| Repository | `scada` |
| Audited base branch | `work` (the checkout contains no local or remote `main` ref) |
| Audited base commit | `20af1e199dfe2e7b371c1fa36d5b51baca556b90` |
| Audit date | `2026-09-21` (UTC) |
| Audit status | `COMPLETE` |
| Audit mode | Static contract audit plus repository validation commands |

## 1. Executive findings

The operational stack does **not** consistently map telemetry to one canonical plant-entity model. It combines:

1. a compact, contiguous `NCU + ordinal TCU` telemetry model in the Python collector;
2. a separately embedded siting/topology model in `index.html`;
3. toolbox topology JSON and PowerShell diagnostics;
4. Supabase contracts documented for external web applications; and
5. runtime indexes reconstructed in the browser.

The collector is internally coherent for a simple NCU whose tracker cache is contiguous from 1 through `tcu_count`. End-to-end identity is not coherent, however:

- the checked-in backend configuration uses `NCU1` / `NCU2`, while the built-in frontend topology uses `NCU-01` / `NCU-02`; the live join compares these strings literally;
- the frontend derives `scadaIdx` by sorting layout trackers rather than consuming a commissioned Modbus-to-tracker binding;
- `NCU2` explicitly declares exceptional TCU 109 and a missing 108, but the collector polls only the contiguous range 1..107 and ignores gateway ranges;
- Influx telemetry omits gateway, physical tracker number, client label, coordinates, topology revision, provenance, and general quality;
- the API persists a `plant` tag but does not filter or group queries by plant;
- Supabase, Influx, embedded layouts, toolbox plant files, and external DWG-derived files each represent overlapping topology with different identifiers and completeness rules;
- the deployment defaults to simulated data, but stored data and API responses do not identify their source as simulated.

**Overall conclusion:** this repository contains strong protocol decoding and operational state adapters, but it reconstructs plant topology and entity joins rather than consistently consuming canonical plant entities. A versioned adapter to `06_PLANT` should normalize plant/entity aliases, bind signals to immutable entities, represent sparse Modbus inventories, and attach timestamps, quality, units, topology revision, and simulation/live provenance.

## 2. Complete implementation inventory

### 2.1 Live collection and persistence

| Path / symbol | Contract / fields | IDs | Units and time | Provenance | Role candidate |
|---|---|---|---|---|---|
| `config/plants.yml` | `plant{id,name}`, `polling`, `driver`, `float_word_order`, `ncus[]`, `traffic`, `influxdb` | Plant slug/name; NCU text ID; gateway port/range; HSU slave | Poll/timeouts in seconds | Hand-maintained deployment config, with field/layout-derived comments | **CANONICAL** for collector deployment; **MIRROR** of plant topology |
| `config/modbus_map.yml` | `tcu_compat`, `tcu_lastcomm`, `alarm_bits`, `ncu.registers`, `hsu`, `hsu_ext` | Register address, offset, bit | Raw mV, mA, rad, Kx10, m, m/s, degree, Wm2x100 | Derived subset of vendor R7/R23 map | **ADAPTER** |
| `collector/decode.py::decode_tcu_block` | Decodes `u16`, `s16`, `u8_low`, `f32`, `s32`, `u32`; expands bit fields | Field name from YAML | Converts rad→degree, Kx10→°C, scaled integers | Raw Modbus registers | **ADAPTER** |
| `collector/decode.py::decode_alarms` | Raw alarm registers → list of alarm names | Alarm bit/name | N/A | YAML bit map | **ADAPTER** |
| `collector/decode.py::tracker_health` | `ok`, `warn`, `alarm`, `offline` | TCU operational record | Stale threshold 300 s; angle tolerance 5° | Derived from decoded fields, alarms and communication age | **ADAPTER** |
| `collector/decode.py::motivo_health` | Human explanation of derived health | TCU | Text | Same decision inputs as health | **ADAPTER**, not persisted |
| `collector/drivers/modbus_ncu.py::NCUDriver` | Driver interface: trackers, NCU status, meteo | NCU config ID; numeric TCU and HSU cache slots | NCU/host epoch and age seconds | Common real/simulated driver boundary | **ADAPTER** |
| `collector/drivers/modbus_ncu.py::ModbusNCUDriver.read_trackers` | `{tcu,fields,alarms,last_comm,comms_age_s,comms_age_src,skew_s}` | Emits `tcu=i+1` | `last_comm` Unix seconds; age/skew seconds | NCU cache blocks | **ADAPTER** |
| `collector/drivers/modbus_ncu.py::read_ncu` | Decoded NCU bits and `date_time` | NCU | Unix timestamp plus bit/enumerated states | Registers 30002 and 30100..30105 | **ADAPTER** |
| `collector/drivers/modbus_ncu.py::read_meteo` | `{hsu, fields}` with basic/extended pages merged by slot | NCU-local integer HSU slot | HSU engineering units | NCU-published HSU cache | **ADAPTER** |
| `collector/drivers/simulated.py::SimulatedNCUDriver` | Same high-level shapes as real driver; injected offline/lag/alarm states | Same ordinal IDs | Synthetic current UTC/time, approximate solar model | Random/simulated | **ADAPTER** |
| `collector/main.py::tracker_points` | Influx measurement `tracker_status`; tags `plant,ncu,tcu`; fields `health,alarms,comms_age_s,tilt_angle,target_angle,soc,soh,battery_voltage,battery_current,temp_battery,temp_pcb,motor_current,panel_voltage,main_state,bt_active,safe_position,system_ok,alarms1,alarms2` | Plant slug, exact NCU string, ordinal TCU string | Converted values; implicit Influx write timestamp | Per-poll driver result | **MIRROR** |
| `collector/main.py::poll_ncu` | Influx `ncu_status`, `meteo`, `event`, `traffic` batches | Plant/NCU; HSU slot | Host UTC event time; NCU time/skew; traffic bytes | Poll cycle | **MIRROR / ADAPTER** |
| `collector/events.py::RegistroEventos` | `event` tags `plant,ncu,scope,kind,tcu?/hsu?`; fields `from,to,res_s,detail?` | Scoped equipment key | Explicit timezone-aware detection time; resolution seconds | In-memory edge detection between poll cycles | **ADAPTER** |
| `collector/traffic.py::TrafficMeter` | `lan_b,lan_up_b,lan_down_b,cloud_raw_b,cloud_gz_b,modbus_tx,cloud_points,period_s` | Plant/NCU | Bytes, counts, seconds | Accounted request/payload sizes, not packet capture | **ADAPTER** |
| InfluxDB 2.7 (`docker-compose.yml`) | Buckets/measurements above | Tags defined by collector | Time-series | Local Docker volume | **MIRROR** |

### 2.2 FastAPI read contract

| Endpoint / symbol | Response / semantics | Role candidate |
|---|---|---|
| `api/main.py::live` (`GET /live`) | `{count,trackers[]}`; last fields in previous 10 minutes, optional exact NCU filter | **ADAPTER** |
| `api/main.py::history` (`GET /history/{ncu}/{tcu}`) | `{ncu,tcu,series:{field:[{t,v}]}}`; 5-minute mean; 1–720 hours | **ADAPTER** |
| `api/main.py::meteo` (`GET /meteo`) | `{hsus:[{ncu,hsu,wind_speed,wind_direction,snow_level,wind_level,alarm_wind,alarm_snow}]}` | **ADAPTER** |
| `api/main.py::meteo_history` (`GET /meteo/history`) | Shared time axis plus requested series; mean for scalar fields and last for direction | **ADAPTER** |
| `api/main.py::traffic` (`GET /traffic`) | Per-NCU and total counters/rates using measured `period_s` | **ADAPTER** |
| `api/main.py::health` (`GET /health`) | `{status:"ok"}` | **ADAPTER** |

There is no event-query endpoint even though `event` is persisted.

### 2.3 Browser topology and live-data contract

| Path / symbol | Contract | Role candidate |
|---|---|---|
| `index.html` plant constants (`AYORA`, `PARAMO`, `SANJOSE`, `BURGO`, etc.) | Embedded `ox,oy,sc,name,ncus[],tcus[],hsus[],reps[]` plus geometry/table properties | **MIRROR** of external Siting/DWG topology |
| `index.html::loadProject` | Converts numeric NCU to `NCU-XX`; creates motors with label, physical number, gateway, coordinates and power block | **ADAPTER** |
| `index.html::buildScadaIndex` | Groups layout trackers by NCU, sorts `(gw,tn)`, assigns sequential `scadaIdx` | **ADAPTER / reconstructed topology** |
| `index.html::scadaOf` | Exact lookup by `ncu + "|" + scadaIdx` | **ADAPTER** |
| `index.html::fiHash` / `fiResolve` | Deep link `#tcu/<ncu>/<gw>/<tn>`; detects stale gateway in old links | **ADAPTER** |
| `index.html::equipmentData` | Runtime inventory `ncus,rsus,reps,totals` | **MIRROR / derived view** |
| `index.html::csvEquip` | CSV `equipo,tipo,nomenclatura_cliente,power_block,asociado_a,n_tcu,x_m,y_m[,x_utm,y_utm]` | **ADAPTER** export |
| `index.html::csvAssign` | CSV `tcu,tracker_id,ncu,ncu_cliente,power_block,gw,n_en_gw,x_m,y_m[,x_utm,y_utm]` | **ADAPTER** export |
| `index.html::scadaPoll` | Consumes `/live`, keys rows by exact `ncu|tcu`, derives status counts | **ADAPTER** |
| `localStorage.scadaApiUrl` | FastAPI base URL string | **LEGACY / local adapter state** |
| `localStorage.factiun_meteo` | `{ws,wd,n,t}`; average wind and browser epoch milliseconds | **MIRROR / browser adapter** |

For generated/non-preset scenarios, the browser additionally creates or moves NCUs, assigns trackers by proximity/capacity, splits gateways, places HSU points, renumbers entities, and exports topology. This makes the same application both an operational viewer and a topology constructor.

### 2.4 Supabase and PowerShell contracts

`CONTRATO.md` documents an external contract family that is richer than the Python stack:

| Contract | Fields / semantics | Role candidate |
|---|---|---|
| `diagnosticos` | `{planta,ip,fecha,resumen,datos}` with types `diagnostico_tcu`, `inventario_tcu`, `comisionado`, `seguimiento_pem`, `auditoria_tcu`, `test_comm`, `baterias_tcu` | **CANONICAL** for external portfolio history; **LEGACY/documentary** to Python collector |
| `diagnostico_tcu` rows | `NCU,GW,TCU,Salud,Modo,Tilt,Objetivo,Dif,SoC,SoH,Vbat_mV,Ibat_mA,Vpanel_mV,Ientrada_mA,Tbat_C,Tpcb_C,Dia,Edad_s,Alarmas` plus raw hex fields | **MIRROR** |
| Diagnostic entity key | `TCU` may be numeric tracker, `NCU`, `HSU<n>`, or `Repetidor <n>` | **ADAPTER** over heterogeneous entities |
| Diagnostic health | `OK, AVISO, ALARMA, OFFLINE, SIN LECTURA` | **ADAPTER** |
| `bitacora` | `{id,fecha,planta,ncu,equipo,categoria,texto,autor}` | **CANONICAL candidate** for maintenance journal |
| `acuses` | `{id,fecha,planta,ncu,equipo,alarma,autor,nota}`; logical key `(planta,ncu,equipo,alarma)` | **CANONICAL candidate** for acknowledgements |
| Supabase `topología` | `{proyecto,ncu,esclavos_gw1,esclavos_gw2}`; supports multiple ranges and holes | Claims **CANONICAL** status for web totals |
| `TCU_Agente.ps1::Sb-Login` / `Sb-Insertar` | Authenticated REST inserts into configured Supabase tables | **ADAPTER** |
| Agent HTTP API | Read routes plus gated writes: mode, alarm clear, stow/unstow, commissioning, clock, NVM and bulk writes | **ADAPTER** command plane |
| `agente_config.ejemplo.json` | Plant, HTTP/token, timing, write/config gates, Supabase credentials, development paths | **CANONICAL** for agent deployment |

The Python collector is deliberately read-only and excludes command registers 40000+. The PowerShell agent/toolbox is the separate command plane; writes require `permitir_escritura=true`, confirmation, and auditing.

### 2.5 Shared JSON, postMessage, and imported logs

| Contract | Schema / semantics | Role candidate |
|---|---|---|
| `scada3d` postMessage | `{tipo:"scada3d",planta,fecha,filas:[{ncu,tcu,eti,lat,lon,salud,tilt,dif,soc,alarmas}],meteo:{ws,wd,nieve,hsu,ncu,salud}}`; receiver responds `scada3d-ack` | **ADAPTER** |
| Shared localStorage | `factiun_meteo`, `factiun_plantas`, `factiun_cal_<cod>`, `cobertura_offline`, `cob3d_trackers` | **LEGACY / ADAPTER** |
| NCU daily logs | `NCU<n>_TCU_<nnn>_<date>.csv`, HSU, sensor-head and NCU files at different sampling rates | **MIRROR** of equipment logs |
| External `telemetria` import | Subsampled series, events and summary produced by `factiun-cartera/importar-logs.html` | **ADAPTER / MIRROR** |

The `scada3d` implementation and log importer are referenced contracts in other repositories; they are not implemented by this repository's Python API or `index.html`.

## 3. Entity and ID mapping

### 3.1 Entity hierarchy encountered

```text
Plant
 ├─ NCU
 │   ├─ Gateway / TCP passthrough port
 │   │   ├─ tracker TCU
 │   │   ├─ HSU / RSU
 │   │   └─ repeater (TCU-like device, not a tracker)
 │   └─ NCU-local HSU cache slots
 └─ layout objects, power blocks, client labels and coordinates
```

### 3.2 Identifier crosswalk

| Entity | IDs found | Actual join | Finding |
|---|---|---|---|
| Plant | `elburgo`, `El Burgo I`, `burgo`, `23003`, external `Burgo I` | No normalized shared key | Fragmented naming/file-name logic |
| NCU | `NCU1`, `NCU-01`, numeric/string `1`, client label such as `4.1` | Exact text in `/live` frontend join | Broken without normalization |
| Telemetry TCU | Collector ordinal `i+1` | `(ncu,tcu)` | Derived ordinal, not governed canonical identity |
| Physical TCU | `tn` / `TCU_SUNNER_ID_nnn` | Deep link `(ncu,gw,tn)` | More stable field identity, absent from API |
| Client tracker | `TK 001-01`, `TR-...`, etc. | Layout/display, external `eti` | Business/display identity, absent from Influx |
| Runtime SCADA TCU | `scadaIdx` | `(ncu,scadaIdx)` | Reconstructed adapter identity |
| Gateway | `1/2`, `GW1/GW2`, TCP `503/504` | Layout/toolbox only | Absent from tracker telemetry |
| HSU | Cache slot, `HSU<n>`, RSU number, slave 230/231 | `(ncu,hsu slot)` in Influx | Ambiguous mirror |
| Repeater | `Repetidor n`, NCU/gateway/slave | External diagnostic `(NCU,TCU)` | Not modeled by Python collector |

The frontend's deep-link contract correctly avoids `scadaIdx` because layout changes can shift derived indexes. It uses physical number and carries gateway as a stale-layout check. The live lookup nevertheless still uses the unstable derived index.

## 4. Telemetry, timestamp, quality, and unit semantics

### 4.1 Engineering units

- angles: IEEE-754 radians in registers, converted to degrees;
- voltage: mV in persisted telemetry; UI converts to V for presentation;
- current: mA;
- PCB/battery temperature: Kx10 converted to °C;
- SoC/SoH: percent;
- wind: m/s;
- direction: degrees;
- snow: metres;
- irradiance: signed Wm2x100 scaled by 0.01 to W/m².

Units live in YAML and shared assumptions, not in API payload metadata. No API schema version or unit version accompanies observations.

### 4.2 Timestamp meanings

1. `lastComm`: Unix timestamp written by the NCU for NCU↔TCU communication.
2. `date_time`: NCU clock from register 30104.
3. `comms_age_s`: preferably `NCU date_time - lastComm`; host-clock fallback when NCU time is unavailable.
4. periodic Influx samples: implicit write timestamp because `tracker_status`, `ncu_status`, and `meteo` do not set `.time()`.
5. `event`: explicit timezone-aware host UTC timestamp captured after reads; `res_s` declares polling uncertainty.
6. `factiun_meteo.t`: browser `Date.now()` milliseconds.
7. Supabase diagnostics: textual `YYYY-MM-DD HH:mm:ss`; bitácora/acuses: `timestamptz default now()`.

The NCU-relative communication age is a sound correction for clock skew. The driver returns time provenance (`comms_age_src`) and raw `last_comm`, but tracker persistence discards both; only age is served. NCU-level `clock_skew_s` is stored separately.

### 4.3 Quality semantics

- `health` is equipment operational condition, not sample quality.
- There is no general `GOOD / UNCERTAIN / BAD / NOT_POLLED / NO_DATA` contract.
- `offline` means absent/old `lastComm`, while the Supabase family separately supports `SIN LECTURA`.
- API absence is presented by the frontend as “no response for this TCU”, distinct only in UI logic.
- No per-field validity, stale flag, range validity, source timestamp or source mode is returned.
- `comms_age_src="host"` is a degraded-provenance indicator but is not persisted.

### 4.4 Simulation/live distinction

The real and simulated drivers deliberately share an interface and traffic accounting. Simulation uses approximate Zaragoza coordinates, generated solar position, random fields, injected offline trackers and an axis-blocked tracker. The checked-in configuration selects `driver: simulated`. No tag or API field distinguishes simulated from live data, so provenance is lost after driver selection.

## 5. Modbus, command, and state contracts

### 5.1 TCU register model

- compact cache base 30500, stride 22, maximum 200;
- last-communication base 29500, stride 2, U32 Unix time;
- collector reads one contiguous block for all integers 1..`tcu_count`;
- mode enum: `0=OFF`, `1=MANUAL`, `2=AUTO`;
- important state: backtracking, sleep, day, safe position, system OK, limits, motor lock, raw alarms;
- critical health alarms: axis blocked, hardware/software overcurrent, critical battery, stop button, and out of range.

### 5.2 NCU and HSU model

NCU state is read in two hard-coded transactions: 30002 and 30100..30105. HSU basic cache is 30200/stride 10; extended cache is 28000/stride 100. Both pages are treated as the same physical HSU and merged by cache index. Raw colliding extended fields receive `_ext`; same-named integer decoded values use `max()` and measurements from the extended page replace basic values.

The generic integer `max()` merge is appropriate for boolean OR/severity in current fields but is not a field-specific contract and could mishandle future integer measurements/enums.

### 5.3 Commands, acknowledgements and journal

- Python collector/API: read-only, no write functions, no command lifecycle.
- PowerShell agent/toolbox: gated command endpoints with confirmation and audit.
- Supabase `acuses`: acknowledgement is keyed to alarm text and does not clear the alarm.
- Supabase `bitacora`: maintenance journal keyed to the polymorphic equipment string.
- A future `acciones` table is mentioned, but no authoritative schema was found in this repository.
- Influx named alarm events are not exposed through FastAPI, so they cannot directly back the documented acknowledgement UI through this API.

## 6. Topology sources and provenance

### 6.1 Sources found, in practical order

1. external DWG-derived `cobertura-zigbee/<planta>_layout.json`;
2. external generated/verified `Siting/index.html`;
3. copied embedded plant constants in `scada/index.html`;
4. collector deployment topology in `config/plants.yml`;
5. toolbox JSON in `tools/tcu-toolbox/plantas/*.json`;
6. Supabase `topología`;
7. user-loaded CSV/XLSX;
8. runtime geometrically inferred NCU/gateway/HSU topology.

The source comments say embedded plants are literal copies from Siting, whose source is a DWG layout in `cobertura-zigbee`, and instruct maintainers not to edit them locally. No runtime source revision/hash validates freshness.

### 6.2 What the collector actually uses

The collector uses `tcu_count` and NCU cache order. It does not consume embedded frontend topology or Supabase topology. Gateway definitions in `plants.yml` are relevant to toolbox generation but ignored by collector polling. Therefore holes, disjoint ranges, repeaters, gateway membership, client labels and coordinates do not participate in telemetry identity.

### 6.3 Plant-name/file-name logic

Plant selection and joins depend on multiple human-readable aliases and filenames. Examples include the frontend query parameter `?planta=burgo`, scenario key `burgo`, collector tag `elburgo`, display name `El Burgo I`, numeric project code 23003, and external `Burgo I`. These are not governed by one alias registry.

## 7. Cross-repository dependencies

| Repository / artifact | Required information | Audit impact when absent |
|---|---|---|
| `06_PLANT` | Canonical plant/entity hierarchy, immutable IDs, aliases and revisions | Cannot verify intended adapter boundary |
| `cobertura-zigbee` | Layout/cotas JSON, Zigbee GeoJSON/logs, extracted R7/R23 map, generators | Modbus and topology validation tests cannot complete |
| `Siting` | Verified/generated plant constants and synchronization toolchain | Cannot prove embedded topology freshness |
| `factiun-cartera` | Supabase migrations/clients, SCADA/PEM, plans, log importer, bitácora/acuses UI | Cannot validate documented contracts against implementation |
| `proyectos` | 3D `scada3d` receiver and shared browser contracts | Cannot validate postMessage/origin behavior |
| Vendor documents | `NCU_Modbus_Map_R7.xlsx`, HSU R23 and TCU v6 maps | Register semantics remain derivative |
| Commissioning exports | Sunner `.bat` and `config_tcu_sunner_<planta>.csv` | Cannot prove slave-to-physical-tracker binding |
| Master topology/IP Excel | Toolbox plant generation | Cannot regenerate/verify all topology; source includes secrets and must stay external |
| Deployed Supabase | Real schema, migrations, RLS and topology rows | Markdown alone cannot prove production contract |

## 8. Role candidates: CANONICAL / MIRROR / ADAPTER / LEGACY

### CANONICAL candidates

- `06_PLANT`: intended immutable entity and topology registry, pending external verification.
- Vendor Modbus documents: canonical protocol source, subject to documented errata.
- Commissioned slave/physical-ID export: canonical signal-to-equipment binding, pending owner decision.
- `config/plants.yml`: canonical only for one collector deployment, not for enterprise plant identity.
- Supabase `bitacora` and `acuses`: candidate canonical operational records in the external web architecture.
- Supabase `topología`: currently claims canonical fleet-total status, but conflicts with other sources and needs governance resolution.

### MIRROR candidates

- Influx measurements `tracker_status`, `ncu_status`, `meteo`, `traffic`.
- Embedded plant constants in `index.html`.
- `tools/tcu-toolbox/plantas/*.json`.
- Supabase `diagnosticos` and imported `telemetria`.
- NCU daily CSV logs and derived `config/malla_medida.json`.

### ADAPTER candidates

- `config/modbus_map.yml` plus `collector/decode.py`.
- Real and simulated NCU drivers.
- `tracker_health`, event edge detection and traffic accounting.
- FastAPI projections.
- Browser `loadProject`, `buildScadaIndex`, deep-link and CSV import/export logic.
- PowerShell agent REST/Supabase adapter.
- `scada3d`, localStorage meteo and log import contracts.

### LEGACY candidates

- Free-text plant/NCU/equipment names as primary joins.
- Derived browser `scadaIdx`.
- Shared localStorage without schema/version metadata.
- Old toolbox/Supabase topology exports missing NCUs, ranges, HSU identity, or scope fields.
- Markdown-only external contracts where implementations live in other repositories.

## 9. Discrepancies

| ID | Classification | Discrepancy | Impact |
|---|---|---|---|
| D-01 | **BUG** | Backend NCU IDs are `NCU1/NCU2`; frontend topology uses `NCU-01/NCU-02`; join is exact string concatenation | Checked-in deployment can show no telemetry for every mapped tracker |
| D-02 | **BUG** | NCU2 declares exceptional TCU 109 with missing 108, but `tcu_count:107` drives a contiguous 1..107 read; gateway ranges are ignored | TCU 109 is never polled and sparse inventory cannot be represented |
| D-03 | **APPROXIMATION** (becomes **BUG** when order differs) | `scadaIdx` is reconstructed from `(gw,tn)` instead of a commissioned binding | Plausible telemetry may be displayed on the wrong physical tracker |
| D-04 | **BUG / UNKNOWN deployment assumption** | API queries omit plant filters although points have a plant tag | A shared bucket can mix plants with identical NCU/TCU IDs |
| D-05 | **INTENTIONAL** vocabulary difference, with an adapter gap | Python health lacks Supabase `SIN LECTURA` | `not polled`, `no data`, and confirmed offline can be collapsed |
| D-06 | **APPROXIMATION** | Telemetry omits canonical entity ID, gateway, physical ID, label, coordinates and topology revision | Consumers recreate topology joins |
| D-07 | **LEGACY / UNKNOWN** | Plant identity has several slugs, names, project codes and filenames | Name-based matching and duplicate plants |
| D-08 | **APPROXIMATION** | HSU cache slot is used as HSU identity | Identity can drift with missing/multiple stations |
| D-09 | **APPROXIMATION** | HSU merge uses generic `max()` for every colliding integer | Future enum/integer fields may merge incorrectly |
| D-10 | **BUG** | Simulation/live source is not persisted or served | Synthetic data can be mistaken for field measurements |
| D-11 | **INTENTIONAL / APPROXIMATION** | Periodic samples use write time, while only events set explicit detection time | Source acquisition chronology cannot be reconstructed precisely |
| D-12 | **BUG** | `last_comm` and `comms_age_src` are calculated but discarded from tracker persistence | Consumers cannot audit time provenance or host fallback |
| D-13 | **UNKNOWN / incomplete feature** | Events are stored but not exposed by API | Operational UI cannot consume the dedicated transition stream here |
| D-14 | **INTENTIONAL** architectural split; integration **UNKNOWN** | Acknowledgements/bitácora live only in the external Supabase contract | No verified local link between Influx events and acknowledgement records |
| D-15 | **APPROXIMATION** | `/live` flattens alarm names into comma-separated text while acknowledgement keys use alarm text | Parsing/order/text changes weaken stable alarm identity |
| D-16 | **LEGACY / adapter gap** | Collector ignores declared gateway topology | No tracker gateway identity or gateway-aware validation |
| D-17 | **MIRROR** risk | Embedded topology duplicates an external generated artifact without revision handshake | Silent drift across repositories |
| D-18 | **LEGACY** | Historical toolbox/Supabase exports omitted NCUs, mishandled multi-ranges, or misnumbered HSU rows | Totals and `SIN LECTURA` completion can be wrong |
| D-19 | **APPROXIMATION** | API has no schema or engineering-unit metadata | Consumers rely on shared undocumented assumptions |
| D-20 | **UNKNOWN** | Example config includes concrete Supabase URL and publishable key | Must confirm intended exposure and effective RLS |

## 10. Unresolved UNKNOWN items

1. Whether each production deployment is guaranteed a separate Influx bucket, making the missing plant filter intentional.
2. Whether TCU 109 exists in commissioned hardware and what its NCU cache index is.
3. Whether a CSV mapping override for `buildScadaIndex` exists elsewhere; the inspected implementation only contains the comment.
4. Which plant identifier is authoritative across `06_PLANT`, Supabase, collector config and layouts.
5. Which topology source wins when DWG/layout, commissioned ranges and observed inventory disagree.
6. Whether `event` is consumed by an uninspected external service despite having no FastAPI route.
7. Whether `acuses` bind to stable codes anywhere in the external application or only to presentation text.
8. Whether the concrete Supabase publishable key is approved and protected by suitable RLS.
9. Whether NCU/HSU clocks are UTC, local time encoded as epoch, or firmware-dependent.
10. Whether the generic integer HSU merge is guaranteed safe by the vendor schema.
11. Whether simulated and live points can coexist in a production bucket.
12. Whether `acciones` has an implemented authoritative schema in another repository.

## 11. Tests and validation evidence

| Command | Result |
|---|---|
| `python tools/test_eventos.py` | **PASS** — 27 checks: startup suppression, explicit event time, resolution, scopes, inventory changes and quiet cycles |
| `node tests/test_vis_importadores.js` | **PASS** — 42/42 checks: CSV/XLSX parsing, missing values, exclusion reporting, ambiguous columns and round-trip |
| `python tools/test_modbus_map.py` | **ENVIRONMENT-LIMITED** — required `cobertura-zigbee/tools/modbus_src/ncu_r7_hsu_r23.json` was absent; the script refused to declare success |
| `python tools/test_plants_yml.py` | **ENVIRONMENT-LIMITED** — adjacent `cobertura-zigbee` layouts were absent |
| `git status --porcelain=v1` during audit | **PASS** — empty before report persistence; original audit was read-only |
| `rg -n "acuses|bitacora|bitácora|postMessage|supabase" --glob '!CONTRATO.md' .` | **PASS** — located Supabase implementation in the agent and confirmed no Python acknowledgement/bitácora implementation |
| Targeted `rg`, `nl -ba`, and `sed` inspections listed below | **PASS** — static evidence gathered without repository changes |

The two environment-limited checks demonstrate that canonical register and topology validation currently depends on files stored in another repository.

## 12. Candidate adapter boundary to `06_PLANT`

Introduce a versioned plant-entity registry and signal-binding adapter between protocol inputs and every persistence/UI projection.

### 12.1 Canonical entity envelope

```json
{
  "schema_version": "plant-entity/v1",
  "plant_id": "immutable-plant-id",
  "entities": [{
    "entity_id": "immutable-entity-id",
    "entity_type": "PLANT|NCU|GW|TRACKER|HSU|REPEATER",
    "parent_id": "immutable-parent-id",
    "operational_name": "NCU-01",
    "aliases": ["NCU1", "1", "client-name"],
    "attributes": {
      "project_code": "23003",
      "modbus_unit": 1,
      "gateway": 2,
      "slave": 109,
      "client_label": "TK ...",
      "x": 0,
      "y": 0,
      "crs": "EPSG:25830"
    },
    "valid_from": "...",
    "valid_to": null,
    "source": "...",
    "source_revision": "..."
  }]
}
```

### 12.2 Signal binding

```json
{
  "signal_id": "stable-signal-id",
  "entity_id": "immutable-entity-id",
  "source": {
    "protocol": "modbus-tcp",
    "ncu_entity_id": "...",
    "register": 30500,
    "offset": 6,
    "type": "f32",
    "word_order": "big"
  },
  "semantic": "tracker.actual_tilt",
  "unit_raw": "rad",
  "unit_canonical": "deg",
  "quality_rules": {"stale_after_s": 300}
}
```

### 12.3 Observation/event envelope

```json
{
  "plant_id": "...",
  "entity_id": "...",
  "signal": "tracker.actual_tilt",
  "value": -23.5,
  "unit": "deg",
  "source_time": "...",
  "ingest_time": "...",
  "quality": "GOOD|UNCERTAIN|BAD|NOT_POLLED|NO_DATA",
  "quality_detail": "...",
  "source_mode": "LIVE|SIMULATED|IMPORTED",
  "topology_revision": "...",
  "provenance": {
    "driver": "modbus",
    "register_map": "R7/R23",
    "clock_source": "ncu"
  }
}
```

### 12.4 Adapter responsibilities

- normalize aliases such as `NCU1`, `NCU-01`, and numeric `1`;
- resolve commissioned sparse Modbus IDs without assuming contiguity;
- preserve gateway, physical tracker, client label, HSU and repeater identity;
- map operational condition separately from observation quality;
- keep `SIN LECTURA`, API absence, never-polled, stale and confirmed offline distinct;
- carry live/simulated/imported provenance;
- validate and publish topology revision;
- reject ambiguous mappings rather than showing plausible data on a wrong tracker;
- emit compatibility projections for current Influx, `/live`, Supabase diagnostics, `scada3d`, and toolbox JSON;
- keep display names and filenames as aliases rather than primary keys.

`06_PLANT` should own immutable plant/entity identity and topology; this repository should remain authoritative for NCU register decoding and explicitly versioned operational derivations.

## 13. External repositories still requiring verification

1. **`06_PLANT`** — canonical hierarchy, IDs, aliases, revisions and signal-binding ownership.
2. **`cobertura-zigbee`** — layouts, cotas, real radio evidence, HSU provenance and extracted R7/R23 register JSON.
3. **`Siting`** — current generated plant constants and synchronization behavior.
4. **`factiun-cartera`** — actual Supabase migrations and clients for diagnostics, topology, bitácora, acknowledgements, telemetry and actions.
5. **`proyectos`** — `scada3d` receiver, origin validation and shared localStorage consumers.
6. **Vendor/source-document storage** — R7/R23 spreadsheets/PDFs and TCU v6 register map.
7. **Commissioning/source-data storage** — Sunner `.bat` and per-plant configuration CSVs.
8. **Deployed Supabase instance** — schema, RLS, current topology rows, duplicate names and legacy data.

## 14. Questions to escalate to `00_MASTER`

1. What immutable plant ID must every repository use, and which current names/codes are aliases?
2. What is the canonical NCU identifier syntax? The checked-in backend and frontend disagree.
3. Is a tracker canonically identified by cache ordinal, Modbus slave, physical Sunner ID, client label, or a separate UUID?
4. Can operational TCU inventories contain holes and exceptional addresses such as NCU2/T109? If yes, may `tcu_count` be retired in favor of explicit inventory/range unions?
5. Does `06_PLANT` own topology, or does Supabase `topología` remain authoritative for totals?
6. Is one Influx bucket per plant a hard invariant? If not, should plant become mandatory in every API route and grouping key?
7. What canonical quality mapping preserves `SIN LECTURA`, no API row, never-polled, stale and confirmed offline?
8. May simulated data enter production storage? If yes, should `source_mode` be mandatory and excluded from alerts by default?
9. Which timestamps must be retained separately: equipment source, NCU communication, collector read, ingest/write, and imported log time?
10. What is the stable HSU identity: cache slot, plant-wide HSU/RSU number, gateway/slave pair, or canonical entity ID?
11. Should alarm acknowledgement bind to display text, alarm code/bit, event ID, or an active-alarm occurrence ID?
12. Should event-edge state persist across collector restarts?
13. Which repository owns schema migrations for `diagnosticos`, `topología`, `bitacora`, `acuses`, `telemetria`, and `acciones`?
14. Are the Python collector and PowerShell agent both production ingestion paths, or is one transitional?
15. Should an operations SCADA retain topology-construction capability, or consume only a versioned canonical topology?
16. Is the concrete Supabase URL/publishable key in the example configuration approved for public distribution?
17. Should cross-repository test artifacts be pinned/fetched in CI so Modbus and topology checks are reproducible from this repository?

## 15. Evidence index: paths and symbols inspected

### Collector and API

- `collector/decode.py`: `MAIN_STATE`, `decode_tcu_block`, `decode_alarms`, `tracker_health`, `motivo_health`.
- `collector/drivers/modbus_ncu.py`: `NCUDriver`, `edad_comms`, `_hsu_jobs`, `_campos_ext`, `_funde_ext`, `ModbusNCUDriver`, `read_trackers`, `read_ncu`, `read_meteo`.
- `collector/drivers/simulated.py`: `solar_tracker_angle`, `SimulatedNCUDriver`, `read_trackers`, `_reloj_ncu`, `read_ncu`, `read_meteo`.
- `collector/main.py`: `load_cfg`, `make_driver`, `clasificar`, `tracker_points`, `write_points`, `write_traffic`, `poll_ncu`.
- `collector/events.py`: `NCU_SUCESOS`, `HSU_SUCESOS`, `RegistroEventos` and its edge builders.
- `collector/traffic.py`: traffic fields/models and Zigbee estimate constants.
- `api/main.py`: `_TRACKER_FIELDS`, `_LIVE_KEYS`, `live`, `history`, `meteo`, `traffic`, `_METEO_FIELDS`, `meteo_history`, `health`.

### Configuration and deployment

- `config/plants.yml`: plant, polling, driver, NCU/gateway/HSU and Influx settings.
- `config/modbus_map.yml`: TCU, alarm, NCU, HSU basic and HSU extended maps.
- `config/malla_medida.json`: measured Zigbee hop/ACK evidence summary.
- `docker-compose.yml`: InfluxDB, collector, API and config mount.
- `collector/requirements.txt`, `api/requirements.txt`: runtime integration dependencies.

### Frontend and topology

- `index.html`: embedded real plant constants, CSV/XLSX import, `loadProject`, `equipmentData`, exports, `buildScadaIndex`, `scadaOf`, field-card/deep-link functions, meteo publication, `scadaPoll`, `scadaStart`, plant-name query handling.
- `trafico.html`: traffic viewer consumption and plant inventory presentation.
- `tools/sync_plantas.mjs`: cross-repository plant synchronization.
- `tools/trafico.py`: topology-derived traffic inventory and external layout dependence.
- `tools/test_plants_yml.py`, `tools/test_modbus_map.py`, `tools/test_eventos.py`, `tests/test_vis_importadores.js`: validation boundaries.

### Toolbox, agent, and external contracts

- `CONTRATO.md`: Supabase tables, agent HTTP routes, `scada3d`, localStorage, external file schemas, topology discrepancies and functional roadmap.
- `tools/tcu-agente/agente_config.ejemplo.json`: agent/write/Supabase configuration contract.
- `tools/tcu-agente/TCU_Agente.ps1`: Supabase authentication/insertion and diagnostic production.
- `tools/tcu-toolbox/TCU_Toolbox.ps1`: plant files, topology handling, diagnostics and command workflows.
- `tools/tcu-toolbox/plantas/*.json`: checked-in toolbox topology mirrors.
- `tools/tcu-toolbox/make_plantas.py`: plant JSON generation/merge boundary.

## 16. Audit commands used

The following command families were used to obtain the evidence without modifying repository state:

```text
find .. -name AGENTS.md -print
rg --files -g '!node_modules' -g '!dist'
nl -ba <file>
sed -n '<range>p'
rg -n '<contract/entity/topology patterns>' <paths>
git status --porcelain=v1
git branch --show-current
git rev-parse HEAD
python tools/test_modbus_map.py
python tools/test_eventos.py
python tools/test_plants_yml.py
node tests/test_vis_importadores.js
```

No `AGENTS.md` file was present in or above the repository during the audit.
