#!/usr/bin/env python3
"""Electrical telemetry contract tests; no network or real plant required."""
import os
import sys
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "collector"))

from electrical_contract import (  # noqa: E402
    ElectricalTelemetryError,
    validate_electrical_sample,
)
from electrical import electrical_point  # noqa: E402

ASSET = "11111111-1111-4111-8111-111111111111"
TS = "2026-09-28T12:00:00+00:00"


def sample(**overrides):
    row = {
        "asset_id": ASSET,
        "asset_type": "string",
        "observed_at": TS,
        "source": "fixture",
        "source_channel": "inv1.mppt2.string7",
        "quality": "GOOD",
        "metrics": {"dc_current_a": 11.8},
    }
    row.update(overrides)
    return row


def test_valid_string_sample_is_normalized():
    row = validate_electrical_sample(sample())
    assert row["asset_id"] == ASSET
    assert row["metrics"] == {"dc_current_a": 11.8}
    assert row["observed_at"] == TS


def test_noncanonical_or_non_v4_asset_id_is_rejected():
    for value in (
        ASSET.upper(),
        "11111111111141118111111111111111",
        "00000000-0000-1000-8000-000000000001",
        "not-a-uuid",
    ):
        try:
            validate_electrical_sample(sample(asset_id=value))
        except ElectricalTelemetryError:
            pass
        else:
            raise AssertionError(value)


def test_string_cannot_publish_inverter_ac_power():
    try:
        validate_electrical_sample(sample(metrics={"ac_power_kw": 100.0}))
    except ElectricalTelemetryError as exc:
        assert "not valid for string" in str(exc)
    else:
        raise AssertionError("string accepted ac_power_kw")


def test_inverter_active_power_limit_is_bounded():
    inv = sample(
        asset_type="inverter",
        metrics={"ac_power_kw": 300.0, "active_power_limit_pct": 101.0},
    )
    try:
        validate_electrical_sample(inv)
    except ElectricalTelemetryError as exc:
        assert "[0, 100]" in str(exc)
    else:
        raise AssertionError("invalid curtailment limit accepted")


def test_naive_timestamp_is_rejected():
    try:
        validate_electrical_sample(sample(observed_at="2026-09-28T12:00:00"))
    except ElectricalTelemetryError as exc:
        assert "timezone" in str(exc)
    else:
        raise AssertionError("naive timestamp accepted")


def test_collector_point_preserves_identity_time_and_units():
    point = electrical_point("23003", sample())
    line = point.to_line_protocol()
    assert line.startswith("electrical_status,")
    assert "asset_id=" + ASSET in line
    assert "asset_type=string" in line
    assert "source=fixture" in line
    assert "source_channel=inv1.mppt2.string7" in line
    assert "dc_current_a=11.8" in line
    assert 'quality="GOOD"' in line


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items())
             if k.startswith("test_") and callable(v)]
    for test in tests:
        test()
        print("OK", test.__name__)
    print(f"{len(tests)} electrical contract tests OK")
