"""Canonical measured-electrical telemetry contract for SCADA.

This module contains no PV physics and no vendor register map. Vendor adapters
must translate their native channels into this contract using an explicit
canonical asset_id supplied by Plant Package identity.
"""
from __future__ import annotations

from datetime import datetime
import math
from typing import Any
from uuid import UUID

SCHEMA_VERSION = "1.0.0"

ELECTRICAL_ASSET_TYPES = frozenset({"inverter", "mppt", "string"})
QUALITY_VALUES = frozenset({"GOOD", "BAD", "UNKNOWN"})

FIELDS_BY_TYPE = {
    "inverter": frozenset({
        "dc_voltage_v",
        "dc_current_a",
        "dc_power_kw",
        "ac_power_kw",
        "active_power_limit_pct",
        "temperature_c",
    }),
    "mppt": frozenset({
        "dc_voltage_v",
        "dc_current_a",
        "dc_power_kw",
    }),
    "string": frozenset({
        "dc_voltage_v",
        "dc_current_a",
        "dc_power_kw",
    }),
}
ALL_FIELDS = frozenset().union(*FIELDS_BY_TYPE.values())


class ElectricalTelemetryError(ValueError):
    """A measured electrical sample violates the canonical contract."""


def canonical_uuid4(value: Any) -> str:
    raw = str(value)
    try:
        parsed = UUID(raw)
    except (TypeError, ValueError, AttributeError):
        raise ElectricalTelemetryError("asset_id must be canonical UUID v4") from None
    if parsed.version != 4 or raw != str(parsed):
        raise ElectricalTelemetryError("asset_id must be canonical UUID v4")
    return raw


def aware_timestamp(value: Any) -> datetime:
    if isinstance(value, datetime):
        dt = value
    else:
        try:
            dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        except (TypeError, ValueError):
            raise ElectricalTelemetryError(
                "observed_at must be RFC3339 with timezone") from None
    if dt.tzinfo is None or dt.utcoffset() is None:
        raise ElectricalTelemetryError(
            "observed_at must be RFC3339 with timezone")
    return dt


def _finite(value: Any, field: str) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        raise ElectricalTelemetryError(
            f"{field} must be a finite number") from None
    if not math.isfinite(number):
        raise ElectricalTelemetryError(f"{field} must be a finite number")
    return number


def validate_electrical_sample(sample: dict[str, Any]) -> dict[str, Any]:
    """Return one normalized measured sample or fail closed."""
    if not isinstance(sample, dict):
        raise ElectricalTelemetryError("electrical sample must be an object")

    asset_id = canonical_uuid4(sample.get("asset_id"))
    asset_type = str(sample.get("asset_type") or "")
    if asset_type not in ELECTRICAL_ASSET_TYPES:
        raise ElectricalTelemetryError(
            f"asset_type must be one of {sorted(ELECTRICAL_ASSET_TYPES)}")

    observed_at = aware_timestamp(sample.get("observed_at"))
    source = str(sample.get("source") or "").strip()
    if not source:
        raise ElectricalTelemetryError("source is required")
    quality = str(sample.get("quality") or "UNKNOWN").upper()
    if quality not in QUALITY_VALUES:
        raise ElectricalTelemetryError(
            f"quality must be one of {sorted(QUALITY_VALUES)}")

    source_channel = sample.get("source_channel")
    if source_channel is not None:
        source_channel = str(source_channel).strip()
        if not source_channel:
            raise ElectricalTelemetryError(
                "source_channel cannot be blank when present")

    metrics = sample.get("metrics")
    if not isinstance(metrics, dict) or not metrics:
        raise ElectricalTelemetryError("metrics must be a non-empty object")
    unknown = sorted(set(metrics) - FIELDS_BY_TYPE[asset_type])
    if unknown:
        raise ElectricalTelemetryError(
            f"metrics not valid for {asset_type}: {unknown}")
    normalized_metrics = {
        field: _finite(value, field) for field, value in metrics.items()
    }
    if "active_power_limit_pct" in normalized_metrics:
        limit = normalized_metrics["active_power_limit_pct"]
        if not 0.0 <= limit <= 100.0:
            raise ElectricalTelemetryError(
                "active_power_limit_pct must be within [0, 100]")

    return {
        "schema_version": SCHEMA_VERSION,
        "asset_id": asset_id,
        "asset_type": asset_type,
        "observed_at": observed_at.isoformat(),
        "source": source,
        "source_channel": source_channel,
        "quality": quality,
        "metrics": normalized_metrics,
    }


__all__ = [
    "ALL_FIELDS", "ELECTRICAL_ASSET_TYPES", "ElectricalTelemetryError",
    "FIELDS_BY_TYPE", "QUALITY_VALUES", "SCHEMA_VERSION", "aware_timestamp",
    "canonical_uuid4", "validate_electrical_sample",
]
