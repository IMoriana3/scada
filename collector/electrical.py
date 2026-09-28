"""InfluxDB adapter for canonical measured electrical telemetry."""
from __future__ import annotations

from influxdb_client import Point

from electrical_contract import validate_electrical_sample


def electrical_point(plant_id: str, sample: dict) -> Point:
    """Build one Influx point from an already identified measured sample."""
    if not str(plant_id or "").strip():
        raise ValueError("plant_id is required")
    row = validate_electrical_sample(sample)
    point = (
        Point("electrical_status")
        .tag("plant", str(plant_id))
        .tag("asset_id", row["asset_id"])
        .tag("asset_type", row["asset_type"])
        .tag("source", row["source"])
    )
    if row["source_channel"] is not None:
        point.tag("source_channel", row["source_channel"])
    point.field("quality", row["quality"])
    for field, value in row["metrics"].items():
        point.field(field, float(value))
    point.time(row["observed_at"])
    return point


__all__ = ["electrical_point"]
