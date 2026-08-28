#!/usr/bin/env python3
"""
test_tarjeta.py — meter en plantas/ la IP del gateway que exporta la tarjeta.

POR QUE EXISTE. La tabla «IPs de plantas» tiene las IPs de los ConnectPort y las
exporta en JSONs con esta misma forma. Meterlas a mano en plantas/ es justo el
sitio donde se cuela el error caro: escribir la del Modbus de la NCU en vez de la
del gateway. Son dos aparatos —en El Burgo la NCU .52 tiene los gateways .53 y
.54— y quien sale a medir cobertura pregunta al segundo. Poner la equivocada no
da error: da una jornada de campo midiendo contra el sitio que no es.

QUE SE COMPRUEBA, con pasadas de verdad sobre una carpeta plantas/ de mentira:

  · que empareja por (NCU, puerto) y NO por nombre —el Excel dice «Burgo I» y
    plants.yml «El Burgo I», y de ahi no sale—, incluido el fichero de El Burgo,
    que se llama distinto;
  · que si un (NCU, puerto) tiene varios tramos, la IP va en todos;
  · que NO escribe una IP igual a la del Modbus, ni una que no sea una IP;
  · que no toca NADA mas del fichero: ni rangos, ni rsu, ni hsu_esclavos;
  · que los rangos que no cuadran con la tabla se CANTAN pero no se tocan: eso lo
    decide una persona mirando la planta;
  · y que un export sin ip_gw no reescribe ningun fichero.

    python3 tools/tcu-toolbox/test_tarjeta.py
"""
import json
import os
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

AQUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, AQUI)
from make_plantas import modo_tarjeta                                  # noqa: E402

fallos = []
n = 0


def di(cond, que, extra=""):
    global n
    n += 1
    if cond:
        print("  OK   " + que)
    else:
        fallos.append(que)
        print("  FALLO " + que + ("  -> " + str(extra) if extra != "" else ""))


def pl(nombre, ip, puerto, ini, fin, **kw):
    d = {"nombre": nombre, "ip": ip, "puerto": puerto, "tcu_ini": ini, "tcu_fin": fin}
    d.update(kw)
    return d


def escribe(ruta, entradas):
    Path(ruta).write_text(json.dumps({"_comentario": "x", "version": 1, "plantas": entradas},
                                     ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def carga(ruta):
    return json.loads(Path(ruta).read_text(encoding="utf-8"))["plantas"]


# ── el caso normal ───────────────────────────────────────────────────────────
print("\n· la IP del gateway entra donde toca")
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    dirp = tmp / "plantas"
    dirp.mkdir()
    exp = tmp / "exp"
    exp.mkdir()
    # plantas/: los nombres son los de plants.yml («El Burgo I»), y el fichero de
    # El Burgo se llama distinto. Ademas el GW2 tiene el TCU 109 suelto.
    escribe(dirp / "elburgo.json", [
        pl("El Burgo I NCU1 GW1", "10.100.1.52", 503, 1, 56, hsus=1, rsu=[1]),
        pl("El Burgo I NCU1 GW2", "10.100.1.52", 504, 57, 108, hsus=1, rsu=[2]),
        pl("El Burgo I NCU2 GW1", "10.100.1.56", 503, 1, 45),
        pl("El Burgo I NCU2 GW2", "10.100.1.56", 504, 46, 107),
        pl("El Burgo I NCU2 GW2 (TCU 109-109)", "10.100.1.56", 504, 109, 109),
    ])
    # el export de la tarjeta: la planta se llama «Burgo I» y el fichero lleva el codigo
    escribe(exp / "23003-burgo-i.json", [
        pl("Burgo I NCU1 GW1", "10.100.1.52", 503, 1, 56, ip_gw="10.100.1.53"),
        pl("Burgo I NCU1 GW2", "10.100.1.52", 504, 57, 108, ip_gw="10.100.1.54"),
        pl("Burgo I NCU2 GW1", "10.100.1.56", 503, 1, 45, ip_gw="10.100.1.57"),
        pl("Burgo I NCU2 GW2", "10.100.1.56", 504, 46, 107, ip_gw="10.100.1.58"),
    ])
    escritos, avisos = modo_tarjeta([exp], dirp)
    ent = carga(dirp / "elburgo.json")
    di([e.get("ip_gw") for e in ent] == ["10.100.1.53", "10.100.1.54", "10.100.1.57",
                                         "10.100.1.58", "10.100.1.58"],
       "cada entrada con la IP de SU gateway", [e.get("ip_gw") for e in ent])
    di(all(e.get("ip_gw") != e["ip"] for e in ent), "y ninguna es la del Modbus",
       [e.get("ip_gw") for e in ent])
    di(ent[4].get("ip_gw") == ent[3].get("ip_gw") is not None,
       "el tramo suelto del 504 comparte gateway con su puerto", ent[4].get("ip_gw"))
    di(not (dirp / "23003-burgo-i.json").exists(),
       "no crea un El Burgo por duplicado con el nombre del export")
    di(sorted(p.name for p in dirp.iterdir()) == ["elburgo.json"],
       "y no aparece ningun fichero nuevo", sorted(p.name for p in dirp.iterdir()))
    di([e.get("rsu") for e in ent[:2]] == [[1], [2]], "el rsu de antes sigue ahi",
       [e.get("rsu") for e in ent[:2]])
    di([(e["tcu_ini"], e["tcu_fin"], e["puerto"]) for e in ent]
       == [(1, 56, 503), (57, 108, 504), (1, 45, 503), (46, 107, 504), (109, 109, 504)],
       "y los rangos no se han movido")
    di([e["nombre"] for e in ent][0] == "El Burgo I NCU1 GW1",
       "los nombres siguen siendo los de aqui, no los del export")
    # el TCU 109 suelto no sale de ninguna hoja (viene de los .bat de Sunner), asi
    # que la tabla no lo tiene: se canta, y se queda donde estaba
    di(avisos == ["elburgo.json: NCU2 puerto 504 no cuadra con la tabla; aqui de mas [109]"],
       "el unico aviso es el TCU 109 que la tabla no conoce", avisos)

# ── lo que NO debe escribir ──────────────────────────────────────────────────
print("\n· una IP dudosa no entra: es peor que ninguna")
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    dirp = tmp / "plantas"
    dirp.mkdir()
    exp = tmp / "exp"
    exp.mkdir()
    escribe(dirp / "24025-ayora.json", [
        pl("Ayora NCU1", "192.168.4.10", 503, 1, 63),
        pl("Ayora NCU2", "192.168.4.20", 503, 1, 69),
        pl("Ayora NCU3", "192.168.4.30", 503, 1, 66),
        pl("Ayora NCU4", "192.168.4.40", 503, 1, 30),
    ])
    escribe(exp / "24025-ayora.json", [
        # la del Modbus repetida: el error caro
        pl("Ayora NCU1", "192.168.4.10", 503, 1, 63, ip_gw="192.168.4.10"),
        pl("Ayora NCU2", "192.168.4.20", 503, 1, 69, ip_gw="192.168.4.256"),
        pl("Ayora NCU3", "192.168.4.30", 503, 1, 66, ip_gw="pendiente"),
        pl("Ayora NCU4", "192.168.4.40", 503, 1, 30, ip_gw="192.168.4.41"),
    ])
    antes = (dirp / "24025-ayora.json").read_text(encoding="utf-8")
    escritos, avisos = modo_tarjeta([exp], dirp)
    ent = carga(dirp / "24025-ayora.json")
    di(ent[0].get("ip_gw") is None, "la del Modbus NO se escribe", ent[0].get("ip_gw"))
    di(any("igual que el Modbus" in a for a in avisos), "y se canta", avisos)
    di(ent[1].get("ip_gw") is None, "un octeto de 256 tampoco", ent[1].get("ip_gw"))
    di(ent[2].get("ip_gw") is None, "ni una celda con texto", ent[2].get("ip_gw"))
    di(ent[3].get("ip_gw") == "192.168.4.41", "y la buena si entra", ent[3].get("ip_gw"))
    di(sum(1 for a in avisos if "no es una IP" in a) == 2, "dos avisos de IP invalida", avisos)

print("\n· un export sin ip_gw no reescribe nada")
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    dirp = tmp / "plantas"
    dirp.mkdir()
    exp = tmp / "exp"
    exp.mkdir()
    escribe(dirp / "24021-tunez.json", [pl("Tunez NCU1", "192.168.1.111", 503, 1, 19)])
    escribe(exp / "24021-tunez.json", [pl("Túnez NCU1", "192.168.1.111", 503, 1, 19, trackers=19)])
    antes = (dirp / "24021-tunez.json").read_text(encoding="utf-8")
    escritos, avisos = modo_tarjeta([exp], dirp)
    di(escritos == [], "no escribe ningun fichero", escritos)
    di((dirp / "24021-tunez.json").read_text(encoding="utf-8") == antes,
       "el fichero se queda byte a byte igual")

print("\n· lo que no casa se canta, no se inventa")
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    dirp = tmp / "plantas"
    dirp.mkdir()
    exp = tmp / "exp"
    exp.mkdir()
    escribe(dirp / "24007-fayon.json", [pl("Fayon NCU1", "192.168.1.150", 503, 1, 24)])
    escribe(exp / "24007-fayon.json", [
        pl("Fayón NCU1", "192.168.1.150", 503, 1, 24, ip_gw="192.168.1.151"),
        pl("Fayón NCU9", "192.168.1.190", 503, 1, 10, ip_gw="192.168.1.191"),
    ])
    escribe(exp / "99999-marte.json", [pl("Marte NCU1", "10.0.0.1", 503, 1, 5, ip_gw="10.0.0.2")])
    escritos, avisos = modo_tarjeta([exp], dirp)
    ent = carga(dirp / "24007-fayon.json")
    di(len(ent) == 1 and ent[0].get("ip_gw") == "192.168.1.151",
       "la que casa entra y no se anaden entradas", ent)
    di(any("NCU9" in a and "no casa" in a for a in avisos), "la NCU que aqui no existe se canta", avisos)
    di(any("no hay" in a and "marte" in a for a in avisos),
       "y una planta que no esta en plantas/ tambien", avisos)
    di(not (dirp / "99999-marte.json").exists(), "sin crearla")

print("\n· los rangos que no cuadran se cantan, pero NO se tocan")
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    dirp = tmp / "plantas"
    dirp.mkdir()
    exp = tmp / "exp"
    exp.mkdir()
    escribe(dirp / "24019-san-jose.json", [
        pl("San Jose NCU7 GW1", "10.21.236.41", 503, 1, 25),          # aqui 1-25
        pl("San Jose NCU8 GW1", "10.21.236.36", 503, 1, 48),
        pl("San Jose NCU8 GW2", "10.21.236.36", 504, 50, 119),        # aqui falta el 49
    ])
    escribe(exp / "24019-san-jose.json", [
        pl("San Jose NCU7 GW1", "10.21.236.41", 503, 1, 23, huecos=[14], ip_gw="10.21.236.42"),
        pl("San Jose NCU8 GW1", "10.21.236.36", 503, 1, 48, ip_gw="10.21.236.37"),
        pl("San Jose NCU8 GW2", "10.21.236.36", 504, 49, 119, ip_gw="10.21.236.38"),
    ])
    escritos, avisos = modo_tarjeta([exp], dirp)
    ent = carga(dirp / "24019-san-jose.json")
    di((ent[0]["tcu_ini"], ent[0]["tcu_fin"], ent[0].get("huecos")) == (1, 25, None),
       "el rango de aqui manda: no lo recorta la tarjeta", ent[0])
    di(ent[2]["tcu_ini"] == 50, "ni lo estira", ent[2]["tcu_ini"])
    di(any("NCU7" in a and "de mas [14, 24, 25]" in a for a in avisos),
       "canta los tres que aqui sobran", avisos)
    di(any("NCU8" in a and "en la tabla y aqui no [49]" in a for a in avisos),
       "y el que aqui falta", avisos)
    di([e.get("ip_gw") for e in ent] == ["10.21.236.42", "10.21.236.37", "10.21.236.38"],
       "y aun asi mete las IPs de gateway", [e.get("ip_gw") for e in ent])

print("\n· se le puede dar el .zip tal cual sale del navegador")
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    dirp = tmp / "plantas"
    dirp.mkdir()
    escribe(dirp / "24030-bagnarelli.json", [pl("Bagnarelli NCU1", "192.168.5.21", 503, 1, 17)])
    z = tmp / "IPs.zip"
    with zipfile.ZipFile(z, "w") as f:
        f.writestr("24030-bagnarelli.json", json.dumps({"version": 1, "plantas": [
            pl("Bagnarelli NCU1", "192.168.5.21", 503, 1, 17, ip_gw="192.168.5.22")]}))
    escritos, avisos = modo_tarjeta([z], dirp)
    di(carga(dirp / "24030-bagnarelli.json")[0].get("ip_gw") == "192.168.5.22",
       "del zip a plantas/ sin descomprimir nada a mano")

print("\n%d comprobaciones, %d fallos" % (n, len(fallos)))
sys.exit(1 if fallos else 0)
