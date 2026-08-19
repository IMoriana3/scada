"""API de consulta para el frontend (mapa demo-siting).

GET /live                 -> último estado de todos los trackers de la planta
GET /live?ncu=NCU-01      -> filtrado por NCU
GET /history/{ncu}/{tcu}  -> series del tracker (por defecto últimas 24h)
GET /meteo                -> última lectura de cada HSU
GET /traffic              -> tráfico medido: LAN de planta y subida a la nube
"""
import os

from fastapi import FastAPI, Query
from fastapi.middleware.cors import CORSMiddleware
from influxdb_client import InfluxDBClient

app = FastAPI(title="Tracker SCADA API")
app.add_middleware(CORSMiddleware, allow_origins=["*"],
                   allow_methods=["GET"], allow_headers=["*"])

URL = os.environ.get("INFLUXDB_URL", "http://influxdb:8086")
ORG = os.environ.get("INFLUXDB_ORG", "factiun")
BUCKET = os.environ.get("INFLUXDB_BUCKET", "trackers")
client = InfluxDBClient(url=URL, token=os.environ["INFLUXDB_TOKEN"], org=ORG)


@app.get("/live")
def live(ncu: str | None = None):
    flt = f' and r.ncu == "{ncu}"' if ncu else ""
    q = f'''
from(bucket: "{BUCKET}")
  |> range(start: -10m)
  |> filter(fn: (r) => r._measurement == "tracker_status"{flt})
  |> last()
  |> pivot(rowKey: ["ncu","tcu"], columnKey: ["_field"], valueColumn: "_value")
'''
    tables = client.query_api().query(q)
    out = []
    for table in tables:
        for rec in table.records:
            v = rec.values
            out.append({k: v.get(k) for k in
                        ("ncu", "tcu", "health", "alarms", "tilt_angle",
                         "target_angle", "soc", "battery_voltage", "temp_battery",
                         "main_state", "bt_active", "safe_position", "comms_age_s",
                         "system_ok")})
    return {"count": len(out), "trackers": out}


@app.get("/history/{ncu}/{tcu}")
def history(ncu: str, tcu: str,
            hours: int = Query(24, le=720),
            fields: str = "tilt_angle,target_angle,soc"):
    field_list = [f.strip() for f in fields.split(",")]
    flt = " or ".join(f'r._field == "{f}"' for f in field_list)
    q = f'''
from(bucket: "{BUCKET}")
  |> range(start: -{hours}h)
  |> filter(fn: (r) => r._measurement == "tracker_status"
       and r.ncu == "{ncu}" and r.tcu == "{tcu}" and ({flt}))
  |> aggregateWindow(every: 5m, fn: mean, createEmpty: false)
'''
    tables = client.query_api().query(q)
    series: dict[str, list] = {}
    for table in tables:
        for rec in table.records:
            series.setdefault(rec.get_field(), []).append(
                {"t": rec.get_time().isoformat(), "v": rec.get_value()})
    return {"ncu": ncu, "tcu": tcu, "series": series}


@app.get("/meteo")
def meteo():
    q = f'''
from(bucket: "{BUCKET}")
  |> range(start: -15m)
  |> filter(fn: (r) => r._measurement == "meteo")
  |> last()
  |> pivot(rowKey: ["ncu","hsu"], columnKey: ["_field"], valueColumn: "_value")
'''
    tables = client.query_api().query(q)
    out = []
    for table in tables:
        for rec in table.records:
            v = rec.values
            out.append({k: v.get(k) for k in
                        ("ncu", "hsu", "wind_speed", "wind_direction",
                         "snow_level", "wind_level", "alarm_wind", "alarm_snow")})
    return {"hsus": out}


TRAFFIC_FIELDS = ("lan_b", "lan_up_b", "lan_down_b", "cloud_raw_b", "cloud_gz_b",
                  "modbus_tx", "cloud_points", "period_s")


@app.get("/traffic")
def traffic(hours: int = Query(24, le=720), ncu: str | None = None):
    """Medidor de tráfico: cuánto cuesta el SCADA en la LAN y cuánto sube a la nube.

    Suma los contadores por ciclo que publica el colector y los extrapola con el
    tiempo REALMENTE medido (`period_s`), no con la ventana pedida: si el
    colector ha estado parado dos horas, la proyección a día no se infla.
    """
    flt = f' and r.ncu == "{ncu}"' if ncu else ""
    campos = " or ".join(f'r._field == "{f}"' for f in TRAFFIC_FIELDS)
    q = f"""
from(bucket: "{BUCKET}")
  |> range(start: -{hours}h)
  |> filter(fn: (r) => r._measurement == "traffic"{flt} and ({campos}))
  |> group(columns: ["ncu", "_field"])
  |> sum()
"""
    por_ncu: dict[str, dict] = {}
    for table in client.query_api().query(q):
        for rec in table.records:
            por_ncu.setdefault(rec.values.get("ncu"), {})[rec.get_field()] = rec.get_value()

    ncus, tot = [], {f: 0.0 for f in TRAFFIC_FIELDS}
    for nombre, campos_ncu in sorted(por_ncu.items()):
        fila = {"ncu": nombre, **{f: campos_ncu.get(f, 0) or 0 for f in TRAFFIC_FIELDS}}
        ncus.append(fila | _rates(fila))
        for f in TRAFFIC_FIELDS:
            tot[f] += fila[f]
    return {"hours": hours, "measured_s": round(tot["period_s"], 1),
            "ncus": ncus, "plant": tot | _rates(tot)}


def _rates(fila: dict) -> dict:
    """Proyección a día y a mes sobre el tiempo medido."""
    s = fila.get("period_s") or 0
    if s <= 0:
        return {"lan_mb_day": 0.0, "cloud_mb_day": 0.0, "cloud_gb_month": 0.0,
                "cloud_bps": 0.0}
    dia = 86400.0 / s
    return {
        "lan_mb_day": round(fila["lan_b"] * dia / 1e6, 3),
        "cloud_mb_day": round(fila["cloud_gz_b"] * dia / 1e6, 3),
        "cloud_gb_month": round(fila["cloud_gz_b"] * dia * 30 / 1e9, 3),
        "cloud_bps": round(fila["cloud_gz_b"] * 8 / s, 1),
    }


@app.get("/health")
def health():
    return {"status": "ok"}
