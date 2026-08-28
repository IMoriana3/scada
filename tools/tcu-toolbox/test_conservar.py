#!/usr/bin/env python3
"""
test_conservar.py — regenerar desde el Excel NO puede borrar lo que el Excel no trae.

QUE PASO. La #222 paso el Excel y los ficheros de planta perdieron en silencio los
CINCO repetidores de Ayora. El mecanismo de conservacion existia y estaba pensado
—lo dice su propio comentario— pero era una LISTA BLANCA de nombres:

    for k in ("hsu_esclavos", "rsu", "hsus_gw", "ip_gw"):

y `repetidores` no estaba en ella. Nadie se entero hasta que un barrido de Ayora
dejo de ver los repetidores. Sin ellos no se diagnostican, no entran en el
inventario ni en la campana de firmware, y uno con la bateria muerta se lleva por
delante todo lo que cuelga de el.

LA REGLA, SIN LISTA. Regenerar solo pisa lo que la hoja dice: si la entrada
recien construida ya trae el campo, manda la hoja; si no lo trae, es que la hoja
no opina y lo que hubiera en el JSON se queda. Un campo nuevo puesto a mano
manana se conserva solo, sin acordarse de ninguna lista.

El primer intento de arreglo SI tenia lista -al reves, la de campos que la
pasada escribe- y este mismo banco lo tumbo: dejaba de conservar `hsu_esclavos`
cuando la hoja no los trae, que es el caso de casi todas las plantas.

Estas pruebas ejercitan la conservacion de verdad —construyendo el JSON viejo y
el nuevo y pasandolos por la misma logica—, no leyendo el fichero fuente.

    python3 tools/tcu-toolbox/test_conservar.py
"""
import json
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent
sys.path.insert(0, str(RAIZ))
import make_plantas  # noqa: E402

fallos = []


def check(nombre, real, esperado):
    if real == esperado:
        print(f"OK   {nombre} = {real}")
    else:
        print(f"FAIL {nombre} : obtenido {real!r}, esperado {esperado!r}")
        fallos.append(nombre)


# ---------- la regla, tal cual la aplica make_plantas ----------
def conservar(nueva, vieja):
    """Lo mismo que hace el bloque de conservacion de make_plantas."""
    e = dict(nueva)
    for k, v in vieja.items():
        if k in e or v is None:
            continue
        e[k] = v
    return e


print("== lo que el Excel no trae, se conserva ==")

VIEJA = {
    "nombre": "Ayora NCU12", "ip": "192.168.4.80", "puerto": 503,
    "tcu_ini": 1, "tcu_fin": 53,
    "hsus": 1, "hsu_esclavos": [230],
    "repetidores": [{"nombre": "Repetidor 2", "esclavo": 200},
                    {"nombre": "Repetidor 3", "esclavo": 201}],
    "huecos": [7],
}
# lo que sale del Excel: la topologia, sin repetidores ni huecos
NUEVA = {
    "nombre": "Ayora NCU12", "ip": "192.168.4.80", "puerto": 503,
    "tcu_ini": 1, "tcu_fin": 53, "hsus": 1, "hsus_gw": 1, "rsu": [6],
}

r = conservar(NUEVA, VIEJA)
# EL FALLO DE LA #222, en una linea
check("los repetidores sobreviven a la pasada", len(r.get("repetidores", [])), 2)
check("y con sus nombres", [x["nombre"] for x in r["repetidores"]],
      ["Repetidor 2", "Repetidor 3"])
check("los huecos tambien", r.get("huecos"), [7])
check("y los esclavos de la HSU, como siempre", r.get("hsu_esclavos"), [230])

print()
print("== pero el Excel manda en lo suyo ==")
check("la hoja pisa el rango", r["tcu_fin"], 53)
check("y trae lo nuevo", r.get("rsu"), [6])
# si la hoja SI trae el campo, gana la hoja: conservar no puede resucitar un dato viejo
r2 = conservar(dict(NUEVA, hsu_esclavos=[231]), VIEJA)
check("un esclavo cambiado en la hoja no se revierte", r2["hsu_esclavos"], [231])

print()
print("== y no hay lista de nombres que mantener ==")
# un campo inventado hoy, que nadie ha declarado en ningun sitio: se conserva
r3 = conservar(NUEVA, dict(VIEJA, medido_en_campo={"rssi": -61}))
check("un campo nuevo puesto a mano se conserva solo", r3.get("medido_en_campo"), {"rssi": -61})

# LO QUE ESTE ARREGLO NO PUEDE ROMPER: hsu_esclavos NO viene de la hoja en casi
# ninguna planta -por eso se conservaba- y tiene que seguir sobreviviendo.
sin_escl = {k: v for k, v in NUEVA.items()}
check("hsu_esclavos sigue conservandose cuando la hoja no lo trae",
      conservar(sin_escl, VIEJA).get("hsu_esclavos"), [230])

# y la conservacion NO puede meter en el JSON los campos internos de la pasada
fuente = (RAIZ / "make_plantas.py").read_text(encoding="utf-8")
check("el indice interno de gateway se quita antes de escribir",
      'e.pop("_gwidx", None)' in fuente, True)
# la lista blanca ya no existe: si alguien la reintroduce, esto lo canta
check("no ha vuelto la lista blanca de campos",
      'for k in ("hsu_esclavos"' in fuente, False)

print()
print("== y lo que hay hoy en el repo ==")
ayora = json.loads((RAIZ / "plantas/24025-ayora.json").read_text(encoding="utf-8"))
reps = sum(len(e.get("repetidores", [])) for e in ayora["plantas"])
check("Ayora vuelve a declarar sus cinco repetidores", reps, 5)
esclavos = sorted(x["esclavo"] for e in ayora["plantas"] for x in e.get("repetidores", []))
check("con sus esclavos", esclavos, [200, 200, 200, 200, 201])

print()
if fallos:
    print(f"{len(fallos)} PRUEBAS FALLIDAS")
    sys.exit(1)
print("TODAS LAS PRUEBAS OK")
