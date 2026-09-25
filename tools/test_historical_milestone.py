#!/usr/bin/env python3
"""Historical/identity contract tests against a small explicit Plant Package.

Run: python -m unittest tools.test_historical_milestone -v
"""
import hashlib
import asyncio
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from datetime import date, datetime, timedelta, timezone

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT), str(ROOT / "api"), str(ROOT / "collector")]
os.environ.setdefault("INFLUXDB_TOKEN", "test")

from scada_identity import PlantIdentity, IdentityUnavailable  # noqa: E402
from historical import day_bounds, aggregate_samples, history_for_assets, measured_day  # noqa: E402
import main as api  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from drivers.modbus_ncu import ModbusNCUDriver  # noqa: E402

NCU1 = "06ee64ea-bb8d-47b4-8597-9b35c8ffc0b3"
NCU2 = "2b48971f-113c-4adb-8dc4-247cd7b44239"
TCU1 = "2b3b5a10-dc18-4d05-a3e5-50c9fe086b86"
TCU2 = "ae4a02f2-d0a2-4fe0-93cd-f3c51b336bcb"


class Record:
    def __init__(self, field, value, timestamp, ncu=None, tcu=None):
        self.field, self.value, self.timestamp = field, value, timestamp
        self.values = {"ncu": ncu, "tcu": tcu}

    def get_field(self): return self.field
    def get_value(self): return self.value
    def get_time(self): return self.timestamp


class Query:
    def __init__(self, records=()): self.records = records; self.queries = []
    def query(self, text):
        self.queries.append(text)
        rows = [r for r in self.records if not ('r.ncu == "' in text and r.values["ncu"]
                and f'r.ncu == "{r.values["ncu"]}"' not in text)]
        return [type("Table", (), {"records": rows})()]


class Milestone(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        directory = Path(self.temp.name)
        (directory / "identity").mkdir()
        self.config = {"plant": {"id": "23003", "timezone": "Europe/Madrid"},
                       "polling": {"interval_s": 30},
                       "ncus": [{"id": "NCU1", "asset_id": NCU1},
                                {"id": "NCU2", "asset_id": NCU2, "interval_s": 60}]}
        self.registry = {"plant_id": "23003", "revision": "r1",
                         "assets": [{"asset_id": a, "asset_type": kind} for a, kind in
                                    [(NCU1, "ncu"), (NCU2, "ncu"), (TCU1, "tcu"), (TCU2, "tcu")]],
                         "bindings": []}
        for asset, ncu, slave, locator in [(TCU1, NCU1, 1, "23003|NCU-01|tcu|1"),
                                            (TCU2, NCU2, 109, "23003|NCU-02|tcu|109")]:
            for kind, value, scope_type, scope_id in [
                ("modbus_slave", str(slave), "ncu", ncu),
                ("operational_asset_key", locator, "plant", "23003")]:
                self.registry["bindings"].append({"asset_id": asset, "binding_type": kind,
                  "value": value, "scope_type": scope_type, "scope_id": scope_id,
                  "valid_from": "2026-01-01T00:00:00+00:00", "valid_to": None,
                  "status": "provisional"})
        self.directory = directory
        self.save()
        self.identity = PlantIdentity(directory, self.config, development=True)

    def save(self):
        raw = (json.dumps(self.registry, sort_keys=True) + "\n").encode()
        (self.directory / "identity/registry-r1.json").write_bytes(raw)
        manifest = {"plant_id": "23003", "revision": "r1", "record_status": "provisional",
                    "files": {"registry": {"path": "identity/registry-r1.json",
                                            "sha256": "sha256:" + hashlib.sha256(raw).hexdigest()}}}
        (self.directory / "manifest.yaml").write_text(yaml.safe_dump(manifest))

    def test_explicit_sparse_inventory_and_hash(self):
        rows = self.identity.inventory()
        self.assertEqual([(r["ncu"], r["tcu"]) for r in rows], [("NCU1", 1), ("NCU2", 109)])
        self.assertFalse(self.identity.operationally_usable)
        self.identity.development = False
        self.identity.manifest["record_status"] = "accepted"
        self.assertFalse(self.identity.operationally_usable)  # scada.live absent
        self.identity.manifest["capabilities"] = {"scada.live": {"available": False}}
        self.assertFalse(self.identity.operationally_usable)
        self.identity.manifest["capabilities"]["scada.live"]["available"] = True
        self.assertTrue(self.identity.operationally_usable)
        self.identity.development = True
        self.identity.manifest["record_status"] = "provisional"
        with self.assertRaises(IdentityUnavailable):
            PlantIdentity(self.directory, self.config)  # unmerged package must not run
        (self.directory / "identity/registry-r1.json").write_text("{}")
        with self.assertRaisesRegex(IdentityUnavailable, "Hash"):
            PlantIdentity(self.directory, self.config, development=True)

    def test_modbus_reads_only_explicit_cache_slots(self):
        mmap = yaml.safe_load((ROOT / "config/modbus_map.yml").read_text())
        driver = ModbusNCUDriver({"id": "N", "tcu_ids": [1, 3], "tcu_count": 200}, mmap)
        calls = []

        async def read_span(addr, count):
            calls.append((addr, count))
            return [0] * count

        driver._read_span = read_span
        result = asyncio.run(driver.read_trackers())
        self.assertEqual([r["tcu"] for r in result], [1, 3])
        self.assertEqual(calls, [(30500, 22), (29500, 2), (30544, 22), (29504, 2)])

    def test_duplicate_or_missing_binding_fails_closed(self):
        self.registry["bindings"].append(dict(self.registry["bindings"][0], asset_id=TCU2))
        self.save()
        with self.assertRaises(IdentityUnavailable):
            PlantIdentity(self.directory, self.config, development=True).inventory()

    def test_same_asset_on_two_slaves_fails_closed(self):
        self.registry["bindings"].append(dict(self.registry["bindings"][0], value="3"))
        self.save()
        with self.assertRaisesRegex(IdentityUnavailable, "más de una dirección"):
            PlantIdentity(self.directory, self.config, development=True).inventory()

    def test_multi_asset_history_shared_range_and_empty_peer(self):
        from_ = datetime(2026, 9, 24, tzinfo=timezone.utc)
        to = from_ + timedelta(hours=6)
        query = Query([Record("soc", 80.0, from_ + timedelta(minutes=5), "NCU1", "1")])
        result = history_for_assets(query, "trackers", self.identity, [TCU1, TCU2], from_, to, ["soc"])
        self.assertEqual(len(result["assets"]), 2)
        self.assertEqual(result["assets"][0]["series"]["soc"][0]["v"], 80.0)
        self.assertEqual(result["assets"][1]["series"]["soc"], [])
        self.assertEqual(len(query.queries), 2)
        self.assertTrue(all('r.plant == "23003"' in q for q in query.queries))
        self.assertTrue(all('r.source == "modbus"' in q for q in query.queries))
        self.assertIn('r.ncu == "NCU1" and r.tcu == "1"', query.queries[0])
        self.assertIn('r.ncu == "NCU2" and r.tcu == "109"', query.queries[1])
        self.assertTrue(all('2026-09-24T00:00:00Z' in q and '2026-09-24T06:00:00Z' in q
                            for q in query.queries))
        with self.assertRaises(ValueError):
            history_for_assets(query, "trackers", self.identity, [TCU1, TCU1], from_, to, ["soc"])
        with self.assertRaises(ValueError):
            history_for_assets(query, "trackers", self.identity, [TCU1], from_, to, ["health"])

    def test_dst_and_missing_vs_offline(self):
        start, end = day_bounds(date(2026, 3, 29), "Europe/Madrid")
        self.assertEqual((end - start).total_seconds(), 23 * 3600)
        self.assertEqual(day_bounds(date(2026, 10, 25), "Europe/Madrid")[1] -
                         day_bounds(date(2026, 10, 25), "Europe/Madrid")[0], timedelta(hours=25))
        samples = [(start + timedelta(seconds=i * 30), state)
                   for i, state in [(0, "ok"), (1, "offline"), (4, "ok")]]
        metric = aggregate_samples(samples, start, start + timedelta(seconds=150), 30, complete=True)
        self.assertEqual((metric["received"], metric["expected"]), (3, 5))
        self.assertEqual(metric["telemetry_availability_pct"], 60)
        self.assertEqual(metric["offline_samples"], 1)
        self.assertEqual(metric["offline_observed_pct"], 33.33)
        self.assertEqual(metric["gaps"][0]["missing"], 2)
        self.assertEqual(aggregate_samples([], start, end, 30, complete=True)["status"], "UNKNOWN")
        self.assertEqual(aggregate_samples(samples, start, end, 30, complete=False)["status"], "UNKNOWN")

    def test_ncu_filter_and_no_cross_identity(self):
        start, _ = day_bounds(date(2026, 9, 24), "Europe/Madrid")
        query = Query([Record("health", "ok", start, "NCU1", "1"),
                       Record("health", "offline", start + timedelta(seconds=30), "NCU1", "1"),
                       Record("health", "ok", start, "NCU2", "109"),
                       Record("health", "ok", start, "NCU2", "108")])
        filtered = measured_day(query, "trackers", self.identity, date(2026, 9, 24),
                                ncu_asset_id=NCU1, now=start + timedelta(days=3))
        self.assertEqual([r["asset_id"] for r in filtered["assets"]], [TCU1])
        self.assertEqual(filtered["assets"][0]["offline_samples"], 1)
        all_ = measured_day(query, "trackers", self.identity, date(2026, 9, 24),
                            now=start + timedelta(days=3))
        self.assertEqual({r["asset_id"] for r in all_["assets"]}, {TCU1, TCU2})
        self.assertEqual(next(r for r in all_["assets"] if r["asset_id"] == TCU2)["status"], "UNKNOWN")
        with self.assertRaises(ValueError):
            measured_day(query, "trackers", self.identity, date(2026, 9, 24),
                         ncu_asset_id="12345678-1234-1234-1234-123456789abc")

    def test_http_contract_validation(self):
        old = api._identity
        api._identity = lambda: self.identity
        self.addCleanup(lambda: setattr(api, "_identity", old))
        cli = TestClient(api.app)
        self.assertEqual(cli.get("/identity").json()["operationally_usable"], False)
        self.assertEqual(cli.get("/assets/history", params={"asset_id": TCU1,
                         "from": "2026-09-24T00:00:00", "to": "2026-09-25T00:00:00Z"}).status_code, 400)
        self.assertEqual(cli.get("/assets/history", params={"asset_id": "name",
                         "from": "2026-09-24T00:00:00Z", "to": "2026-09-25T00:00:00Z"}).status_code, 400)


if __name__ == "__main__":
    unittest.main()
