"""Collector: una tarea asyncio por NCU, escribe a InfluxDB.

Patrón Gorraiz: loop infinito con backoff en errores, logging de campos
en el primer ciclo para validar el mapeo contra la NCU real.
"""
import asyncio
import logging
import os
import sys

import yaml
from influxdb_client import InfluxDBClient, Point
from influxdb_client.client.write_api import SYNCHRONOUS

from decode import tracker_health

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s [%(name)s] %(message)s")
log = logging.getLogger("collector")

CFG_DIR = os.environ.get("CONFIG_DIR", "/config")


def load_cfg():
    with open(f"{CFG_DIR}/plants.yml") as f:
        plants = yaml.safe_load(f)
    with open(f"{CFG_DIR}/modbus_map.yml") as f:
        mmap = yaml.safe_load(f)
    return plants, mmap


def make_driver(cfg, ncu_cfg, mmap):
    word_order = cfg.get("float_word_order", "big")
    if cfg["driver"] == "modbus":
        from drivers.modbus_ncu import ModbusNCUDriver
        return ModbusNCUDriver(ncu_cfg, mmap, word_order,
                               timeout=cfg["polling"]["modbus_timeout_s"],
                               max_regs=cfg["polling"]["max_regs_per_read"])
    from drivers.simulated import SimulatedNCUDriver
    return SimulatedNCUDriver(ncu_cfg, mmap, word_order)


def write_trackers(write_api, bucket, org, plant_id, ncu_id, trackers):
    points = []
    for t in trackers:
        f = t["fields"]
        health = tracker_health(f, t["alarms"], t["comms_age_s"])
        p = (Point("tracker_status")
             .tag("plant", plant_id).tag("ncu", ncu_id).tag("tcu", str(t["tcu"]))
             .field("health", health)
             .field("alarms", ",".join(t["alarms"])))
        if t["comms_age_s"] is not None:
            p.field("comms_age_s", float(t["comms_age_s"]))
        for k in ("tilt_angle", "target_angle", "soc", "soh", "battery_voltage",
                  "battery_current", "temp_battery", "temp_pcb", "motor_current",
                  "panel_voltage", "main_state", "bt_active", "safe_position",
                  "system_ok", "alarms1", "alarms2"):
            if k in f and f[k] is not None:
                p.field(k, float(f[k]))
        points.append(p)
    write_api.write(bucket=bucket, org=org, record=points)


async def poll_ncu(cfg, mmap, ncu_cfg, write_api):
    plant_id = cfg["plant"]["id"]
    bucket, org = cfg["influxdb"]["bucket"], cfg["influxdb"]["org"]
    interval = cfg["polling"]["interval_s"]
    drv = make_driver(cfg, ncu_cfg, mmap)
    first = True
    while True:
        try:
            await drv.connect()
            trackers = await drv.read_trackers()
            ncu_status = await drv.read_ncu()
            meteo = await drv.read_meteo()
            await drv.close()

            if first:
                sample = next((t for t in trackers if t["fields"]), None)
                log.info("[%s] Campos disponibles TCU: %s", ncu_cfg["id"],
                         list(sample["fields"].keys()) if sample else "ninguno")
                first = False

            write_trackers(write_api, bucket, org, plant_id, ncu_cfg["id"], trackers)

            p = Point("ncu_status").tag("plant", plant_id).tag("ncu", ncu_cfg["id"])
            for k, v in ncu_status.items():
                p.field(k, float(v))
            write_api.write(bucket=bucket, org=org, record=p)

            for m in meteo:
                p = (Point("meteo").tag("plant", plant_id)
                     .tag("ncu", ncu_cfg["id"]).tag("hsu", str(m["hsu"])))
                for k, v in m["fields"].items():
                    p.field(k, float(v))
                write_api.write(bucket=bucket, org=org, record=p)

            n_off = sum(1 for t in trackers if tracker_health(
                t["fields"], t["alarms"], t["comms_age_s"]) == "offline")
            log.info("[%s] %d TCUs leídos (%d offline)", ncu_cfg["id"],
                     len(trackers), n_off)
            await asyncio.sleep(interval)
        except Exception as e:
            log.error("[%s] %s — reintento en %ds", ncu_cfg["id"], e, interval)
            try:
                await drv.close()
            except Exception:
                pass
            await asyncio.sleep(interval)


async def main():
    cfg, mmap = load_cfg()
    token = os.environ.get("INFLUXDB_TOKEN")
    if not token:
        log.error("Falta INFLUXDB_TOKEN")
        sys.exit(1)
    influx = InfluxDBClient(url=cfg["influxdb"]["url"], token=token,
                            org=cfg["influxdb"]["org"])
    write_api = influx.write_api(write_options=SYNCHRONOUS)
    log.info("Collector arrancando: planta=%s driver=%s NCUs=%d",
             cfg["plant"]["id"], cfg["driver"], len(cfg["ncus"]))
    await asyncio.gather(*(poll_ncu(cfg, mmap, n, write_api) for n in cfg["ncus"]))


if __name__ == "__main__":
    asyncio.run(main())
