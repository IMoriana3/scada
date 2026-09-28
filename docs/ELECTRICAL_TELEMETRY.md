# Electrical telemetry contract v1

## Responsibility

SCADA owns measured electrical telemetry. It does not calculate PV expected
power, string current, irradiance or electrical losses.

SolarGPT remains the owner of expected electrical physics.

## Canonical asset key

Every electrical measurement is attached to an explicit Plant Package
`asset_id`.

Supported asset types:

- `inverter`
- `mppt`
- `string`

No asset is created or resolved from a channel name, Modbus address, list
position, inverter number or string number.

## Measured sample

```json
{
  "schema_version": "1.0.0",
  "asset_id": "<canonical UUIDv4>",
  "asset_type": "string",
  "observed_at": "2026-09-28T12:00:00+00:00",
  "source": "vendor-adapter",
  "source_channel": "optional native channel locator",
  "quality": "GOOD",
  "metrics": {
    "dc_current_a": 11.8
  }
}
```

Timestamp must be timezone-aware and represent the observation instant. It must
not be replaced by an arbitrary API-request time.

## Canonical units

String / MPPT:

- `dc_voltage_v`
- `dc_current_a`
- `dc_power_kw`

Inverter additionally supports:

- `ac_power_kw`
- `active_power_limit_pct`
- `temperature_c`

All numeric values must be finite.

## InfluxDB

The collector adapter writes canonical samples as:

```text
measurement = electrical_status
tags:
  plant
  asset_id
  asset_type
  source
  source_channel (optional)
fields:
  quality
  canonical measured metrics
time:
  observed_at
```

Vendor drivers are responsible only for translating native protocol/register
values into this contract. They must not implement expected PV physics.

## API

`GET /assets/electrical/live`

Optional:

- `asset_id=<UUID>`
- `max_age_s=<seconds>`

The endpoint only exposes assets present in the Plant Package registry when the
package declares `electrical.topology.available = true`.

Possible states include:

- `OK`
- `NO_MEASURED_ELECTRICAL_TELEMETRY`
- `UNAVAILABLE_NO_ELECTRICAL_TOPOLOGY`

Unknown assets, mismatched asset types and malformed samples fail closed.

## El Burgo I

Current Plant Package evidence does not contain explicit inverter/MPPT/string
identity and DC allocation. Therefore the correct production state is:

```text
UNAVAILABLE_NO_ELECTRICAL_TOPOLOGY
```

This is not replaced with guessed inverter numbers from tracker rows.

To activate measured electrical telemetry we still need an explicit source such
as:

- inverter Modbus map + channel inventory;
- PPC/SCADA export;
- manufacturer configuration export;
- verified DC/as-built schedule.

That source must map each native channel to a canonical electrical `asset_id`.

## Next step

Once measured channels exist, Actual-vs-Expected will combine:

```text
SCADA measured sample
        +
SolarGPT expected electrical sample
        +
Plant Electrical Topology
        =
residual + diagnostic evidence
```

The residual/diagnostic layer must remain separate from the measured telemetry
contract.
