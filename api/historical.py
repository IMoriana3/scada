"""Contractual historical reads over the existing tracker_status Influx series."""
from datetime import date, datetime, time, timedelta, timezone
from math import ceil
from zoneinfo import ZoneInfo


CHART_FIELDS = ("tilt_angle", "target_angle", "soc", "soh", "battery_voltage",
                "battery_current", "temp_battery", "temp_pcb", "motor_current",
                "panel_voltage", "comms_age_s")


def flux_time(instant):
    return instant.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def utc_range(start, stop):
    if start.tzinfo is None or stop.tzinfo is None or stop <= start:
        raise ValueError("from/to requieren offset y from < to")
    return start.astimezone(timezone.utc), stop.astimezone(timezone.utc)


def day_bounds(local_day, zone):
    tz = ZoneInfo(zone)
    start = datetime.combine(local_day, time.min, tzinfo=tz)
    stop = datetime.combine(local_day + timedelta(days=1), time.min, tzinfo=tz)
    return utc_range(start, stop)


def chart_query(bucket, plant, binding, fields, start, stop, window_s):
    # All interpolated tags are validated in the caller and checked here as well.
    if not fields or any(f not in CHART_FIELDS for f in fields):
        raise ValueError("Campo histórico no permitido")
    if any(not str(tag).replace("-", "").replace("_", "").isalnum()
           for tag in (bucket, plant, binding["ncu"], binding["tcu"])):
        raise ValueError("Tag Influx no válido")
    flt = " or ".join(f'r._field == "{f}"' for f in fields)
    return f'''from(bucket: "{bucket}")
  |> range(start: {flux_time(start)}, stop: {flux_time(stop)})
  |> filter(fn: (r) => r._measurement == "tracker_status" and r.plant == "{plant}" and r.source == "modbus"
       and r.ncu == "{binding['ncu']}" and r.tcu == "{binding['tcu']}" and ({flt}))
  |> aggregateWindow(every: {window_s}s, fn: mean, createEmpty: false)
'''


def history_for_assets(query_api, bucket, identity, asset_ids, start, stop, fields):
    start, stop = utc_range(start, stop)
    if not 1 <= len(asset_ids) <= 8 or len(set(asset_ids)) != len(asset_ids):
        raise ValueError("Se requieren 1–8 asset_id distintos")
    if not fields or any(f not in CHART_FIELDS for f in fields):
        raise ValueError("Campos históricos inválidos")
    window_s = max(300, 60 * ceil((stop - start).total_seconds() / 1500 / 60))
    rows = []
    for asset in asset_ids:
        binding = identity.resolve(asset, start)
        if identity.resolve(asset, stop - timedelta(microseconds=1)) != binding:
            raise ValueError("El binding cambia dentro del intervalo")
        series = {f: [] for f in fields}
        q = chart_query(bucket, identity.registry["plant_id"], binding, fields, start, stop, window_s)
        for table in query_api.query(q):
            for rec in table.records:
                if rec.get_field() in series:
                    series[rec.get_field()].append({"t": rec.get_time().astimezone(timezone.utc).isoformat(),
                                                     "v": rec.get_value()})
        rows.append({"asset_id": asset, "ncu": binding["ncu"], "tcu": binding["tcu"],
                     "series": series})
    return {"from": start.isoformat(), "to": stop.isoformat(),
            "timezone": identity.timezone, "window_s": window_s,
            "read_only": True, "operationally_usable": identity.operationally_usable,
            "source": "modbus", "legacy_without_source": "excluded",
            "assets": rows}


def aggregate_samples(samples, start, stop, cadence_s, *, complete):
    """Missing samples are gaps, never observed equipment offline."""
    expected = round((stop - start).total_seconds() / cadence_s)
    if expected <= 0:
        raise ValueError("Cadencia inválida")
    slots = {}
    for timestamp, health in samples:
        ts = timestamp.astimezone(timezone.utc)
        if start <= ts < stop:
            slot = min(expected - 1, int((ts - start).total_seconds() / cadence_s))
            slots.setdefault(slot, health)
    received = len(slots)
    offline = sum(1 for health in slots.values() if health == "offline")
    gaps = []
    previous = -1
    for slot in sorted(slots) + [expected]:
        if slot - previous > 1:
            gaps.append({"from": (start + timedelta(seconds=(previous + 1) * cadence_s)).isoformat(),
                         "to": (start + timedelta(seconds=slot * cadence_s)).isoformat(),
                         "missing": slot - previous - 1})
        previous = slot
    known = complete and received >= 2
    return {"status": "MEASURED" if known else "UNKNOWN",
            "reason": None if known else ("INCOMPLETE_DAY" if not complete else "INSUFFICIENT_SAMPLES"),
            "expected": expected, "received": received, "gaps": gaps,
            "telemetry_availability_pct": round(received / expected * 100, 2) if known else None,
            "offline_observed_pct": round(offline / received * 100, 2) if known else None,
            "offline_samples": offline, "cadence_s": cadence_s,
            "quality": "collector_write_time; no per-field quality flag"}


def measured_day(query_api, bucket, identity, local_day, *, ncu_asset_id=None, now=None):
    start, stop = day_bounds(local_day, identity.timezone)
    now = now or datetime.now(timezone.utc)
    ncu_cfg = {n["id"]: n for n in identity.config["ncus"]}
    inventory = [r for r in identity.inventory(start) if ncu_asset_id is None
                 or r["ncu_asset_id"] == ncu_asset_id]
    if ncu_asset_id is not None and not inventory:
        raise ValueError("NCU fuera del inventario configurado")
    if identity.inventory(stop - timedelta(microseconds=1)) != identity.inventory(start):
        raise ValueError("El inventario cambia durante el día")
    q = f'''from(bucket: "{bucket}")
  |> range(start: {flux_time(start)}, stop: {flux_time(stop)})
  |> filter(fn: (r) => r._measurement == "tracker_status" and r.plant == "{identity.registry['plant_id']}" and r.source == "modbus" and r._field == "health")
'''
    observed = {}
    valid = {(r["ncu"], str(r["tcu"])) for r in inventory}
    # Stream on real InfluxDB: a whole plant-day can contain >600k records.
    records = (query_api.query_stream(q) if hasattr(query_api, "query_stream") else
               (rec for table in query_api.query(q) for rec in table.records))
    for rec in records:
        v = rec.values
        key = (v.get("ncu"), v.get("tcu"))
        if key in valid:
            observed.setdefault(key, []).append((rec.get_time(), rec.get_value()))
    assets = []
    for row in inventory:
        cadence = ncu_cfg[row["ncu"]].get("interval_s", identity.config["polling"]["interval_s"])
        if not isinstance(cadence, (int, float)) or cadence <= 0:
            raise ValueError("Cadencia operativa no declarada")
        metric = aggregate_samples(observed.get((row["ncu"], str(row["tcu"])), []),
                                   start, stop, cadence, complete=now >= stop)
        assets.append({"asset_id": row["asset_id"], "layout_key": row["layout_key"],
                       "ncu_asset_id": row["ncu_asset_id"], **metric})
    return {"date": local_day.isoformat(), "timezone": identity.timezone,
            "from": start.isoformat(), "to": stop.isoformat(),
            "read_only": True, "operationally_usable": identity.operationally_usable,
            "metric": "telemetry_availability", "source": "modbus",
            "legacy_without_source": "excluded", "rf_modelled": False,
            "thresholds": None, "assets": assets}
