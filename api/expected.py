"""Read-only Actual vs Expected adapter.

SCADA owns measured state. SolarGPT owns expected tracker physics. This module
only validates/join their contracts by canonical asset_id and computes
residuals. It contains no solar, tracking, backtracking or supervisor physics.
"""
from __future__ import annotations

from datetime import datetime
import json
import math
from typing import Callable, Any
from urllib.parse import urlencode
from urllib.request import Request, urlopen


POWER_UNAVAILABLE = "UNKNOWN_NO_MEASURED_POWER_CHANNEL"


class ExpectedUnavailable(RuntimeError):
    """SolarGPT expected state cannot be used for this actual snapshot."""


def _aware_iso(value: Any) -> datetime:
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (TypeError, ValueError) as exc:
        raise ExpectedUnavailable("ACTUAL_TIMESTAMP_UNKNOWN") from exc
    if dt.tzinfo is None or dt.utcoffset() is None:
        raise ExpectedUnavailable("ACTUAL_TIMESTAMP_UNKNOWN")
    return dt


def _finite(value):
    if value is None or value == "":
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def fetch_expected(
    base_url: str,
    *,
    asset_id: str,
    ts: str,
    soc=None,
    timeout: float = 3.0,
    transport: Callable[[str, float], dict] | None = None,
) -> dict:
    """Fetch SolarGPT expected tracking for the exact measured instant.

    Only evidence SCADA actually owns is forwarded. In v1 that is asset_id,
    timestamp and optionally SOC. Wind/hail/snow are deliberately omitted until
    their asset/scope mapping is explicit, so SolarGPT returns operational
    expected as incomplete instead of assuming safe weather.
    """
    base = str(base_url or "").strip().rstrip("/")
    if not base:
        raise ExpectedUnavailable("SOLARGPT_EXPECTED_URL_NOT_CONFIGURED")
    if not asset_id or str(asset_id).strip() != str(asset_id):
        raise ExpectedUnavailable("ASSET_ID_INVALID")
    _aware_iso(ts)

    params = {"asset_id": asset_id, "ts": ts}
    soc_num = _finite(soc)
    if soc_num is not None:
        params["soc"] = str(soc_num)
    url = base + "/expected/tracker?" + urlencode(params)

    if transport is None:
        def transport(request_url: str, request_timeout: float) -> dict:
            req = Request(request_url, headers={"Accept": "application/json"})
            with urlopen(req, timeout=request_timeout) as response:
                if response.status != 200:
                    raise ExpectedUnavailable(
                        f"SOLARGPT_HTTP_{response.status}")
                return json.loads(response.read().decode("utf-8"))

    try:
        payload = transport(url, timeout)
    except ExpectedUnavailable:
        raise
    except Exception as exc:
        raise ExpectedUnavailable(
            f"SOLARGPT_UNAVAILABLE:{type(exc).__name__}") from exc

    if not isinstance(payload, dict):
        raise ExpectedUnavailable("SOLARGPT_RESPONSE_INVALID")
    if payload.get("asset_id") != asset_id:
        raise ExpectedUnavailable("SOLARGPT_ASSET_ID_MISMATCH")
    if payload.get("status") == "ERROR":
        raise ExpectedUnavailable(
            "SOLARGPT_EXPECTED_ERROR:" + str(payload.get("error") or "unknown"))
    return payload


def compare_actual_expected(actual: dict, expected: dict | None, *,
                            max_age_s: float = 120.0,
                            expected_error: str | None = None) -> dict:
    """Compare one exact SCADA snapshot with the SolarGPT expectation.

    Comparison is fail-closed: no exact observation timestamp, no freshness
    evidence, stale comms, or no expected tracking => no angle residual.
    """
    if max_age_s <= 0:
        raise ValueError("max_age_s must be > 0")
    asset_id = actual.get("asset_id")
    if not asset_id:
        raise ValueError("actual snapshot requires asset_id")

    observed_at = actual.get("observed_at")
    timestamp_ok = True
    try:
        _aware_iso(observed_at)
    except ExpectedUnavailable:
        timestamp_ok = False

    age = _finite(actual.get("comms_age_s"))
    freshness = (
        "UNKNOWN" if age is None
        else ("STALE" if age > max_age_s else "FRESH")
    )

    exp_tracking = (
        _finite(expected.get("expected_tracking_angle_deg"))
        if expected else None
    )
    exp_operational = (
        _finite(expected.get("expected_operational_angle_deg"))
        if expected else None
    )
    tilt = _finite(actual.get("tilt_angle"))
    target = _finite(actual.get("target_angle"))

    compare_ok = timestamp_ok and freshness == "FRESH" and exp_tracking is not None
    residuals = {
        "encoder_minus_expected_tracking_deg": (
            tilt - exp_tracking if compare_ok and tilt is not None else None),
        "target_minus_expected_tracking_deg": (
            target - exp_tracking if compare_ok and target is not None else None),
        "encoder_minus_expected_operational_deg": (
            tilt - exp_operational
            if compare_ok and exp_operational is not None and tilt is not None
            else None),
        "target_minus_expected_operational_deg": (
            target - exp_operational
            if compare_ok and exp_operational is not None and target is not None
            else None),
    }

    if not timestamp_ok:
        status = "ACTUAL_TIMESTAMP_UNKNOWN"
    elif freshness == "UNKNOWN":
        status = "ACTUAL_FRESHNESS_UNKNOWN"
    elif freshness == "STALE":
        status = "STALE_ACTUAL"
    elif expected is None:
        status = "ACTUAL_ONLY"
    elif exp_tracking is None:
        status = "EXPECTED_UNKNOWN"
    elif expected.get("expected_operational_angle_deg") is None:
        status = "PARTIAL"
    else:
        status = "OK"

    return {
        "schema_version": "1.0.0",
        "status": status,
        "asset_id": asset_id,
        "actual": actual,
        "expected": expected,
        "expected_error": expected_error,
        "freshness": {
            "status": freshness,
            "comms_age_s": age,
            "max_age_s": float(max_age_s),
            "observed_at_valid": timestamp_ok,
        },
        "residuals": residuals,
        "power": {
            "status": POWER_UNAVAILABLE,
            "actual_kw": None,
            "expected_kw": None,
            "residual_kw": None,
        },
        "provenance": {
            "join_key": "asset_id",
            "actual_owner": "SCADA",
            "expected_owner": "SolarGPT",
            "physics_in_scada": False,
        },
    }
