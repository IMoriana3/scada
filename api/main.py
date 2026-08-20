"""API de consulta para el frontend (mapa demo-siting).

GET /live                 -> último estado de todos los trackers de la planta
GET /live?ncu=NCU-01      -> filtrado por NCU
GET /history/{ncu}/{tcu}  -> series del tracker (por defecto últimas 24h)
GET /meteo                -> última lectura de cada HSU
GET /traffic              -> tráfico medido: LAN de planta y subida a la nube
GET /meteo/history        -> series de las HSU (viento, dirección, nieve…)
"""
import os
import re

from fastapi import FastAPI, HTTPException, Query
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
#: Lo que se acepta interpolar en una consulta Flux. NO es cosmética: `hours`
#: llevaba `ge/le` desde el principio, pero `every`, `hsu`, `ncu` y `fields`
#: entraban en crudo en el texto de la consulta, así que un valor con comillas
#: se sale del literal y puede leer otro `measurement` o `bucket` —datos de
#: otra planta— o lanzar una consulta que tumbe el servicio. Que la API sea de
#: solo lectura no lo evita: lee lo que no debe.
_RE_TAG = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")      # hsu, ncu
#: La ventana tiene que ser POSITIVA y sin ceros a la izquierda: `0s` daba una
#: división por cero al calcular los puntos y `00s` un KeyError al partir la
#: unidad. Las dos pasaban el filtro y morían con un 500 — un valor que se
#: rechaza tiene que salir por la puerta del 400, diciendo qué está mal.
_RE_EVERY = re.compile(r"^[1-9]\d{0,4}(ms|s|m|h|d|w)$")   # ventana de agregación
#: Lista BLANCA de campos. Una negra habría que mantenerla al día; esta falla
#: hacia el lado seguro cuando aparezca un campo nuevo.
_METEO_FIELDS = frozenset((
    "wind_speed", "wind_direction", "wind_gust", "temp_air", "temp_module",
    "humidity", "pressure", "ghi", "poa", "rain", "snow_level", "wind_level",
))
#: Tope de puntos por serie. `hours=8760&every=1s` son ~31 millones: no es un
#: ataque, es un enlace mal escrito, y tumba igual.
_MAX_PUNTOS = 20000

_UNID_SEG = {"ms": 0.001, "s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800}


def _every_segundos(every: str) -> float:
    n = int(re.match(r"^(\d+)", every).group(1))
    return n * _UNID_SEG[every[len(str(n)):]]


@app.get("/meteo/history")
def meteo_history(hours: int = Query(720, ge=1, le=8760),
                  every: str = Query("10m"),
                  hsu: str | None = None,
                  ncu: str | None = None,
                  fields: str = "wind_speed,wind_direction,temp_air,ghi"):
    """Series de las HSU: el viento MEDIDO en la planta.

    `/meteo` da solo la última lectura, que sirve para pintar el estado pero no
    para analizar un emplazamiento. Esto devuelve la serie sobre un ÚNICO eje de
    tiempos, para que el consumidor no tenga que casar timestamps (el simulador
    de abanderamiento la come tal cual).

    Dos decisiones que conviene conocer antes de usar el dato:

    * los campos escalares se agregan por **media** en cada ventana, pero la
      **dirección se toma como último valor**: promediar rumbos exige media
      circular —entre 350° y 10° la media aritmética da 180°, el rumbo
      contrario— y para una ventana de minutos el último valor dice lo mismo
      sin abrir esa puerta;
    * sin filtrar `hsu` o `ncu` se mezclan todas las HSU de la planta. Para
      analizar un punto concreto, hay que decir cuál.
    """
    # Validación ANTES de tocar la consulta: nada llega al texto de Flux sin
    # pasar por aquí. Se rechaza con 400 y diciendo qué valor está mal, no se
    # limpia en silencio — un filtro que se ignora es peor que un error.
    if not _RE_EVERY.match(every):
        raise HTTPException(400, f"`every` inválido: {every!r}. Formato "
                                 "<número><ms|s|m|h|d|w>, p.ej. 10m")
    for nombre, valor in (("hsu", hsu), ("ncu", ncu)):
        if valor is not None and not _RE_TAG.match(valor):
            raise HTTPException(400, f"`{nombre}` inválido: {valor!r}. Solo "
                                     "letras, dígitos, punto, guion y guion bajo")
    field_list = [f.strip() for f in fields.split(",") if f.strip()]
    desconocidos = [f for f in field_list if f not in _METEO_FIELDS]
    if desconocidos:
        raise HTTPException(400, f"campos no reconocidos: {desconocidos}. "
                                 f"Disponibles: {sorted(_METEO_FIELDS)}")
    puntos = hours * 3600 / _every_segundos(every)
    if puntos > _MAX_PUNTOS:
        raise HTTPException(400, f"{int(puntos):,} puntos por serie ({hours} h "
                                 f"cada {every}) pasan del tope de {_MAX_PUNTOS:,}. "
                                 "Sube `every` o baja `hours`")
    if not field_list:
        return {"hours": hours, "every": every, "t": [], "series": {}}

    filtro = ['r._measurement == "meteo"']
    if hsu:
        filtro.append(f'r.hsu == "{hsu}"')
    if ncu:
        filtro.append(f'r.ncu == "{ncu}"')
    base = " and ".join(filtro)

    series: dict[str, dict[str, float]] = {}

    def _consulta(campos: list[str], fn: str) -> None:
        if not campos:
            return
        flt = " or ".join(f'r._field == "{f}"' for f in campos)
        q = f"""
from(bucket: "{BUCKET}")
  |> range(start: -{hours}h)
  |> filter(fn: (r) => {base} and ({flt}))
  |> aggregateWindow(every: {every}, fn: {fn}, createEmpty: false)
"""
        for table in client.query_api().query(q):
            for rec in table.records:
                series.setdefault(rec.get_field(), {})[rec.get_time().isoformat()] = rec.get_value()

    _consulta([f for f in field_list if f != "wind_direction"], "mean")
    if "wind_direction" in field_list:
        _consulta(["wind_direction"], "last")

    tiempos = sorted({t for campo in series.values() for t in campo})
    return {"hours": hours, "every": every, "hsu": hsu, "ncu": ncu,
            "t": tiempos,
            "series": {k: [v.get(t) for t in tiempos] for k, v in series.items()}}


@app.get("/health")
def health():
    return {"status": "ok"}
