# SCADA — Historical Analysis & Measured Coverage: audit gate

**Status:** BLOCKED_P0; implementation has not started.  
**Repository:** `IMoriana3/scada`; audited `main` at `565ebd3264b1c259d011226e86896bda1bd7e86d` (2026-09-25).  
**Branch:** `codex/scada-historical-measured-coverage-audit`.

## 1. AUDIT FINDINGS

| Finding | Kind / discrepancy | Evidence |
| --- | --- | --- |
| There is a TCU field card and plant canvas with NCU selection, but no free historical chart or variable selector in this repository. The README explicitly lists historical TCU charts as future work. | HECHO / UNKNOWN: the described existing chart may live in a different product or unpublished branch. | `index.html` (`fiRender`, `fiOpen`, `draw`); `README.md` “Gráficas de histórico por TCU” under pending work. The only open PR in `scada` at audit time was #261, a contract audit. |
| Historical storage exists: `tracker_status` points in InfluxDB; `/history/{ncu}/{tcu}` accepts `hours=1..720` and `fields`, returns one TCU with fixed 5-minute means. It has no `from/to`, multi-TCU request or daily aggregation. | HECHO / LEGACY limitations. | `collector/main.py::tracker_points`; `api/main.py::history`; `tools/test_api.py`. |
| `health` and `comms_age_s` exist in stored TCU samples. `health=offline` is a device communications assessment, not evidence that the collector missed a sample. RSSI and `ack_failures` do not exist in `tracker_status` or its API; the latter is discussed in separate traffic/RF tooling. | HECHO; treating absent samples as offline is a BUG to avoid. | `collector/main.py::tracker_points`; `collector/decode.py::tracker_health`; `api/main.py::_TRACKER_FIELDS`; `trafico.html`; `tools/calibrar_zigbee.py`. |
| The current canvas paints modelled geometric radio reach via `radius`; this is distinct from historical telemetry availability and instantaneous `health`. | HECHO / INTENCIONAL distinction; combining the layers would be a BUG. | `index.html::draw`, especially “radios de cobertura” and “TCU fuera del radio”. |
| The browser joins layout TCUs to `/live` by `scadaIdx`, derived from sorting `(gw,tn)`. `config/plants.yml` identifies the NCUs as `NCU1`/`NCU2` while the built-in layout uses `NCU-01`/`NCU-02`; NCU2 declares a sparse 109 and missing 108 while the collector polls `1..tcu_count` (`1..107`). The API does not filter the Influx plant tag. | HECHO / BUG for end-to-end identity; **P0** for coloring actual canvas assets with historical data. | `index.html::buildScadaIndex`, `scadaOf`, `fiHash`; `config/plants.yml`; `collector/drivers/modbus_ncu.py::read_trackers`; `api/main.py::history` and `live`. |
| `config/plants.yml` has a plant ID and poll interval of 30 s but no approved IANA plant timezone, commissioned SCADA-to-asset bindings, source quality or topology revision. Influx samples use implicit write timestamps. There is no trustworthy denominator for a full-day expected count if the cadence or commissioning status changed. | HECHO / UNKNOWN: timezone, commissioned intervals, completeness policy. **P0** for trustworthy availability percentages across the whole plant. | `config/plants.yml`; `collector/main.py::tracker_points`; `README.md` timestamp and identity notes. |
| The El Burgo `06_PLANT` package in `SolarGPTfull` PR #273 contains `plants/23003/identity/registry-r1.json` with `operational_asset_key` and `modbus_slave` bindings. Its records are provisional and the PR is open; the package is not consumed by `scada` or present on `SolarGPTfull/main`. | HECHO. Potential read-only input after an explicit adapter contract, not a license to reconstruct bindings or assign new IDs. | `IMoriana3/SolarGPTfull` PR #273, `plants/23003/identity/{registry-r1.json,mapping.yaml}`, `docs/audit/06-PLANT-IDENTITY-ALTA-EXEC__SolarGPTfull.md`. |

**P0 decision for this branch:** Stop before implementing a measured layer or comparative chart linked from layout assets. With the current positional join, data can silently be assigned to the wrong physical TCU. The user explicitly requires no inference from order, index, name or count, and instructs implementation only if there is no P0 architectural contradiction. This audit records the gate; it does not declare the milestone delivered.

## 2. IMPLEMENTATION PLAN (PROPUESTA; pending 00_MASTER identity decisions)

1. Establish a read-only 06_PLANT adapter with explicit `(plant_id, ncu binding, tcu binding, valid time) -> asset_id` resolution. Require the package revision and provenance; reject zero, duplicate, provisional-for-critical, expired and cross-plant matches according to the approved consumer policy. Replace positional joins in SCADA overlays. Reconcile `NCU1` vs `NCU-01` through declared bindings, never string normalization. Repair sparse TCU polling against the commissioned inventory. No new identity authority or UUID generation in SCADA.
2. Declare plant IANA timezone and historical cadence/quality policy in the existing deployment contract or the approved Plant Package. Show dates as plant-local values, send unambiguous UTC `from/to` instants. A “previous/next day” button shifts both local wall-clock endpoints by one calendar day, then reconverts to UTC; across daylight-saving transitions elapsed UTC time may be 23 or 25 h. Resolve repeated/nonexistent wall times explicitly in UX. Preserve both selected TCU assets and variables.
3. Extend the existing Influx-backed history query with bounded, validated UTC `from/to` and optional second explicitly resolved `asset_id` (or a bounded list), return source timestamps and shared time-axis semantics. Preserve legacy `hours` for existing callers; avoid averaging categorical `health`/states. Query no other historical store.
4. In the backend, aggregate actual received samples, planned expected samples (only when a valid cadence and asset lifecycle are known), gap durations, observed `health=offline` proportion and coverage/quality provenance for a complete plant-local day. Never convert missing telemetry into observed offline. With no reliable denominator, no commissioned binding, incomplete day or missing evidence, return `UNKNOWN` with a reason. RSSI and `ack_failures` remain unavailable until an actual supported source and signal contract exist. Thresholds for green/amber/red need 08_COMMS / 00_MASTER approval; otherwise use a neutral numeric or unknown legend without making up cutoffs.
5. Add the historical chart and measured layer to existing `index.html` and its TCU card: variables as interactive legend with one stable color per variable, line style per TCU, explicit comparison asset, plant and NCU filters, click through to detail, visible separation of modelled reach / measured availability / instantaneous health. Keep the legend and renderer on one color map. Reuse the existing canvas and API rather than building another SCADA.
6. Add focused backend and browser tests for identity collision/reassignment, absent peer series, range limits, DST, retained selection, color equality, interval gaps, incomplete day, no samples, offline-vs-missing, NCU isolation and unknown evidence. Verify full suite and browser state before considering completion.

## 3. FILES TO CHANGE (planned, no implementation yet)

| Path | Planned change |
| --- | --- |
| `config/plants.yml` and the agreed 06_PLANT package consumer | Declare timezone, cadence provenance and explicit external identity/binding input; do not create another plant model. |
| `collector/drivers/modbus_ncu.py`, `collector/main.py` | Consume commissioned sparse inventory and persist unambiguous binding/provenance, if the approved contract calls for it. |
| `api/main.py` | Extend history over Influx; validated identity, temporal aggregation and measured metrics endpoints. |
| `index.html` | Existing card/chart UI and measured overlay on existing plant canvas, with separate layer selectors. Remove positional runtime join in operational views. |
| `tools/test_api.py`, `tests/` or existing browser test harness | Contract, DST, aggregation and UI interaction tests. |
| `README.md`, `docs/audit/SCADA-HISTORICAL-MEASURED-COVERAGE.md` | Usage, metric semantics, decisions and verified outcomes. |

## Decisions to elevate to 00_MASTER

1. Authoritative 06_PLANT package revision and whether provisional El Burgo bindings permit these read-only historical views; how SCADA obtains the package and validates its hash.
2. Source of approved IANA timezone and cadence history per plant/NCU; response when those are unavailable.
3. Whether the free chart the requester sees belongs to another frontend/repository; link to its actual source before modifying UX.
4. Semantics and approved thresholds for measured telemetry availability versus communications offline, and eventual RF prediction comparison.

## Validation at audit gate

Code paths inspected from `main`; `python tools/test_api.py` reported a missing `fastapi` dependency and exited 0 with an `AVISO`, so it did **not** execute assertions. No milestone tests have been added or passed. No UI screenshot represents the requested functions.
