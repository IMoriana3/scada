"""Explainable electrical diagnostic rules for sibling strings.

This layer consumes measured and expected evidence. It never mutates telemetry,
calculates PV expected physics, or infers topology.
"""
from __future__ import annotations

from statistics import median
from uuid import UUID
import math


class ElectricalDiagnosticError(ValueError):
    """Diagnostic evidence is malformed or not comparable."""


def _finite(value):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _uuid4(value: str) -> str:
    try:
        parsed = UUID(str(value))
    except ValueError:
        raise ElectricalDiagnosticError("asset_id must be canonical UUIDv4") from None
    canonical = str(parsed)
    if canonical != str(value) or parsed.version != 4:
        raise ElectricalDiagnosticError("asset_id must be canonical UUIDv4")
    return canonical


def diagnose_sibling_strings(
    rows: list[dict],
    *,
    mppt_asset_id: str,
    localized_threshold_pct: float = 10.0,
    common_mode_threshold_pct: float = 10.0,
    max_common_dispersion_pct: float = 5.0,
    min_siblings: int = 3,
    curtailment_active: bool = False,
) -> dict:
    """Diagnose one MPPT from comparable measured+expected string rows.

    Each row requires:
      asset_id, actual_dc_power_kw, expected_dc_power_kw

    Optional evidence:
      quality ("GOOD" required when present), freshness ("FRESH" required when
      present).

    The diagnostic operates on performance ratio actual/expected. It does not
    call a fault unless the pattern supports that statement.
    """
    _uuid4(mppt_asset_id)
    if min_siblings < 2:
        raise ValueError("min_siblings must be >= 2")
    for name, value in (
        ("localized_threshold_pct", localized_threshold_pct),
        ("common_mode_threshold_pct", common_mode_threshold_pct),
        ("max_common_dispersion_pct", max_common_dispersion_pct),
    ):
        if value <= 0:
            raise ValueError(f"{name} must be > 0")

    normalized = []
    for row in rows or []:
        asset_id = _uuid4(row.get("asset_id"))
        actual = _finite(row.get("actual_dc_power_kw"))
        expected = _finite(row.get("expected_dc_power_kw"))
        quality = row.get("quality")
        freshness = row.get("freshness")
        usable = (
            actual is not None and expected is not None and expected > 0
            and (quality in (None, "GOOD"))
            and (freshness in (None, "FRESH"))
        )
        ratio = actual / expected if usable else None
        normalized.append({
            "asset_id": asset_id,
            "actual_dc_power_kw": actual,
            "expected_dc_power_kw": expected,
            "quality": quality,
            "freshness": freshness,
            "ratio": ratio,
        })

    usable = [r for r in normalized if r["ratio"] is not None]
    if len(usable) < min_siblings:
        return {
            "schema_version": "1.0.0",
            "status": "UNKNOWN_INSUFFICIENT_EVIDENCE",
            "mppt_asset_id": mppt_asset_id,
            "rows": normalized,
            "diagnoses": [],
            "evidence": {
                "usable_strings": len(usable),
                "required_strings": min_siblings,
            },
        }

    ratios = [r["ratio"] for r in usable]
    med = median(ratios)
    dispersion = max(ratios) - min(ratios)

    if curtailment_active:
        return {
            "schema_version": "1.0.0",
            "status": "CURTAILMENT_PRESENT_NO_FAULT_ATTRIBUTION",
            "mppt_asset_id": mppt_asset_id,
            "rows": normalized,
            "diagnoses": [],
            "evidence": {
                "median_performance_ratio": med,
                "dispersion_pct": dispersion * 100.0,
                "curtailment_active": True,
            },
        }

    local_cut = localized_threshold_pct / 100.0
    diagnoses = []
    for row in usable:
        deviation_from_siblings = row["ratio"] - med
        if deviation_from_siblings <= -local_cut:
            diagnoses.append({
                "asset_id": row["asset_id"],
                "code": "LOCALIZED_STRING_UNDERPERFORMANCE",
                "severity": "ALARM",
                "ratio": row["ratio"],
                "deviation_from_sibling_median_pct": deviation_from_siblings * 100.0,
                "interpretation": (
                    "localized underperformance relative to sibling strings; "
                    "not explained by an MPPT-wide common-mode drop"),
                "recommended_checks": [
                    "connectors",
                    "fuses",
                    "dc_cabling",
                    "module_damage_or_disconnect",
                    "measure_voc",
                    "measure_isc",
                ],
            })

    common_cut = 1.0 - common_mode_threshold_pct / 100.0
    common_disp = max_common_dispersion_pct / 100.0
    if med < common_cut and dispersion <= common_disp:
        return {
            "schema_version": "1.0.0",
            "status": "COMMON_MODE_UNDERPERFORMANCE",
            "mppt_asset_id": mppt_asset_id,
            "rows": normalized,
            "diagnoses": [],
            "evidence": {
                "median_performance_ratio": med,
                "dispersion_pct": dispersion * 100.0,
            },
            "interpretation": (
                "all comparable sibling strings are similarly below expected; "
                "do not attribute this to one string"),
            "next_evidence": [
                "mppt_voltage_current",
                "inverter_state",
                "poa_quality",
                "tracking_state",
                "curtailment_or_ppc_limit",
            ],
        }

    return {
        "schema_version": "1.0.0",
        "status": "ANOMALY" if diagnoses else "OK",
        "mppt_asset_id": mppt_asset_id,
        "rows": normalized,
        "diagnoses": diagnoses,
        "evidence": {
            "median_performance_ratio": med,
            "dispersion_pct": dispersion * 100.0,
        },
    }


__all__ = ["ElectricalDiagnosticError", "diagnose_sibling_strings"]
