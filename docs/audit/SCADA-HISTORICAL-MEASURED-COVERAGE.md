# SCADA — Historical Analysis & Measured Coverage

**Branch:** `codex/scada-historical-measured-coverage-audit` (no merge). **Frontend:** `index.html` del SCADA existente. **Plant package:** El Burgo 23003, IdentityRegistry r1 de `SolarGPTfull` PR #273, sólo para desarrollo provisional mientras no esté publicado en `main`.

## 1. AUDIT FINDINGS

| Distinción | Hallazgo previo | Decisión y resultado |
| --- | --- | --- |
| HECHO / LEGACY | `index.html` tenía ficha TCU y sinóptico por NCU, pero la gráfica libre descrita no estaba en `main`. | P0-SOURCE: crear histórico en esa ficha y `index.html`, sin SPA. |
| HECHO / LEGACY | `tracker_status` en InfluxDB y `GET /history/{ncu}/{tcu}` (1–720 h, una TCU, media cada 5 min). No había desde/hasta, varias TCUs ni agregado diario. | Reutilizar InfluxDB; añadir rutas basadas en `asset_id`, conservar las antiguas. |
| HECHO / BUG | `scadaIdx` ordenaba motores del plano para unirlos con telemetría; NCU2 tenía direcciones dispersas. `tcu_count` no es identidad. | Quitar join posicional de runtime y sondear sólo esclavos explícitos del paquete. El estimador de tráfico conserva `tcu_count` como LEGACY. |
| HECHO / INTENCIONAL | El radio geométrico del sinóptico representa RF modelado; `health` y `comms_age_s` representan estado instantáneo. | Capa separada de disponibilidad de telemetría medida, sin comparativa con RF previsto. |
| HECHO / UNKNOWN | `tracker_status` no contiene RSSI ni `ack_failures`, y los puntos antiguos no registran `source`. | No calcular métricas inexistentes; excluir histórico sin procedencia y simulado de la capa medida. |
| HECHO / DECISIÓN | P0-ID: paquete r1 read-only provisional para desarrollo; runtime sólo revisión publicada/mergeada. P0-TIME: Europe/Madrid, TCU/NCU 30 s, HSU 10 s salvo override explícito. | Adaptador de sólo lectura, configuración de cadencia del colector, zona de planta y calidad visible en API. |

## 2. IMPLEMENTATION PLAN Y ARCHIVOS

| Milestone | Archivos | Resultado |
| --- | --- | --- |
| M01 identidad | `scada_identity.py`, `config/plants.yml`, `api/main.py`, `docker-compose.yml`, Dockerfiles | Verifica hash y revisión mergeada en runtime; bindings explícitos del paquete a `asset_id`; desarrollo provisional no operativo. |
| M02 inventario y procedencia | `collector/drivers/{modbus_ncu,simulated}.py`, `collector/main.py` | TCUs dispersas del inventario real; etiqueta `source`; HSU a 10 s y TCU/NCU a 30 s desde configuración. |
| M03 histórico | `api/historical.py`, `api/main.py` | Consulta UTC desde/hasta de hasta dos TCUs en la UI (API hasta ocho) con igual rango, campos numéricos y eje temporal. |
| M04 gráfica | `index.html`, `historical-ui.js` | Selector de hora local, día anterior/siguiente, presets, chips coloreados y comparación sólido/discontinuo. |
| M05 cobertura | `api/historical.py`, `index.html`, `historical-ui.js` | Agregado de día local, NCU opcional, faltantes/UNKNOWN y capa distinta del RF modelado y health instantáneo. |
| M06 contratos/documentación | `tools/test_historical_milestone.py`, `tests/test_historical_ui.js`, `tools/test_*.py`, `README.md`, este archivo | Pruebas de identidad, huecos, DST, filtros, color y compatibilidad. |

## Contratos y limitaciones

- `GET /identity`, `GET /assets/live`, `GET /assets/history?asset_id=&compare_asset_id=&from=&to=&fields=`, `GET /coverage/measured?day=&ncu_asset_id=`. `from/to` ISO con offset y sin límite artificial de meses; la consulta adapta su ventana hasta unas 1500 muestras por serie. La historia anterior continúa disponible. Sólo campos numéricos graficables; no se promedia `health`.
- `telemetry_availability_pct = received / expected × 100` en el día local cerrado; `expected` usa la cadencia operativa configurada, `received` cuenta slots con muestra `health` de `source=modbus`, `gaps` lista slots ausentes. `offline_observed_pct = muestras recibidas con health=offline / received × 100`. Ausencia de muestra jamás significa equipo offline. Días incompletos o menos de dos muestras => `UNKNOWN` con motivo y porcentaje nulo.
- **APROXIMACIÓN:** los slots se anclan al inicio del día local y se asignan por timestamp de escritura del colector, pues `tracker_status` no lleva tiempo físico de lectura ni historial de cambios de cadencia. Puede agrupar dos lecturas con jitter en un slot o estimar mal un día con cambio operativo de cadencia. El JSON declara esa calidad; para exactitud histórica de cadencias se necesitaría su vigencia contractual.
- **UNKNOWN:** umbrales de buen/degradado/pobre para 08_COMMS; por eso la capa usa intensidad continua, sin semáforos. RSSI, P10 RSSI, ACK failures y RF previsto no forman parte de este esquema. También queda sin verificar visualmente la interacción en navegador real: el navegador de QA no accede al servidor local; las pruebas JS verifican lógica y montaje, no sustituyen una captura.
- El paquete de El Burgo en PR #273 es **provisional** y declara `capabilities.scada.live.available=false` (topología desplegada aún no declarada). Desarrollo: `read_only=true`, `operationally_usable=false`. Producción exige `SCADA_PACKAGE_REPO`, `SCADA_PACKAGE_PUBLISHED_COMMIT` ancestro de `main`, bytes de manifest/registry idénticos y hash correcto. Incluso tras publicar identidad, sólo se declara operativo cuando el paquete sea `accepted` y `scada.live.available=true`. El driver por defecto `simulated` sólo sirve demostración, y su histórico no se etiqueta como cobertura medida real.

## Validación

Se registran resultados finales en la entrega de la rama. Pruebas unitarias y de integración usan un fixture de IdentityRegistry con vínculos explícitos; una prueba adicional con el paquete provisional r1 comprobó 215 TCUs (108 NCU1, 107 NCU2), todas `UNKNOWN` sin telemetría de origen modbus. No se ha conectado hierro ni datos productivos.
