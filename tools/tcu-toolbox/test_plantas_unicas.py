#!/usr/bin/env python3
"""
test_plantas_unicas.py — una planta, UN fichero en plantas/.

POR QUE EXISTE. El 25/09/2026 El Burgo acabo con DOS ficheros identicos,
`elburgo.json` y `23003.json`, y el portatil de campo veia la planta duplicada
en la lista. No dio error en ningun sitio: los dos ficheros eran validos y el
tecnico elegia uno de los dos al azar.

Lo malo no fue el duplicado en si, fue que uno se quedo atras. Al sacar de
plants.yml la TCU 109 -un prototipo de certificaciones que no es un seguidor de
la planta- solo se actualizo uno de los dos, asi que la mitad de las veces el
109 seguia apareciendo. Un duplicado no es ruido: es una copia que se desvia.

La tabla MISMO_FICHERO de make_plantas.py existe justo para evitarlo, pero solo
la respetaba el camino de --tarjeta y no el de plants.yml. Y el workflow que
regenera plantas/ hace commit solo, sin pasar por aqui. De ahi esta prueba.

    python3 tools/tcu-toolbox/test_plantas_unicas.py
"""
import json
import os
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
DIR = os.path.join(AQUI, "plantas")

fallos = []


def di(ok, texto):
    print(("OK   " if ok else "FAIL ") + texto)
    if not ok:
        fallos.append(texto)


def entradas(doc):
    return doc.get("plantas") or []


ficheros = {}
for nombre in sorted(os.listdir(DIR)):
    if not nombre.endswith(".json"):
        continue
    with open(os.path.join(DIR, nombre), encoding="utf-8") as f:
        doc = json.load(f)
    if not isinstance(doc, dict) or "plantas" not in doc:
        continue          # ficheros de otra cosa (ambitos_*.json y demas)
    ficheros[nombre] = doc

di(len(ficheros) > 0, "hay ficheros de planta que comprobar (%d)" % len(ficheros))

# 1) NINGUNA ENTRADA REPETIDA ENTRE FICHEROS. Es el sintoma directo: dos
#    ficheros de la misma planta traen las mismas entradas con el mismo nombre.
de_quien = {}
for nombre, doc in ficheros.items():
    for e in entradas(doc):
        de_quien.setdefault(str(e.get("nombre")), []).append(nombre)
repes = {k: v for k, v in de_quien.items() if len(v) > 1}
di(not repes, "ninguna entrada sale en dos ficheros" +
   ("" if not repes else ": " + "; ".join("%s -> %s" % (k, ", ".join(v)) for k, v in sorted(repes.items()))))

# 2) NI DOS FICHEROS CONTRA LA MISMA NCU. Por si alguien renombra las entradas:
#    lo que de verdad identifica una planta es contra que aparatos habla.
ips = {}
for nombre, doc in ficheros.items():
    for e in entradas(doc):
        ip = str(e.get("ip") or "").strip()
        if ip:
            ips.setdefault(ip, set()).add(nombre)
cruce = {k: v for k, v in ips.items() if len(v) > 1}
di(not cruce, "ninguna NCU aparece en dos ficheros" +
   ("" if not cruce else ": " + "; ".join("%s -> %s" % (k, ", ".join(sorted(v))) for k, v in sorted(cruce.items()))))

# 3) Y la tabla que lo evita tiene que seguir apuntando a un fichero que exista:
#    si alguien renombra elburgo.json y no toca MISMO_FICHERO, vuelve el duplicado.
sys.path.insert(0, AQUI)
from make_plantas import MISMO_FICHERO                                # noqa: E402

for pid, fich in MISMO_FICHERO.items():
    di(os.path.exists(os.path.join(DIR, fich)),
       "MISMO_FICHERO[%s] apunta a %s, que existe" % (pid, fich))
    di(not os.path.exists(os.path.join(DIR, "%s.json" % pid)),
       "y no esta ademas el %s.json que generaria el duplicado" % pid)

print()
if fallos:
    print("FALLOS: %d" % len(fallos))
    sys.exit(1)
print("plantas/: una planta, un fichero. OK")
