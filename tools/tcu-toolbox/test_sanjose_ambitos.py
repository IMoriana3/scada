#!/usr/bin/env python3
"""
test_sanjose_ambitos.py — que San Jose declare los TCU que de verdad tiene.

POR QUE EXISTE. La hoja «Direcciones IP» da los esclavos por RANGOS, y en San
Jose se le habian colado tres errores que nadie podia ver de un vistazo:

  · NCU3  — el TCU 46 estaba en los DOS gateways;
  · NCU9  — el TCU 49 no estaba en ninguno (GW1 acababa en 48, GW2 empezaba en 50);
  · NCU17 — el GW2 acababa en 112 y llega al 122: DIEZ seguidores que la toolbox
            no leia jamas. Ni inventario, ni firmware, ni baterias, ni cobertura.

Se vieron cruzando con el EXCEL DE COORDENADAS de la planta, que declara el
gateway y el numero de TCU seguidor a seguidor. De 38 ambitos (NCU,GW), 35 ya
coincidian: la fuente es de fiar.

Y esto no se arregla una vez. `make_plantas.py --excel` regenera desde la hoja,
asi que mientras la hoja siga mal, la proxima pasada vuelve a meterlos EN
SILENCIO. Este banco lo cantaria.

    python3 tools/tcu-toolbox/test_sanjose_ambitos.py
"""
import json
import os
import re
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
esperado = json.load(open(os.path.join(AQUI, "plantas", "ambitos_24019-san-jose.json"),
                          encoding="utf-8"))
plantas = json.load(open(os.path.join(AQUI, "plantas", "24019-san-jose.json"),
                         encoding="utf-8"))["plantas"]

hay = {}
for p in plantas:
    m = re.search(r"NCU\s*(\d+)", p.get("nombre") or "")
    g = re.search(r"GW\s*(\d+)", p.get("nombre") or "")
    if not m or p.get("tcu_ini") is None:
        continue
    hay.setdefault((int(m.group(1)), int(g.group(1)) if g else 1), set()).update(
        range(int(p["tcu_ini"]), int(p["tcu_fin"]) + 1))

fallos, n = [], 0


def di(ok, texto, extra=None):
    global n
    n += 1
    if not ok:
        fallos.append(texto)
    print("  %s %s%s" % ("OK   " if ok else "FALLO", texto,
                         "" if ok or extra is None else "  -> %s" % (extra,)))


print("\n· cada (NCU, GW) declara exactamente los TCU del Excel de coordenadas")
quiero = {}
for ncu, gws in esperado["ambitos"].items():
    for gw, tr in gws.items():
        quiero[(int(ncu), int(gw))] = {x for a, b in tr for x in range(a, b + 1)}

mal = []
for k in sorted(set(quiero) | set(hay)):
    a, b = quiero.get(k, set()), hay.get(k, set())
    if a != b:
        mal.append("NCU%d GW%d: faltan %s%s" % (
            k[0], k[1], sorted(a - b)[:12],
            "; sobran %s" % sorted(b - a)[:12] if b - a else ""))
di(not mal, "los %d ámbitos cuadran" % len(quiero), mal[:3])

print("\n· y ninguno de los tres errores de la hoja ha vuelto")
di(46 not in hay.get((3, 2), set()), "NCU3: el TCU 46 no está en los dos gateways")
di(46 in hay.get((3, 1), set()), "         y sí está en el suyo, el GW1")
di(49 in hay.get((9, 2), set()), "NCU9: el TCU 49 existe y cuelga del GW2")
di(set(range(113, 123)) <= hay.get((17, 2), set()),
   "NCU17: el GW2 llega al 122, no al 112",
   sorted(set(range(113, 123)) - hay.get((17, 2), set())))

print("\n· y el total")
di(sum(len(v) for v in hay.values()) == esperado["seguidores"],
   "%d seguidores declarados" % esperado["seguidores"],
   sum(len(v) for v in hay.values()))
# un TCU en dos gateways a la vez no existe: seria sondearlo dos veces por dos
# puertos, y el que no conteste por uno de ellos saldria como caido
solapes = []
for ncu in {k[0] for k in hay}:
    g1, g2 = hay.get((ncu, 1), set()), hay.get((ncu, 2), set())
    if g1 & g2:
        solapes.append("NCU%d: %s" % (ncu, sorted(g1 & g2)))
di(not solapes, "ningún TCU cuelga de dos gateways a la vez", solapes)

print("\n%d comprobaciones, %d fallos" % (n, len(fallos)))
sys.exit(1 if fallos else 0)
