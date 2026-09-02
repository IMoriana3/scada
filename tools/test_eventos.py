"""Banco del histórico de eventos (B5-a): flancos, hora del dato y ámbitos.

Lo que se vigila aquí no es "¿detecta un cambio?" —eso lo haría cualquier
comparación— sino las tres cosas por las que un histórico de eventos sirve o no
sirve cuando alguien lo abre a las tres de la mañana:

  · que el sello sea la hora del DATO y no la de escribirlo,
  · que cada suceso se escriba en SU ámbito y una sola vez,
  · que arrancar el colector no invente 108 transiciones.

    python tools/test_eventos.py
"""
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(RAIZ / "collector"))

from events import RegistroEventos                     # noqa: E402

T0 = datetime(2026, 8, 21, 3, 14, 0, tzinfo=timezone.utc)

ok, fallos = 0, []


def chk(nombre, actual, esperado):
    global ok
    if actual == esperado:
        ok += 1
        print(f"  ok    {nombre} = {actual!r}")
    else:
        fallos.append(nombre)
        print(f"  FALLO {nombre}: {actual!r} != {esperado!r}")


def chk_true(nombre, cond, detalle=""):
    global ok
    if cond:
        ok += 1
        print(f"  ok    {nombre}{(' — ' + detalle) if detalle else ''}")
    else:
        fallos.append(nombre)
        print(f"  FALLO {nombre}{(' — ' + detalle) if detalle else ''}")


def tcu(n, health="ok", alarms=(), modo="AUTO"):
    return {"tcu": n, "health": health, "alarms": list(alarms),
            "fields": {"main_state_txt": modo}}


def campos(ev):
    """Los campos de un Point ya construido, sin depender de su API interna."""
    linea = ev.to_line_protocol()
    etiquetas = dict(p.split("=", 1) for p in linea.split(" ")[0].split(",")[1:])
    valores = dict(p.split("=", 1) for p in linea.split(" ")[1].split(","))
    return etiquetas, {k: v.strip('"') for k, v in valores.items()}


def reg(interval=30.0):
    return RegistroEventos("burgo", "NCU-01", interval)


print("=== arrancar NO es un flanco ===")
r = reg()
prim = r.flancos([tcu(1), tcu(2, "alarm", ["axis_blocked"])], {"alarm_any_wind": 1}, [], T0)
chk("el primer ciclo no emite nada, ni con una alarma puesta", len(prim), 0)
# ...y el mutante de eso: si el estado no se hubiera aprendido, el segundo
# ciclo idéntico emitiría todo de golpe.
chk("y el segundo ciclo idéntico tampoco",
    len(r.flancos([tcu(1), tcu(2, "alarm", ["axis_blocked"])], {"alarm_any_wind": 1}, [], T0)), 0)

print("\n=== un flanco de salud, con la hora del DATO ===")
r = reg()
r.flancos([tcu(7)], {}, [], T0)
t1 = T0 + timedelta(seconds=30)
ev = r.flancos([tcu(7, "alarm", ["axis_blocked"])], {}, [], t1)
chk("un cambio de salud + su alarma = dos eventos", len(ev), 2)
salud = [e for e in ev if campos(e)[0]["kind"] == "health"][0]
et, va = campos(salud)
chk("ámbito", et["scope"], "tcu")
chk("lleva la etiqueta del TCU", et["tcu"], "7")
chk("de dónde viene", va["from"], "ok")
chk("a dónde va", va["to"], "alarm")
chk_true("EL SELLO ES LA HORA DEL CICLO, no la de escribir",
         str(int(t1.timestamp() * 1e9)) in salud.to_line_protocol(),
         f"{t1.isoformat()}")
chk("y publica la resolución del flanco (no se finge precisión)", va["res_s"], "30")
alarma = [e for e in ev if campos(e)[0]["kind"] == "alarma"][0]
chk("la alarma va con su NOMBRE, para poder filtrarla", campos(alarma)[1]["detail"], "axis_blocked")

print("\n=== el mutante del sello ===")
# Un punto SIN `.time()` deja que InfluxDB selle con la hora de escritura. La
# diferencia no se ve en el valor -- se ve en que la linea no lleva timestamp.
from influxdb_client import Point                       # noqa: E402
sin_sello = Point("event").tag("plant", "burgo").field("from", "ok").field("to", "alarm")
chk_true("sin .time() la línea NO lleva instante: el servidor pondría el suyo",
         sin_sello.to_line_protocol().rstrip()[-1] not in "0123456789" or
         len(sin_sello.to_line_protocol().split(" ")) < 3,
         sin_sello.to_line_protocol())
chk_true("y con .time() sí lo lleva", len(salud.to_line_protocol().split(" ")) == 3)

print("\n=== ámbitos reales: una alarma de NCU ocurre UNA vez, no 108 ===")
flota = [tcu(i) for i in range(1, 109)]
r = reg()
r.flancos(flota, {"alarm_any_wind": 0}, [], T0)
ev = r.flancos(flota, {"alarm_any_wind": 1}, [], T0 + timedelta(seconds=30))
chk("una alarma de viento = UN evento, no 108", len(ev), 1)
et, va = campos(ev[0])
chk("y su ámbito es la NCU", et["scope"], "ncu")
chk("con su tipo", et["kind"], "alarm_any_wind")
chk_true("y SIN etiqueta de TCU: una etiqueta vacía sería otra serie", "tcu" not in et)

print("\n=== la meteo tiene su propio ámbito, y por estación ===")
r = reg()
m0 = [{"hsu": 1, "fields": {"alarm_wind": 0}}, {"hsu": 2, "fields": {"alarm_wind": 0}}]
m1 = [{"hsu": 1, "fields": {"alarm_wind": 1}}, {"hsu": 2, "fields": {"alarm_wind": 0}}]
r.flancos([], {}, m0, T0)
ev = r.flancos([], {}, m1, T0 + timedelta(seconds=30))
chk("solo la estación que cambió", len(ev), 1)
et, _ = campos(ev[0])
chk("ámbito HSU", et["scope"], "hsu")

# El caso de campo del 21/8: el NIVEL de viento subio a 1 y nadie tenia el
# flanco con su hora. Y una bateria desconectada (bit 4, que antes ni se
# decodificaba) tambien deja rastro.
r2 = reg()
r2.flancos([], {}, [{"hsu": 1, "fields": {"wind_level": 0, "batt_disconnected": 0}}], T0)
ev2 = r2.flancos([], {}, [{"hsu": 1, "fields": {"wind_level": 1, "batt_disconnected": 1}}],
                 T0 + timedelta(seconds=30))
chk("nivel de viento y bateria: dos flancos", len(ev2), 2)
tipos2 = sorted(campos(e)[0]["kind"] for e in ev2)
chk("con sus nombres", ",".join(tipos2), "batt_disconnected,wind_level")
nivel_ev = [e for e in ev2 if campos(e)[0]["kind"] == "wind_level"][0]
chk("y el nivel dice de donde a donde", campos(nivel_ev)[1]["from"] + "->" + campos(nivel_ev)[1]["to"], "0->1")
chk("y dice cuál", et["hsu"], "1")

print("\n=== el reloj de la NCU no es un evento ===")
r = reg()
r.flancos([], {"date_time": 1_000_000, "alarm_any_wind": 0}, [], T0)
ev = r.flancos([], {"date_time": 1_000_030, "alarm_any_wind": 0}, [], T0 + timedelta(seconds=30))
chk_true("date_time cambia en CADA ciclo: sería un evento por ciclo, para siempre",
         len(ev) == 0, f"{len(ev)} eventos")

print("\n=== un TCU que aparece o desaparece es INVENTARIO, no salud ===")
r = reg()
r.flancos([tcu(1), tcu(2)], {}, [], T0)
ev = r.flancos([tcu(1)], {}, [], T0 + timedelta(seconds=30))
chk("un evento", len(ev), 1)
et, va = campos(ev[0])
chk("y no se disfraza de cambio de salud", et["kind"], "inventario")
chk("dice qué pasó", (va["from"], va["to"]), ("presente", "ausente"))

print("\n=== nada cambia -> nada se escribe ===")
r = reg()
r.flancos(flota, {"alarm_any_wind": 0}, [], T0)
chk_true("un ciclo tranquilo cuesta CERO puntos",
         len(r.flancos(flota, {"alarm_any_wind": 0}, [], T0 + timedelta(seconds=30))) == 0)

print(f"\n{'Todo OK' if not fallos else 'FALLAN ' + str(len(fallos))} ({ok} comprobaciones)")
sys.exit(1 if fallos else 0)
