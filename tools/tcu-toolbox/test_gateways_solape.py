#!/usr/bin/env python3
"""
test_gateways_solape.py — un TCU cuelga de UN gateway, y eso hay que comprobarlo.

POR QUE EXISTE. En San Jose el TCU 46 de la NCU3 salia en los DOS gateways. Eso
no da error en ningun sitio: la toolbox lo sondea por los dos puertos y lo da
por CAIDO cuando no contesta por el que no es el suyo. Y mirando la hoja
«Direcciones IP» no se ve — los rangos estan en columnas distintas y hay que
juntarlos para que salte.

Se encontro por casualidad, cruzando con el Excel de coordenadas. Esto lo
convierte en una comprobacion de cada pasada, para todas las plantas.

EL HUECO SE TRATA DISTINTO, Y A PROPOSITO. Un TCU retirado deja su numero vacio
y los demas NO se renumeran: Ayora NCU7 tiene el 14 asi y El Burgo el 108. O sea
que un hueco puede ser perfectamente bueno, y por eso se CUENTA en vez de
cantarse como fallo. Pero tambien fue el sintoma de San Jose NCU9 -el 49 no
colgaba de ninguno-, asi que callarlo tampoco vale.

    python3 tools/tcu-toolbox/test_gateways_solape.py
"""
import io
import os
import sys
from contextlib import redirect_stdout

AQUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, AQUI)
from make_plantas import revisa_gateways                              # noqa: E402

fallos, n = [], 0


def di(ok, texto, extra=None):
    global n
    n += 1
    if not ok:
        fallos.append(texto)
    print("  %s %s%s" % ("OK   " if ok else "FALLO", texto,
                         "" if ok or extra is None else "  -> %s" % (extra,)))


def e(nombre, ini, fin):
    return {"nombre": nombre, "tcu_ini": ini, "tcu_fin": fin}


def corre(entradas):
    cap = io.StringIO()
    with redirect_stdout(cap):
        sol, hue = revisa_gateways(entradas, "prueba.json")
    return sol, hue, cap.getvalue()


print("\n· el mismo TCU en dos gateways: siempre mal")
# el caso de San Jose NCU3, tal cual estaba
sol, hue, log = corre([e("San Jose NCU3 GW1", 1, 46), e("San Jose NCU3 GW2", 46, 120)])
di(len(sol) == 1 and sol[0][3] == [46], "lo caza", sol)
di("!!" in log, "y lo marca como fallo, no como nota", log)
di("por los dos puertos" in log and "caido" in log,
   "diciendo la consecuencia: se sondea dos veces y sale caido", log)
di(not hue, "y no confunde un solape con un hueco", hue)

print("\n· varios TCU solapados, y varias NCU")
sol, _h, log = corre([e("P NCU1 GW1", 1, 50), e("P NCU1 GW2", 48, 100),
                      e("P NCU2 GW1", 1, 30), e("P NCU2 GW2", 31, 60)])
di(len(sol) == 1 and sol[0][3] == [48, 49, 50], "los tres del solape, y solo la NCU1", sol)

print("\n· lo que está bien no se canta")
sol, hue, log = corre([e("P NCU1 GW1", 1, 47), e("P NCU1 GW2", 48, 119)])
di(not sol and not hue, "dos gateways pegados, sin solape ni hueco", (sol, hue))
di(log.strip() == "", "y sin una línea de ruido", log)
sol, hue, _l = corre([e("P NCU1", 1, 63)])
di(not sol and not hue, "una NCU de un solo gateway tampoco")

print("\n· el hueco se cuenta, pero NO es un fallo")
# Ayora NCU7: el 14 es una TCU retirada. Cantarlo como error seria pedir que se
# «arregle» algo que esta bien, y a la tercera vez nadie lee los avisos.
sol, hue, log = corre([e("Ayora NCU7 (TCU 1-13)", 1, 13), e("Ayora NCU7 (TCU 15-23)", 15, 23)])
di(len(hue) == 1 and hue[0][1] == [14], "lo ve", hue)
di("!!" not in log, "pero no lo marca como fallo: puede ser una TCU retirada", log)
di("retirada" in log, "y dice los dos motivos posibles", log)
di(not sol, "y no es un solape", sol)

# San Jose NCU9: el mismo sintoma, pero aqui el 49 SI existia
sol, hue, log = corre([e("San Jose NCU9 GW1", 1, 48), e("San Jose NCU9 GW2", 50, 120)])
di(len(hue) == 1 and hue[0][1] == [49], "el caso de la NCU9 sale igual", hue)
di("rango mal puesto" in log, "por eso el aviso nombra tambien esa posibilidad", log)

print("\n· un hueco largo no llena la pantalla")
sol, hue, log = corre([e("P NCU1 GW1", 1, 10), e("P NCU1 GW2", 40, 60)])
di(len(hue) == 1 and len(hue[0][1]) == 29, "los cuenta todos",
   [len(x[1]) for x in hue])
di("..." in log, "pero solo enseña los primeros", log.strip()[:120])

print("\n· entradas sin rango o sin NCU no rompen nada")
sol, hue, _l = corre([{"nombre": "P NCU1 GW1", "tcu_ini": None, "tcu_fin": None},
                      {"nombre": "sin ncu", "tcu_ini": 1, "tcu_fin": 5},
                      e("P NCU1 GW1", 1, 20)])
di(not sol and not hue, "se saltan sin quejarse", (sol, hue))

print("\n%d comprobaciones, %d fallos" % (n, len(fallos)))
sys.exit(1 if fallos else 0)
