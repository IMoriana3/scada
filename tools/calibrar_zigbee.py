#!/usr/bin/env python3
"""Calibra el modelo de la malla con la captura REAL de El Burgo.

El modelo de `collector/traffic.py` tenía dos parámetros a ojo: los saltos
medios al coordinador y el factor de reintentos. El primero **ya no hace falta
suponerlo**: `cobertura-zigbee/elburgo_real.geojson` es la malla medida de la
NCU1-GW2 (coordinador + 52 TCU) y trae `hop_tipico` por nodo, sacado de las
capturas de `xbee source_route`.

    python tools/calibrar_zigbee.py
    python tools/calibrar_zigbee.py --fuente /ruta/elburgo_real.geojson

Lo que este banco NO puede calibrar es el factor de reintentos: el fichero trae
`ack_failures` por nodo, pero son los contadores ACUMULADOS de la radio (hasta
4,5 millones), no fallos por ronda. Para convertirlos en un factor hace falta el
`zigbee_log.csv` crudo del recolector, que sí guarda el contador ronda a ronda:
la diferencia entre rondas es lo que se busca. El agregado horario que hay
publicado ya no lo lleva.
"""
import argparse
import collections
import json
import os
import statistics
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CANDIDATAS = [
    os.environ.get("MALLA_MEDIDA", ""),
    os.path.join(RAIZ, "..", "cobertura-zigbee", "elburgo_real.geojson"),
    os.path.expanduser("~/cobertura-zigbee/elburgo_real.geojson"),
]


def cargar(ruta):
    with open(ruta, encoding="utf-8") as f:
        d = json.load(f)
    return [x["properties"] for x in d["features"] if x["geometry"]["type"] == "Point"]


def calibrar(nodos):
    """Estadísticos de salto por gateway, y el número que usa el modelo."""
    tcu = [n for n in nodos if n.get("role") == "TCU"]
    por_gw = collections.defaultdict(list)
    for n in tcu:
        if n.get("hop_tipico"):
            por_gw[n.get("gw") or "?"].append(int(n["hop_tipico"]))
    todos = [h for v in por_gw.values() for h in v]
    return {
        "nodos": len(tcu),
        "con_salto": len(todos),
        "gateways": {gw: {
            "nodos": len(v),
            "media": round(statistics.mean(v), 2),
            "mediana": statistics.median(v),
            "min": min(v), "max": max(v),
            "distribucion": dict(sorted(collections.Counter(v).items())),
        } for gw, v in sorted(por_gw.items())},
        "saltos_medios": round(statistics.mean(todos), 2) if todos else None,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fuente", default=None, help="elburgo_real.geojson (malla medida)")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    ruta = a.fuente or next((c for c in CANDIDATAS if c and os.path.exists(c)), None)
    if not ruta:
        print("No encuentro la malla medida (elburgo_real.geojson).")
        print("Está en el repo cobertura-zigbee. Clónalo al lado de este o pásalo con --fuente.")
        return 0

    r = calibrar(cargar(ruta))
    if a.json:
        print(json.dumps(r, indent=2, ensure_ascii=False))
        return 0

    print(f"Fuente: {os.path.relpath(ruta, RAIZ)}")
    print(f"{r['nodos']} TCU medidos, {r['con_salto']} con salto conocido\n")
    for gw, v in r["gateways"].items():
        print(f"{gw}: {v['nodos']} TCU · media {v['media']} saltos · mediana {v['mediana']} "
              f"· rango {v['min']}–{v['max']}")
        ancho = max(v["distribucion"].values())
        for salto, n in v["distribucion"].items():
            print(f"   {salto} saltos {'█' * max(1, round(24 * n / ancho)):<24} {n}")
    print(f"\nSALTOS MEDIOS MEDIDOS: {r['saltos_medios']}")
    print("El modelo suponía 2,0. La ocupación de aire es proporcional a los saltos,")
    print("así que con esto se duplica: cada salto es una retransmisión que ocupa el canal.")
    print("\nEl factor de reintentos sigue sin calibrar: los `ack_failures` del fichero son")
    print("contadores acumulados de la radio, no fallos por ronda. Hace falta el")
    print("zigbee_log.csv crudo (contador ronda a ronda) para sacar la diferencia.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
