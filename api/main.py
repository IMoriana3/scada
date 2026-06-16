"""API de consulta para el frontend (mapa demo-siting).

GET /live                 -> último estado de todos los trackers de la planta
GET /live?ncu=NCU-01      -> filtrado por NCU
GET /history/{ncu}/{tcu}  -> series del tracker (por defecto últimas 24h)
GET /meteo                -> última lectura de cada HSU
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


@app.get("/health")
def health():
    return {"status": "ok"}
