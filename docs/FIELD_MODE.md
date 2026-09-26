# Factiun Field Mode v1

## Purpose

Field Mode is a mobile/offline surface of the existing SCADA. It does not
create a second plant model, telemetry store or solar engine.

The asset key is always the canonical \`asset_id\` served by \`/assets/live\`.

## What v1 does

- Loads canonical tracker identity and live SCADA telemetry.
- Caches the last asset snapshot for offline use.
- Captures a signed physical tracker angle; the phone sensor supplies only the
  magnitude and the technician confirms sign to avoid mixing angle conventions.
- Compares physical angle against encoder and target values already measured by
  the SCADA.
- Captures tracker-specific checklist results.
- Captures manual Voc/Isc evidence without calculating an expected solar value.
- Compares simultaneous string/MPPT measurements against their median; power
  mode normalises by module count. This is a relative diagnostic only.
- Stores notes and compressed visit photos.
- Persists inspection bundles in IndexedDB and exports canonical JSON.
- Installs as a PWA and caches its static shell for operation without coverage.

## Hard boundaries

### No duplicated solar physics

Field Mode contains no solar position, clear-sky model, transposition, tracker
or backtracking equation. Expected production / expected Voc/Isc must later be
served by an approved canonical SolarGPT endpoint if that workflow is added.

### No invented inspection backend

The current SCADA persistence is InfluxDB for time-series telemetry. There is no
approved contract/storage owner for inspection records and photos.

Therefore v1 deliberately marks:

\`server_sync = UNAVAILABLE_UNTIL_CONTRACT_APPROVED\`

and persists inspection bundles on the device plus JSON export. Adding an
arbitrary table, local server file or second database would violate the single
source-of-truth rule.

## Inspection schema v1

Fields:

- schema_version
- inspection_id
- asset_id
- layout_key
- started_at / completed_at
- telemetry_snapshot
- measurements
- strings
- checklist
- notes
- photos
- provenance

The bundle never resolves identity from name similarity, position or list index.

## Next contract needed

A future write path requires a MASTER decision for the operational inspection
store and API. Once approved, the PWA can sync the exact same bundle without
changing field semantics.
