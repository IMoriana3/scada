#!/usr/bin/env python3
"""Endpoint wiring tests for /assets/actual-vs-expected."""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "api"))
sys.path.insert(0, ROOT)
os.environ.setdefault("INFLUXDB_TOKEN", "test")

from fastapi.testclient import TestClient  # noqa: E402
import main as api  # noqa: E402


TCU_ASSET = "11111111-1111-4111-8111-111111111111"
TRACKER_ASSET = "33333333-3333-4333-8333-333333333333"
TRACKER_ASSET_2 = "44444444-4444-4444-8444-444444444444"
TS = "2026-09-28T08:00:00+00:00"
client = TestClient(api.app)


def _row(**overrides):
    row = {
        "asset_id": TCU_ASSET,
        "layout_key": "TK-1",
        "controlled_tracker_asset_ids": [TRACKER_ASSET],
        "observed_at": TS,
        "tilt_angle": 10.0,
        "target_angle": 11.0,
        "soc": 82.0,
        "comms_age_s": 10.0,
    }
    row.update(overrides)
    return row


def test_unconfigured_solargpt_degrades_to_actual_only():
    old_live = api.asset_live
    old_url = api.SOLARGPT_EXPECTED_URL
    try:
        api.asset_live = lambda: {"trackers": [_row()]}
        api.SOLARGPT_EXPECTED_URL = ""
        r = client.get("/assets/actual-vs-expected",
                       params={"asset_id": TCU_ASSET})
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["status"] == "ACTUAL_ONLY"
        assert body["expected_error"] == "SOLARGPT_EXPECTED_URL_NOT_CONFIGURED"
    finally:
        api.asset_live = old_live
        api.SOLARGPT_EXPECTED_URL = old_url


def test_expected_is_joined_by_exact_asset_id():
    old_live = api.asset_live
    old_fetch = api.fetch_expected
    old_url = api.SOLARGPT_EXPECTED_URL
    seen = {}
    try:
        api.asset_live = lambda: {"trackers": [_row()]}
        api.SOLARGPT_EXPECTED_URL = "http://solar.local"
        def fake_fetch(base, **kwargs):
            seen.update(kwargs)
            return {
                "asset_id": TRACKER_ASSET,
                "status": "PARTIAL",
                "expected_tracking_angle_deg": 12.0,
                "expected_operational_angle_deg": None,
                "operational_status": "INCOMPLETE_SAFETY_INPUTS",
            }
        api.fetch_expected = fake_fetch
        body = client.get("/assets/actual-vs-expected",
                          params={"asset_id": TCU_ASSET}).json()
        assert seen["asset_id"] == TRACKER_ASSET
        assert seen["ts"] == TS
        assert seen["soc"] == 82.0
        assert body["residuals"]["encoder_minus_expected_tracking_deg"] == -2.0
        assert body["residuals"]["target_minus_expected_tracking_deg"] == -1.0
    finally:
        api.asset_live = old_live
        api.fetch_expected = old_fetch
        api.SOLARGPT_EXPECTED_URL = old_url


def test_multipoint_tcu_fails_closed_without_channel_telemetry():
    old_live = api.asset_live
    old_fetch = api.fetch_expected
    try:
        api.asset_live = lambda: {"trackers": [
            _row(controlled_tracker_asset_ids=[TRACKER_ASSET, TRACKER_ASSET_2])
        ]}
        def boom(*args, **kwargs):
            raise AssertionError("SolarGPT must not be called for ambiguous multipoint telemetry")
        api.fetch_expected = boom
        body = client.get("/assets/actual-vs-expected",
                          params={"asset_id": TCU_ASSET}).json()
        assert body["status"] == "MULTIPOINT_TELEMETRY_AMBIGUOUS"
        assert body["tracker_asset_id"] is None
        assert body["controlled_tracker_asset_ids"] == [
            TRACKER_ASSET, TRACKER_ASSET_2]
        assert all(v is None for v in body["residuals"].values())
    finally:
        api.asset_live = old_live
        api.fetch_expected = old_fetch


def test_stale_actual_does_not_call_solargpt():
    old_live = api.asset_live
    old_fetch = api.fetch_expected
    try:
        api.asset_live = lambda: {
            "trackers": [_row(comms_age_s=999.0)]}
        def boom(*args, **kwargs):
            raise AssertionError("SolarGPT must not be called for stale actual")
        api.fetch_expected = boom
        body = client.get("/assets/actual-vs-expected",
                          params={"asset_id": TCU_ASSET}).json()
        assert body["status"] == "STALE_ACTUAL"
        assert all(v is None for v in body["residuals"].values())
    finally:
        api.asset_live = old_live
        api.fetch_expected = old_fetch


def test_unknown_asset_is_404():
    old_live = api.asset_live
    try:
        api.asset_live = lambda: {"trackers": [_row()]}
        other = "22222222-2222-4222-8222-222222222222"
        r = client.get("/assets/actual-vs-expected",
                       params={"asset_id": other})
        assert r.status_code == 404
    finally:
        api.asset_live = old_live


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items())
             if k.startswith("test_") and callable(v)]
    for test in tests:
        test()
        print("OK", test.__name__)
    print(f"{len(tests)} actual-vs-expected endpoint tests OK")
