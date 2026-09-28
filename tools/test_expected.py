#!/usr/bin/env python3
"""Contract tests for SCADA Actual-vs-Expected adapter, no network."""
from datetime import datetime, timezone
import os
import sys
from urllib.parse import parse_qs, urlparse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "api"))

from expected import (  # noqa: E402
    ExpectedUnavailable,
    POWER_UNAVAILABLE,
    compare_actual_expected,
    fetch_expected,
)


ASSET = "11111111-1111-4111-8111-111111111111"
TS = "2026-09-28T08:00:00+00:00"


def _actual(**overrides):
    base = {
        "asset_id": ASSET,
        "observed_at": TS,
        "tilt_angle": 10.0,
        "target_angle": 11.0,
        "soc": 82.0,
        "comms_age_s": 15.0,
    }
    base.update(overrides)
    return base


def _expected(**overrides):
    base = {
        "asset_id": ASSET,
        "status": "PARTIAL",
        "expected_tracking_angle_deg": 12.0,
        "expected_operational_angle_deg": None,
        "operational_status": "INCOMPLETE_SAFETY_INPUTS",
    }
    base.update(overrides)
    return base


def test_fetch_uses_exact_asset_timestamp_and_only_owned_safety_evidence():
    seen = {}

    def transport(url, timeout):
        seen["url"] = url
        seen["timeout"] = timeout
        return _expected()

    out = fetch_expected(
        "http://solar.local/",
        asset_id=ASSET,
        ts=TS,
        soc=82,
        transport=transport,
    )
    q = parse_qs(urlparse(seen["url"]).query)
    assert q["asset_id"] == [ASSET]
    assert q["ts"] == [TS]
    assert q["soc"] == ["82.0"]
    assert "wind_ms" not in q
    assert "hail" not in q
    assert "snow_coverage" not in q
    assert out["asset_id"] == ASSET


def test_fetch_rejects_mismatched_identity():
    def transport(url, timeout):
        return _expected(asset_id="22222222-2222-4222-8222-222222222222")

    try:
        fetch_expected("http://solar", asset_id=ASSET, ts=TS,
                       transport=transport)
    except ExpectedUnavailable as exc:
        assert str(exc) == "SOLARGPT_ASSET_ID_MISMATCH"
    else:
        raise AssertionError("identity mismatch accepted")


def test_residuals_are_actual_minus_expected_and_power_is_unknown():
    out = compare_actual_expected(_actual(), _expected())
    assert out["status"] == "PARTIAL"
    assert out["residuals"]["encoder_minus_expected_tracking_deg"] == -2.0
    assert out["residuals"]["target_minus_expected_tracking_deg"] == -1.0
    assert out["residuals"]["encoder_minus_expected_operational_deg"] is None
    assert out["power"]["status"] == POWER_UNAVAILABLE
    assert out["power"]["actual_kw"] is None
    assert out["provenance"]["physics_in_scada"] is False


def test_stale_actual_blocks_all_residuals():
    out = compare_actual_expected(
        _actual(comms_age_s=121.0), _expected(), max_age_s=120)
    assert out["status"] == "STALE_ACTUAL"
    assert all(v is None for v in out["residuals"].values())


def test_missing_freshness_blocks_comparison():
    out = compare_actual_expected(
        _actual(comms_age_s=None), _expected())
    assert out["status"] == "ACTUAL_FRESHNESS_UNKNOWN"
    assert all(v is None for v in out["residuals"].values())


def test_missing_timestamp_blocks_comparison():
    out = compare_actual_expected(
        _actual(observed_at=None), _expected())
    assert out["status"] == "ACTUAL_TIMESTAMP_UNKNOWN"
    assert all(v is None for v in out["residuals"].values())


def test_actual_only_is_explicit_when_solargpt_is_unavailable():
    out = compare_actual_expected(
        _actual(), None, expected_error="SOLARGPT_UNAVAILABLE:TimeoutError")
    assert out["status"] == "ACTUAL_ONLY"
    assert out["expected"] is None
    assert "SOLARGPT_UNAVAILABLE" in out["expected_error"]


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items())
             if k.startswith("test_") and callable(v)]
    for test in tests:
        test()
        print("OK", test.__name__)
    print(f"{len(tests)} expected-contract tests OK")
