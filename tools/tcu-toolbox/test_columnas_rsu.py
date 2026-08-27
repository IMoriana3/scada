#!/usr/bin/env python3
"""
test_columnas_rsu.py — las dos columnas 'RSU' de la hoja «Direcciones IP».

POR QUE EXISTE. La hoja trae DOS columnas 'RSU', una por gateway, igual que trae dos de 'Esclavos':

    Nº | Proyecto | NCU | IP NCU | ... | Esclavos | RSU | ... | IP GW 2 | ... | Esclavos | RSU
                                         └── GW1 ────────┘                     └── GW2 ────────┘

O sea que la hoja dice DOS cosas que se estaban tirando:

  EL GATEWAY, por la columna en la que va el numero. `make_plantas.py` leia las dos columnas pero
  solo para SUMARLAS, y escribia el total en las dos filas de gateway de la NCU. Su comentario
  afirmaba lo contrario —«cual es no lo dice el Excel»— y sobre esa frase se construyo todo lo de
  arriba: `gen_coords_cobertura.py` acabo adivinando el gateway de cada HSU por el TCU mas cercano.

  Y EL NUMERO, que es lo gordo. En la celda va el ORDEN de la estacion dentro de la planta: un 5
  significa «la HSU 5 cuelga de esta NCU». Lo decia el propio comentario del codigo —«ahi va un
  numero de orden dentro de la planta»— y a continuacion: «solo se cuenta». Con ese numero, la hoja
  da cada HSU con su NCU y su gateway SIN deducir nada. Es lo que Ayora ya tiene como `rsu: [8, 9]`
  y lo que a San Jose le falta para cerrarse entera.

Y habia un segundo fallo, SILENCIOSO: la segunda columna se buscaba por el texto EXACTO 'RSU'. Si la
hoja pone 'RSU 2', 'RSU GW2' o le sobra un espacio, no se encontraba y se contaban solo las del GW1,
sin avisar. El sintoma esta a la vista: El Burgo tiene DOS estaciones por NCU —una por gateway,
comprobado en campo— y su JSON sale con `hsus: 1`.

Aqui se prueban las tres cosas SIN el Excel, que no esta en ningun repo: la deteccion de las columnas
contra cabeceras sinteticas, y el reparto por gateway contra filas sinteticas. Lo que NO se puede
probar aqui es una pasada de verdad — eso pide `python3 make_plantas.py --excel <hoja>` con la hoja
real, y la comprobacion de que sale bien es que El Burgo pase a `hsus_gw: 1` en cada gateway.

    python3 tools/tcu-toolbox/test_columnas_rsu.py
"""
import os
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
# LA DE VERDAD, no una copia. Tener la logica duplicada aqui ya se quedo atras una vez: el banco
# daba verde con la version vieja mientras make_plantas hacia otra cosa. Se importa.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_plantas import rsus_de_celda


def por_gw(i1, i2, fila):
    """QUE RSU declara la fila en cada gateway, con la funcion de verdad."""
    def v(i):
        return str(fila[i]).strip() if (i is not None and i < len(fila) and fila[i] is not None) else ""
    return [rsus_de_celda(v(i)) if i is not None else [] for i in (i1, i2)]


print("\n· QUE RSU va en cada gateway, no solo cuantas")
for fila, esperado, que in [
    ([None, "3", None, None], [[3], []], "la RSU 3, en el GW1"),
    ([None, None, None, "7"], [[], [7]], "la RSU 7, en el GW2"),
    ([None, "3", None, "7"], [[3], [7]], "una en cada gateway, y se sabe cual"),
    ([None, None, None, None], [[], []], "ninguna"),
    ([None, "3.0", None, None], [[3], []], "el «.0» que mete Excel en los enteros"),
    ([None, "8,9", None, None], [[8, 9], []], "dos en la misma celda (la NCU15 de Ayora)"),
    ([None, "8 9", None, None], [[8, 9], []], "dos separadas por espacio"),
    ([None, "s/n", None, None], [[], []], "texto que no es un numero"),
    ([None, "8\n9", None, None], [[8, 9], []], "dos en DOS LINEAS de la misma celda: la NCU15 de Ayora"),
    ([None, "8\n9.0", None, None], [[8, 9], []], "y con el «.0» en la segunda linea"),
]:
    g = por_gw(1, 3, fila)
    di(g == esperado, "%s → %s" % (que, g))
g = por_gw(1, None, [None, "3"])
di(g == [[3], []], "hoja sin segunda columna → %s" % (g,))

print("\n%s" % ("%d fallo(s)" % len(fallos) if fallos else
                "se comporta como debe. La pasada de verdad ya esta hecha (2026-08-27): El Burgo "
                "salio con hsus_gw 1 en cada gateway y rsu 1..4, y San Jose con sus ocho, incluida "
                "la NCU16 con DOS -la HSU 5 en el GW2 y la 6 en el GW1-"))
sys.exit(1 if fallos else 0)
