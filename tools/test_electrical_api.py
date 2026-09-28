#!/usr/bin/env python3
"""Endpoint tests for /assets/electrical/live."""
import os
import sys
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "api"))
sys.path.insert(0, ROOT)
os.environ.setdefault("INFLUXDB_TOKEN", "test")

from fastapi.testclient import TestClient  # noqa: E402
import main as api  # noqa: E402

STRING = "11111111-1111-4111-8111-111111111111"
MPPT = "22222222-2222-4222-8222-222222222222"
UNKNOWN = "33333333-3333-4333-8333-333333333333"
client = TestClient(api.app)


class Rec:
    def __init__(self, values, t=None):
        self.values = values
        self._t = t

    def get_time(self):
        return self._t


class Table:
    def __init__(self, records):
        self.records = records


class Query:
    def __init__(self):
        self.tables = []
        self.last = None

    def query(self, query):
        self.last = query
        return self.tables


class Identity:
    registry = {"plant_id": "23003"}

    def __init__(self, available=True):
        self.available = available

    def capability_available(self, name):
        return self.available and name == "electrical.topology"

    def electrical_assets(self):
        if not self.available:
            return []
        return [
            {"asset_id": STRING, "asset_type": "string", "typed_id": "STR-01"},
            {"asset_id": MPPT, "asset_type": "mppt", "typed_id": "MPPT-01"},
        ]


Q = Query()
api.client.query_api = lambda: Q


def test_missing_topology_is_explicit_and_does_not_query_influx():
    old = api._identity
    try:
        api._identity = lambda: Identity(False)
        Q.last = None
        body = client.get("/assets/electrical/live").json()
        assert body["status"] == "UNAVAILABLE_NO_ELECTRICAL_TOPOLOGY"
        assert body["count"] == 0
        assert Q.last is None
    finally:
        api._identity = old


def test_known_string_returns_canonical_measured_sample():
    old = api._identity
    try:
        api._identity = lambda: Identity(True)
        now = datetime.now(timezone.utc)
        Q.tables = [Table([Rec({
            "asset_id": STRING,
            "asset_type": "string",
            "source": "inverter-modbus",
            "source_channel": "s7",
            "quality": "GOOD",
            "dc_current_a": 11.8,
        }, now)])]
        r = client.get("/assets/electrical/live", params={"asset_id": STRING})
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["status"] == "OK"
        assert body["count"] == 1
        row = body["assets"][0]
        assert row["asset_id"] == STRING
        assert row["metrics"]["dc_current_a"] == 11.8
        assert row["freshness"] == "FRESH"
        assert 'r.asset_id == "' + STRING + '"' in Q.last
    finally:
        api._identity = old


def test_unknown_or_malformed_asset_never_reaches_query():
    old = api._identity
    try:
        api._identity = lambda: Identity(True)
        Q.last = None
        assert client.get(
            "/assets/electrical/live", params={"asset_id": "not-a-uuid"}
        ).status_code == 400
        assert Q.last is None
        assert client.get(
            "/assets/electrical/live", params={"asset_id": UNKNOWN}
        ).status_code == 404
        assert Q.last is None
    finally:
        api._identity = old


def test_bucket_asset_type_mismatch_fails_closed():
    old = api._identity
    try:
        api._identity = lambda: Identity(True)
        Q.tables = [Table([Rec({
            "asset_id": STRING,
            "asset_type": "inverter",
            "source": "bad",
            "quality": "GOOD",
            "ac_power_kw": 1.0,
        }, datetime.now(timezone.utc))])]
        r = client.get("/assets/electrical/live")
        assert r.status_code == 409
        assert "asset_type" in r.text
    finally:
        api._identity = old


def test_unknown_bucket_asset_fails_closed():
    old = api._identity
    try:
        api._identity = lambda: Identity(True)
        Q.tables = [Table([Rec({
            "asset_id": UNKNOWN,
            "asset_type": "string",
            "source": "bad",
            "quality": "GOOD",
            "dc_current_a": 1.0,
        }, datetime.now(timezone.utc))])]
        r = client.get("/assets/electrical/live")
        assert r.status_code == 409
        assert "desconocido" in r.text
    finally:
        api._identity = old


def test_no_samples_is_not_reported_as_ok():
    old = api._identity
    try:
        api._identity = lambda: Identity(True)
        Q.tables = []
        body = client.get("/assets/electrical/live").json()
        assert body["status"] == "NO_MEASURED_ELECTRICAL_TELEMETRY"
        assert body["count"] == 0
    finally:
        api._identity = old


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items())
             if k.startswith("test_") and callable(v)]
    for test in tests:
        test()
        print("OK", test.__name__)
    print(f"{len(tests)} electrical endpoint tests OK")
