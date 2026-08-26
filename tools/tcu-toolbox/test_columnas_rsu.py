#!/usr/bin/env python3
"""
test_columnas_rsu.py — las dos columnas 'RSU' de la hoja «Direcciones IP».

POR QUE EXISTE. La hoja trae DOS columnas 'RSU', una por gateway, igual que trae dos de 'Esclavos':

    Nº | Proyecto | NCU | IP NCU | ... | Esclavos | RSU | ... | IP GW 2 | ... | Esclavos | RSU
                                         └── GW1 ────────┘                     └── GW2 ────────┘

O sea que la hoja SI dice de que gateway cuelga cada estacion: lo dice la columna en la que va el
numero. `make_plantas.py` las leia las dos, pero solo para SUMARLAS, y escribia el total en las dos
filas de gateway de la NCU. Su propio comentario afirmaba lo contrario —«cual es no lo dice el
Excel»— y sobre esa frase se construyo todo lo de arriba: `gen_coords_cobertura.py` acabo adivinando
el gateway de cada HSU por el TCU mas cercano.

Y habia un segundo fallo, SILENCIOSO: la segunda columna se buscaba por el texto EXACTO 'RSU'. Si la
hoja pone 'RSU 2', 'RSU GW2' o le sobra un espacio, no se encontraba y se contaban solo las del GW1,
sin avisar. El sintoma esta a la vista: El Burgo tiene DOS estaciones por NCU —una por gateway,
comprobado en campo— y su JSON sale con `hsus: 1`.

Aqui se prueban las dos cosas SIN el Excel, que no esta en ningun repo: la deteccion de las columnas
contra cabeceras sinteticas, y el reparto por gateway contra filas sinteticas. Lo que NO se puede
probar aqui es una pasada de verdad — eso pide `python3 make_plantas.py --excel <hoja>` con la hoja
real, y la comprobacion de que sale bien es que El Burgo pase a `hsus_gw: 1` en cada gateway.

    python3 tools/tcu-toolbox/test_columnas_rsu.py
"""
import re
import sys

fallos = []


def di(ok, texto):
    if not ok:
        fallos.append(texto)
    print("  %s %s" % ("ok   " if ok else "FALLA", texto))


# ── la deteccion de las dos columnas ─────────────────────────────────────────────────────────────
def detecta(head):
    """Lo mismo que hace make_plantas.py: la primera 'RSU*' de la hoja y la primera tras 'IP GW 2'."""
    i1 = next((k for k in range(len(head))
               if str(head[k] or "").strip().upper().startswith("RSU")), None)
    i2 = None
    if i1 is not None and "IP GW 2" in head:
        desde = head.index("IP GW 2")
        for k in range(desde, len(head)):
            if str(head[k] or "").strip().upper().startswith("RSU"):
                i2 = k
                break
    return i1, i2


print("· las dos columnas 'RSU' de la hoja")
for head, esperado, que in [
    (["Nº", "Proyecto", "NCU", "IP NCU", "Esclavos", "RSU", "IP GW 2", "Esclavos", "RSU"], (5, 8), "las dos exactas"),
    (["Nº", "NCU", "Esclavos", "RSU", "IP GW 2", "Esclavos", "RSU 2"], (3, 6), "la segunda como «RSU 2»"),
    (["Nº", "NCU", "Esclavos", "RSU GW1", "IP GW 2", "Esclavos", "RSU GW2"], (3, 6), "las dos con sufijo"),
    (["Nº", "NCU", "Esclavos", "RSU ", "IP GW 2", "Esclavos", "RSU "], (3, 6), "con espacios de sobra"),
    (["Nº", "NCU", "Esclavos", "RSU", "IP GW 2", "Esclavos"], (3, None), "sin segunda columna: avisa y cuenta solo el GW1"),
    (["Nº", "NCU", "Esclavos"], (None, None), "sin ninguna: no se cuentan estaciones"),
]:
    di(detecta(head) == esperado, "%s → %s" % (que, detecta(head)))


# ── el reparto por gateway ───────────────────────────────────────────────────────────────────────
def por_gw(i1, i2, fila):
    """Lo mismo que rsus_por_gw(): cuantas RSU declara la fila EN CADA gateway."""
    def v(i):
        return str(fila[i]).strip() if (i is not None and i < len(fila) and fila[i] is not None) else ""
    return [1 if (i is not None and re.match(r"^\d+$", re.sub(r"\.0$", "", v(i)))) else 0
            for i in (i1, i2)]


print("\n· cuantas RSU van en cada gateway")
for fila, esperado, que in [
    ([None, "3", None, None], [1, 0], "solo en la columna del GW1"),
    ([None, None, None, "7"], [0, 1], "solo en la del GW2"),
    ([None, "3", None, "7"], [1, 1], "una en cada gateway"),
    ([None, None, None, None], [0, 0], "ninguna"),
    ([None, "3.0", None, None], [1, 0], "el «.0» que mete Excel en los enteros"),
]:
    g = por_gw(1, 3, fila)
    di(g == esperado, "%s → %s" % (que, g))
g = por_gw(1, None, [None, "3"])
di(g == [1, 0], "hoja sin segunda columna → %s" % (g,))

print("\n%s" % ("%d fallo(s)" % len(fallos) if fallos else
                "las dos cosas se comportan como deben. Falta la pasada de verdad contra la hoja: "
                "`make_plantas.py --excel`, y comprobar que El Burgo sale con hsus_gw 1 por gateway"))
sys.exit(1 if fallos else 0)
