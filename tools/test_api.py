#!/usr/bin/env python3
"""Banco de la API del SCADA (`api/main.py`), sin InfluxDB ni red.

Ejercita los tres endpoints por TCU contra un `query_api` de mentira que
devuelve registros preparados, así que comprueba lo que de verdad se entrega:
qué campos salen, qué entradas se rechazan y CÓMO queda el texto de la consulta
Flux -- que es donde se cuela una inyección.

    pip install fastapi influxdb-client httpx
    python tools/test_api.py

Sale 0 y `Todo OK`, o la lista de fallos y 1.
"""
import os
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(RAIZ, "api"))
os.environ.setdefault("INFLUXDB_TOKEN", "banco")     # main.py lo exige al importar

try:
    from fastapi.testclient import TestClient
except ImportError as e:                              # pragma: no cover
    print(f"AVISO: falta una dependencia ({e}). pip install fastapi influxdb-client httpx")
    sys.exit(0)

import main as api                                    # noqa: E402

ok = ko = 0


def chk(nombre, real, esperado):
    global ok, ko
    if real == esperado:
        print(f"OK   {nombre} = {real}")
        ok += 1
    else:
        print(f"FALLO {nombre}: {real!r}, esperado {esperado!r}")
        ko += 1


# ── Influx de mentira ───────────────────────────────────────────────────────
# Guarda la consulta que recibe: media prueba de este banco es mirar el texto
# que se le habría mandado a Flux.
class RecStub:
    def __init__(self, values, field=None, valor=None, t=None):
        self.values = values
        self._f, self._v, self._t = field, valor, t

    def get_field(self):
        return self._f

    def get_value(self):
        return self._v

    def get_time(self):
        return self._t


class TableStub:
    def __init__(self, records):
        self.records = records


class QueryStub:
    def __init__(self):
        self.ultima = None
        self.tablas = []

    def query(self, q):
        self.ultima = q
        return self.tablas


QS = QueryStub()
api.client.query_api = lambda: QS
cli = TestClient(api.app)


# ── /live: los campos que se entregan ───────────────────────────────────────
print("== /live ==")
# Un TCU con TODO lo que el colector escribe, para ver qué llega al cliente.
fila = {"ncu": "NCU1", "tcu": "62", "health": "warn", "alarms": "axis_blocked",
        "tilt_angle": -12.5, "target_angle": -14.0, "soc": 87.0, "soh": 98.0,
        "battery_voltage": 25800.0, "battery_current": -320.0,
        "temp_battery": 21.4, "temp_pcb": 24.1, "motor_current": 1450.0,
        "panel_voltage": 31200.0, "main_state": 2.0, "bt_active": 0.0,
        "safe_position": 0.0, "system_ok": 1.0, "alarms1": 256.0,
        "alarms2": 0.0, "comms_age_s": 41.0}
QS.tablas = [TableStub([RecStub(fila)])]
j = cli.get("/live").json()
chk("cuenta los trackers", j["count"], 1)
t = j["trackers"][0]
# Los seis que ANTES se quedaban fuera aunque estuvieran en el bucket. Sin
# corriente de motor no se puede decir por qué un tracker no se mueve.
for campo, valor in (("battery_current", -320.0), ("motor_current", 1450.0),
                     ("soh", 98.0), ("temp_pcb", 24.1),
                     ("panel_voltage", 31200.0), ("alarms1", 256.0)):
    chk(f"live sirve {campo}", t[campo], valor)
chk("y no se ha perdido nada de lo de antes",
    all(k in t for k in ("ncu", "tcu", "health", "alarms", "tilt_angle",
                         "target_angle", "soc", "battery_voltage",
                         "temp_battery", "main_state", "bt_active",
                         "safe_position", "comms_age_s", "system_ok")), True)
# Un TCU legacy: la NCU pre-R7 no publica el bloque, así que el pivot no trae
# esos campos. Tienen que salir como null, NO faltar: la ficha distingue
# "no expuesto por este firmware" de "no ha llegado la respuesta".
QS.tablas = [TableStub([RecStub({"ncu": "NCU2", "tcu": "7", "health": "offline"})])]
t2 = cli.get("/live").json()["trackers"][0]
chk("legacy: la clave existe", "tilt_angle" in t2, True)
chk("legacy: y vale null", t2["tilt_angle"], None)

# ── /live: la NCU no entra en crudo en la consulta ──────────────────────────
print()
print("== /live: filtro de ncu ==")
QS.tablas = []
chk("una NCU normal pasa", cli.get("/live?ncu=NCU1").status_code, 200)
chk("y va al filtro", 'r.ncu == "NCU1"' in QS.ultima, True)
for malo in ('NCU1" or true or "', "NCU 1", "a" * 65, "../otro"):
    chk(f"rechaza {malo!r}", cli.get("/live", params={"ncu": malo}).status_code, 400)

# ── /history: validación de ruta y de campos ───────────────────────────────
print()
print("== /history ==")
QS.tablas = [TableStub([RecStub({}, "tilt_angle", -12.5, __import__("datetime").datetime(2026, 8, 21, 10, 0))])]
r = cli.get("/history/NCU1/62")
chk("una petición normal responde", r.status_code, 200)
chk("y trae la serie", r.json()["series"]["tilt_angle"][0]["v"], -12.5)
chk("con los campos por defecto", 'r._field == "tilt_angle"' in QS.ultima, True)
chk("y el TCU en el filtro", 'r.tcu == "62"' in QS.ultima, True)

# La ruta viene de un enlace pegable en un correo: es entrada de usuario.
for ruta in ('/history/NCU1/62" or true or "', "/history/NCU 1/62"):
    chk(f"rechaza la ruta {ruta!r}", cli.get(ruta).status_code, 400)
# fields: lista blanca. Un campo inventado no llega a Flux.
chk("rechaza un campo inventado",
    cli.get("/history/NCU1/62", params={"fields": "tilt_angle,rm -rf"}).status_code, 400)
chk("rechaza un campo de otro measurement",
    cli.get("/history/NCU1/62", params={"fields": "wind_speed"}).status_code, 400)
chk("acepta los del bloque compat",
    cli.get("/history/NCU1/62", params={"fields": "motor_current,battery_current"}).status_code, 200)
# hours: el tope ya estaba; el suelo no. hours=0 daba un `range(start: -0h)`.
chk("hours=0 se rechaza", cli.get("/history/NCU1/62", params={"hours": 0}).status_code, 422)
chk("hours=721 se rechaza", cli.get("/history/NCU1/62", params={"hours": 721}).status_code, 422)
chk("hours=720 se acepta", cli.get("/history/NCU1/62", params={"hours": 720}).status_code, 200)
# fields vacío: ni consulta ni error. Devuelve la forma correcta y vacía.
QS.ultima = None
r = cli.get("/history/NCU1/62", params={"fields": " , "})
chk("fields vacío no consulta", QS.ultima, None)
chk("y devuelve series vacías", r.json()["series"], {})

# ── /traffic: mismo filtro de ncu ──────────────────────────────────────────
print()
print("== /traffic ==")
QS.tablas = []
chk("rechaza una ncu con comillas",
    cli.get("/traffic", params={"ncu": 'x" or true or "'}).status_code, 400)
chk("y acepta la buena", cli.get("/traffic", params={"ncu": "NCU1"}).status_code, 200)

# ── la lista blanca describe lo que el colector escribe de verdad ──────────
print()
print("== lista blanca contra el colector ==")
# Si alguien añade un campo al colector y no a la lista, `/history` lo rechaza
# en silencio para el que lo pida. Esto lo caza aquí y no en campo.
col = open(os.path.join(RAIZ, "collector", "main.py"), encoding="utf-8").read()
i = col.index('for k in ("tilt_angle"')
escritos = set(col[i:col.index(")", col.index("):", i))].replace("for k in (", "")
                  .replace('"', "").replace("\n", "").replace(" ", "").split(","))
escritos.discard("")
faltan = sorted(escritos - set(api._TRACKER_FIELDS))
chk("ningún campo del colector se queda fuera de la lista blanca", faltan, [])

print()
if ko:
    print(f"{ko} FALLOS, {ok} OK")
    sys.exit(1)
print(f"Todo OK ({ok} comprobaciones)")
