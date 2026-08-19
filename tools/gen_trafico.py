#!/usr/bin/env python3
"""Genera el bloque de datos de `trafico.html` con el modelo de collector/traffic.py.

La página no reimplementa el modelo: se le hornean aquí los bytes por ciclo de
cada NCU real (calculados con el mismo código que usa el colector) y una curva
de tamaño comprimido para la calculadora de plantas nuevas. Así el visor y el
medidor no pueden desviarse: si cambia el modelo, se regenera y punto.

  python tools/gen_trafico.py            # dry-run: enseña lo que saldría
  python tools/gen_trafico.py --write    # escribe trafico.html entre los marcadores

Fuentes:
  config/plants.yml   -> la planta que el stack tiene configurada (intervalo y HSU reales)
  index.html          -> el resto de la flota: el plano del SCADA dice qué TCU cuelga de qué NCU
"""
import json
import os
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(RAIZ, "collector"))
sys.path.insert(0, os.path.join(RAIZ, "tools"))

from traffic import PRESETS, cloud_cycle, modbus_cycle  # noqa: E402
from trafico import cargar_flota, cargar_plants_yml, normaliza  # noqa: E402

INI = "/* === DATOS GENERADOS por tools/gen_trafico.py — no editar a mano === */"
FIN = "/* === FIN DATOS GENERADOS === */"

# Puntos de la curva de bytes de nube por ciclo (crudo y comprimido) según nº de
# TCU. La página interpola entre ellos para la calculadora de plantas nuevas; el
# banco comprueba que el error se queda por debajo del 2 % en todo el rango.
CURVA_N = [1, 2, 5, 10, 20, 35, 50, 75, 100, 150, 200, 300, 400, 600, 800,
           1200, 1700, 2400]

def por_ncu(ncu_id, n_tcu, n_hsu, plant="planta"):
    lan = modbus_cycle(n_tcu, n_hsu)
    nube = cloud_cycle(n_tcu, n_hsu, plant=plant, ncu=ncu_id)
    # Bytes de UNA subida para cada plan (qué campos) y modo (último valor o
    # media/mín/máx). El gzip no se puede rehacer en el navegador, así que la
    # página consume estos números en vez de reimplementar el modelo.
    planes = {}
    for nombre, campos in PRESETS.items():
        planes[nombre] = [
            cloud_cycle(n_tcu, n_hsu, plant=plant, ncu=ncu_id, campos=campos,
                        agregado=agr)["cloud_gz_b"]
            for agr in (False, True)
        ]
    return {
        "id": ncu_id, "tcu": n_tcu, "hsu": n_hsu,
        "tx": lan["modbus_tx"], "lan": lan["lan_b"],
        "crudo": nube["cloud_raw_b"], "gz": nube["cloud_gz_b"],
        "planes": planes,
    }


def construir():
    plantas = []
    cfg = cargar_plants_yml(os.path.join(RAIZ, "config", "plants.yml"))
    nombre_cfg = ""
    if cfg:
        pid = cfg["plant"]["id"]
        nombre_cfg = normaliza(cfg["plant"]["name"])
        plantas.append({
            "planta": cfg["plant"]["name"],
            "configurada": True,
            "intervalo": float(cfg["polling"]["interval_s"]),
            "ncus": [por_ncu(str(n["id"]), int(n["tcu_count"]), int(n.get("hsu_count", 0)), pid)
                     | {"gws": len(n.get("gateways", [])) or 1} for n in cfg["ncus"]],
        })
    for p in cargar_flota():
        # La planta configurada ya va arriba con sus datos buenos (intervalo y
        # HSU reales); no se repite desde el inventario.
        if nombre_cfg and normaliza(p["planta"]).startswith(nombre_cfg):
            continue
        plantas.append({
            "planta": p["planta"],
            "configurada": False,
            "intervalo": None,
            "ncus": [por_ncu(n["id"], n["tcu_count"], n["hsu_count"])
                     | {"gws": n.get("gws", 1)} for n in p["ncus"]],
        })
    curva = []
    for n in CURVA_N:
        fila = [n, cloud_cycle(n, 1)["cloud_raw_b"]]
        for campos in PRESETS.values():          # todo, operacion, minimo
            for agr in (False, True):            # último valor / media-mín-máx
                fila.append(cloud_cycle(n, 1, campos=campos, agregado=agr)["cloud_gz_b"])
        curva.append(fila)
    return {"plantas": plantas, "curvaNube": curva}


def bloque(datos):
    lineas = [INI, "const DATOS = {", '  plantas: [']
    for p in datos["plantas"]:
        ncus = ", ".join(
            "{{id:{}, tcu:{}, hsu:{}, gws:{}, tx:{}, lan:{}, crudo:{}, gz:{}, planes:{}}}".format(
                json.dumps(n["id"], ensure_ascii=False), n["tcu"], n["hsu"], n["gws"],
                n["tx"], n["lan"], n["crudo"], n["gz"],
                "{" + ",".join(f"{k}:[{v[0]},{v[1]}]" for k, v in n["planes"].items()) + "}")
            for n in p["ncus"])
        lineas.append("    {{planta:{}, configurada:{}, intervalo:{}, ncus:[{}]}},".format(
            json.dumps(p["planta"], ensure_ascii=False),
            "true" if p["configurada"] else "false",
            p["intervalo"] if p["intervalo"] else "null", ncus))
    lineas.append("  ],")
    lineas.append("  // [nº TCU, crudos, gz de cada plan × modo: todo/operacion/minimo ×\n"
                  "  //  último valor/media-mín-máx] por subida, con 1 HSU\n"
                  "  curvaNube: [" +
                  ", ".join("[" + ",".join(str(x) for x in f) + "]"
                            for f in datos["curvaNube"]) + "],")
    lineas.append("};")
    lineas.append(FIN)
    return "\n".join(lineas)


def main():
    datos = construir()
    txt = bloque(datos)
    destino = os.path.join(RAIZ, "trafico.html")
    if "--write" not in sys.argv:
        print(txt)
        print(f"\n(dry-run: {len(datos['plantas'])} plantas, "
              f"{sum(len(p['ncus']) for p in datos['plantas'])} NCU, "
              f"{sum(n['tcu'] for p in datos['plantas'] for n in p['ncus'])} TCU. "
              f"Con --write se escribe en trafico.html)")
        return
    with open(destino, encoding="utf-8") as f:
        html = f.read()
    i, j = html.find(INI), html.find(FIN)
    if i < 0 or j < 0:
        sys.exit("No encuentro los marcadores en trafico.html")
    nuevo = html[:i] + txt + html[j + len(FIN):]
    if nuevo == html:
        print("trafico.html ya estaba al día")
        return
    with open(destino, "w", encoding="utf-8") as f:
        f.write(nuevo)
    print(f"trafico.html actualizado: {len(datos['plantas'])} plantas, "
          f"{sum(n['tcu'] for p in datos['plantas'] for n in p['ncus'])} TCU")


if __name__ == "__main__":
    main()
