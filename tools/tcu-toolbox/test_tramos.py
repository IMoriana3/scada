#!/usr/bin/env python3
"""
test_tramos.py — los TRAMOS de la celda 'Esclavos', y que ninguna NCU se caiga sola.

POR QUE EXISTE. Una NCU no siempre tiene un solo tramo de TCUs: hay huecos. Cuando
la celda no se sabe leer, `parse_rangos` devuelve [] y esa NCU **desaparece entera
del fichero sin decir nada**. No es un rango mal puesto: es una NCU que la toolbox
no lee jamas —ni inventario, ni firmware, ni baterias, ni cobertura— y solo se
descubre cuando alguien va a la planta y le faltan seguidores.

Ya paso dos veces con el mismo fallo y un separador distinto:

  · San Jose, con las celdas de varias LINEAS: se perdieron cinco NCUs (7, 12, 16,
    17 y 19) y tres HSU se quedaron sin asignar;
  · Ayora NCU7, con la celda «1-13 15-23» en una sola linea, separada por un
    ESPACIO. La NCU7 no salia.

Asi que aqui se fija que separadores valen, que «1 - 13» sigue siendo UN tramo (y no
los TCU 1 y 13), y sobre todo que una celda que no da tramos se CANTA por consola en
vez de tragarse la NCU.

    python3 tools/tcu-toolbox/test_tramos.py
"""
import io
import json
import os
import sys
import tempfile
from contextlib import redirect_stdout

AQUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, AQUI)
from make_plantas import parse_rangos, parse_rango, modo_excel        # noqa: E402

fallos = []
n = 0


def di(ok, texto, extra=None):
    global n
    n += 1
    if not ok:
        fallos.append(texto)
    print("  %s %s%s" % ("OK   " if ok else "FALLO", texto,
                         "" if ok or extra is None else "  -> %s" % (extra,)))


CAB = ["Nº", "Proyecto", "NCU", "IP NCU", "IP GW 1", "Esclavos", "RSU",
       "IP GW 2", "Esclavos", "RSU"]


def pasada(filas):
    """Una pasada de verdad, en un directorio aparte: `modo_excel` escribe en
    `plantas/` relativo al directorio actual y corriendo aqui te machaca el repo."""
    from openpyxl import Workbook
    wb = Workbook()
    ws = wb.active
    ws.title = "Direcciones IP"
    ws.append(CAB)
    ws.append([""] * len(CAB))
    for f in filas:
        ws.append(f)
    ruta = os.path.join(tempfile.mkdtemp(), "m.xlsx")
    wb.save(ruta)
    prev, tmp, cap = os.getcwd(), tempfile.mkdtemp(), io.StringIO()
    try:
        os.chdir(tmp)
        with redirect_stdout(cap):
            salidas = modo_excel(ruta, "Direcciones IP", [503, 504], [], "")
        return json.loads(open(salidas[0][0], encoding="utf-8").read())["plantas"], cap.getvalue()
    finally:
        os.chdir(prev)


# ── los separadores ──────────────────────────────────────────────────────────
print("\n· la celda se parte por donde sea que este partida")
di(parse_rangos("1-13 15-23") == [(1, 13), (15, 23)],
   "por ESPACIOS, como la guarda la tabla de topologia", parse_rangos("1-13 15-23"))
di(parse_rangos("15-19\n27-35\n53-61\n68-76\n95-103")
   == [(15, 19), (27, 35), (53, 61), (68, 76), (95, 103)],
   "por LINEAS, como la NCU16 de San Jose", parse_rangos("15-19\n27-35"))
di(parse_rangos("1-13, 15-23") == [(1, 13), (15, 23)], "por comas")
di(parse_rangos("1-13; 15-23") == [(1, 13), (15, 23)], "por puntos y coma")
di(parse_rangos("10-17 28-40 52-64") == [(10, 17), (28, 40), (52, 64)],
   "y con tres tramos igual", parse_rangos("10-17 28-40 52-64"))

print("\n· pero un espacio dentro de un tramo NO lo parte")
di(parse_rangos("1 - 13") == [(1, 13)],
   "«1 - 13» es el tramo 1-13, no los TCU 1 y 13", parse_rangos("1 - 13"))
di(parse_rangos("1- 13") == [(1, 13)] and parse_rangos("1 -13") == [(1, 13)],
   "con el espacio a un lado tampoco")

print("\n· lo que no es un tramo no inventa TCUs")
di(parse_rangos("-") == [], "el guion de «no hay»", parse_rangos("-"))
di(parse_rangos("") == [] and parse_rangos(None) == [], "vacio y nulo")
di(parse_rangos("1-56 (sin la 12)") == [(1, 56)],
   "una nota al lado no se cuela como TCU", parse_rangos("1-56 (sin la 12)"))
di(parse_rango("1-13 15-23") == (1, 13), "y el tramo global sigue siendo el primero",
   parse_rango("1-13 15-23"))

# ── la NCU no se cae, y si se cae se oye ─────────────────────────────────────
print("\n· una NCU con varios tramos SALE en el fichero")
ent, log = pasada([["24025", "Ayora", 7, "192.168.4.55", "", "1-13 15-23", "", "", "", ""]])
di(len(ent) == 2, "la NCU7 de Ayora sale, y con una entrada por tramo", len(ent))
di([(e["tcu_ini"], e["tcu_fin"]) for e in ent] == [(1, 13), (15, 23)],
   "con los TCU que hay de verdad: 22, sin el 14 ni el 24 y 25",
   [(e["tcu_ini"], e["tcu_fin"]) for e in ent])
di([e["nombre"] for e in ent] == ["Ayora NCU7 (TCU 1-13)", "Ayora NCU7 (TCU 15-23)"],
   "y el rango en el nombre para distinguirlas", [e["nombre"] for e in ent])
di("no da ningun tramo" not in log, "sin cantar ninguna NCU perdida", log)

print("\n· y si la celda no da ningun tramo, se CANTA")
ent, log = pasada([
    ["24025", "Ayora", 6, "192.168.4.50", "", "1-26", "", "", "", ""],
    ["24025", "Ayora", 7, "192.168.4.55", "", "los de la fila de abajo", "", "", "", ""],
])
di(len(ent) == 1 and ent[0]["nombre"] == "Ayora NCU6",
   "la NCU ilegible no sale (no se puede inventar su rango)", [e["nombre"] for e in ent])
di("NCU7" in log and "no da ningun tramo" in log,
   "pero lo dice, con la NCU y la celda", log)
di("los de la fila de abajo" in log, "y ensena la celda para poder arreglarla", log)
di("NO sale en el fichero" in log, "diciendo la consecuencia, no solo el sintoma", log)

print("\n· una celda vacia no es un error: esa NCU simplemente no tiene ese gateway")
ent, log = pasada([["23003", "Burgo I", 1, "10.100.1.52", "10.100.1.53", "1-56", "",
                    "10.100.1.54", "", ""]])
di(len(ent) == 1, "sale solo el gateway que tiene esclavos", len(ent))
di("no da ningun tramo" not in log, "y no se canta nada", log)

print("\n%d comprobaciones, %d fallos" % (n, len(fallos)))
sys.exit(1 if fallos else 0)
