"""Collector: una tarea asyncio por NCU, escribe a InfluxDB.

Patrón Gorraiz: loop infinito con backoff en errores, logging de campos
en el primer ciclo para validar el mapeo contra la NCU real.
"""
import asyncio
import logging
import os
import sys
import time

import yaml
from influxdb_client import InfluxDBClient, Point
from influxdb_client.client.write_api import SYNCHRONOUS

from decode import tracker_health
from traffic import TrafficMeter

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


def make_driver(cfg, ncu_cfg, mmap, meter=None):
    word_order = cfg.get("float_word_order", "big")
    max_regs = cfg["polling"]["max_regs_per_read"]
    if cfg["driver"] == "modbus":
        from drivers.modbus_ncu import ModbusNCUDriver
        return ModbusNCUDriver(ncu_cfg, mmap, word_order,
                               timeout=cfg["polling"]["modbus_timeout_s"],
                               max_regs=max_regs, meter=meter)
    from drivers.simulated import SimulatedNCUDriver
    return SimulatedNCUDriver(ncu_cfg, mmap, word_order, meter=meter, max_regs=max_regs)


def tracker_points(plant_id, ncu_id, trackers):
    """Puntos InfluxDB de un ciclo de TCUs (se escriben en un solo POST)."""
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
    return points


def write_points(write_api, bucket, org, points, meter=None):
    """Escribe un lote y contabiliza lo que ese lote sube a la nube."""
    if not points:
        return
    write_api.write(bucket=bucket, org=org, record=points)
    if meter:
        meter.cloud_write([p.to_line_protocol() for p in points])


def write_traffic(write_api, bucket, org, plant_id, ncu_id, snap, meter):
    """Publica el coste del ciclo como una serie más (`traffic`).

    El punto que escribe esta función también ocupa: se contabiliza en el
    medidor DESPUÉS de escribirlo, así entra en el ciclo siguiente en vez de
    morderse la cola.
    """
    p = Point("traffic").tag("plant", plant_id).tag("ncu", ncu_id)
    for k, v in snap.items():
        p.field(k, float(v))
    write_api.write(bucket=bucket, org=org, record=p)
    meter.cloud_write([p.to_line_protocol()])


async def poll_ncu(cfg, mmap, ncu_cfg, write_api):
    plant_id = cfg["plant"]["id"]
    bucket, org = cfg["influxdb"]["bucket"], cfg["influxdb"]["org"]
    interval = cfg["polling"]["interval_s"]
    meter = TrafficMeter() if cfg.get("traffic", {}).get("enabled", True) else None
    drv = make_driver(cfg, ncu_cfg, mmap, meter)
    first = True
    t_prev = time.monotonic()
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

            write_points(write_api, bucket, org,
                         tracker_points(plant_id, ncu_cfg["id"], trackers), meter)

            # NCU + meteo van en el MISMO POST: cada escritura HTTP paga sus
            # cabeceras, y por un enlace 4G eso pesa más que los propios datos.
            estado = [Point("ncu_status").tag("plant", plant_id).tag("ncu", ncu_cfg["id"])]
            for k, v in ncu_status.items():
                estado[0].field(k, float(v))
            for m in meteo:
                p = (Point("meteo").tag("plant", plant_id)
                     .tag("ncu", ncu_cfg["id"]).tag("hsu", str(m["hsu"])))
                for k, v in m["fields"].items():
                    p.field(k, float(v))
                estado.append(p)
            write_points(write_api, bucket, org, estado, meter)

            if meter:
                now_m = time.monotonic()
                snap = meter.snapshot(now_m - t_prev)
                t_prev = now_m
                write_traffic(write_api, bucket, org, plant_id, ncu_cfg["id"], snap, meter)

            n_off = sum(1 for t in trackers if tracker_health(
                t["fields"], t["alarms"], t["comms_age_s"]) == "offline")
            log.info("[%s] %d TCUs leídos (%d offline)%s", ncu_cfg["id"],
                     len(trackers), n_off,
                     "" if not meter else
                     " — LAN %.1f kB, nube %.1f kB" % (snap["lan_b"] / 1e3,
                                                       snap["cloud_gz_b"] / 1e3))
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
