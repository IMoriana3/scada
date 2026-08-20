#!/usr/bin/env python3
"""Calibra el modelo de la malla con la captura REAL de El Burgo.

El modelo de `collector/traffic.py` tenía dos parámetros a ojo: los saltos
medios al coordinador y el factor de reintentos. El primero **ya no hace falta
suponerlo**: `cobertura-zigbee/elburgo_real.geojson` es la malla medida de la
NCU1-GW2 (coordinador + 52 TCU) y trae `hop_tipico` por nodo, sacado de las
capturas de `xbee source_route`.

    python tools/calibrar_zigbee.py
    python tools/calibrar_zigbee.py --fuente /ruta/elburgo_real.geojson

El segundo parámetro, el factor de reintentos, sale del `zigbee_log.csv` crudo
del recolector (`--log`), que guarda el contador `ack_failures` de cada radio
RONDA A RONDA: la diferencia entre rondas consecutivas son los fallos de ese
intervalo. Los contadores del geojson no valen para esto — son acumulados de
por vida, hasta 4,5 millones por nodo.

    python tools/calibrar_zigbee.py --log zigbee_log.csv
    python tools/calibrar_zigbee.py --log zigbee_log.csv --write   # deja la evidencia

`--write` guarda `config/malla_medida.json` (unos pocos kB) con lo derivado y su
procedencia, para que la calibración sea auditable sin arrastrar los 16 MB del
CSV. El banco comprueba que los números del modelo son los de ese fichero.
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


def fallos_ack(ruta_csv):
    """Fallos de ACK por hora y nodo, de las diferencias entre rondas.

    Un contador que baja es un reinicio de la radio, no un fallo negativo: ese
    salto se descarta. Los huecos de más de una hora tampoco se cuentan (el
    recolector estuvo parado, no es tiempo medido).
    """
    import csv
    from datetime import datetime

    por = collections.defaultdict(list)
    with open(ruta_csv, encoding="utf-8-sig") as f:
        for r in csv.DictReader(f):
            if r.get("role") != "TCU" or r.get("online") != "1" or not r.get("ack_failures"):
                continue
            por[r["node_id"]].append(
                (datetime.fromisoformat(r["timestamp"]), int(r["ack_failures"]),
                 r.get("gateway", "?")))
    nodos, tot_f, tot_s, reinicios = {}, 0, 0.0, 0
    gws = set()
    for nid, v in por.items():
        v.sort()
        gws.add(v[0][2])
        fallos = segundos = 0.0
        for (t0, a0, _), (t1, a1, _) in zip(v, v[1:]):
            dt = (t1 - t0).total_seconds()
            if not (0 < dt <= 3600):
                continue
            if a1 < a0:
                reinicios += 1
                continue
            fallos += a1 - a0
            segundos += dt
        if segundos > 0:
            nodos[nid] = round(3600 * fallos / segundos, 3)
            tot_f += fallos
            tot_s += segundos
    v = sorted(nodos.values())
    return {
        "gateways": sorted(gws),
        "nodos": len(nodos),
        "horas_nodo": round(tot_s / 3600, 1),
        "fallos_totales": int(tot_f),
        "reinicios_de_contador": reinicios,
        "fallos_h_media": round(statistics.mean(v), 3) if v else None,
        "fallos_h_mediana": round(statistics.median(v), 3) if v else None,
        "fallos_h_p90": v[int(0.9 * len(v))] if v else None,
        "fallos_h_max": max(v) if v else None,
        "por_nodo": dict(sorted(nodos.items())),
    }


def factor_reintentos(fallos_h: float, cycle_s: float) -> float:
    """Reintentos por trama, al ritmo de sondeo que se esté modelando.

    Un nodo manda 2 tramas por sondeo (petición y respuesta), así que a un
    sondeo cada `cycle_s` le corresponden 7200/cycle_s tramas por hora. Los
    fallos medidos son por hora, no por trama: cuanto MÁS lento sondea la NCU,
    más pesa cada fallo. Por eso el factor depende de la cadencia y no es una
    constante del sitio.
    """
    tramas_h = 7200.0 / cycle_s
    return 1 + fallos_h / tramas_h


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
    ap.add_argument("--log", default=None, help="zigbee_log.csv crudo del recolector")
    ap.add_argument("--write", action="store_true",
                    help="guarda config/malla_medida.json con lo derivado")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    ruta = a.fuente or next((c for c in CANDIDATAS if c and os.path.exists(c)), None)
    if not ruta:
        print("No encuentro la malla medida (elburgo_real.geojson).")
        print("Está en el repo cobertura-zigbee. Clónalo al lado de este o pásalo con --fuente.")
        return 0

    r = calibrar(cargar(ruta))
    r["fuente_saltos"] = os.path.basename(ruta)
    if a.log:
        r["ack"] = fallos_ack(a.log)
        r["ack"]["fuente"] = os.path.basename(a.log)
    if a.write:
        destino = os.path.join(RAIZ, "config", "malla_medida.json")
        with open(destino, "w", encoding="utf-8") as f:
            json.dump(r, f, indent=1, ensure_ascii=False)
            f.write("\n")
        print(f"Escrito {os.path.relpath(destino, RAIZ)}")
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

    ack = r.get("ack")
    if not ack:
        print("\nEl factor de reintentos necesita el zigbee_log.csv crudo: pásalo con --log.")
        return 0
    print(f"\nFALLOS DE ACK — {', '.join(ack['gateways'])} · {ack['nodos']} TCU · "
          f"{ack['horas_nodo']:.0f} nodo·hora · {ack['fallos_totales']} fallos")
    print(f"  por nodo y hora: media {ack['fallos_h_media']} · mediana {ack['fallos_h_mediana']} "
          f"· p90 {ack['fallos_h_p90']} · máx {ack['fallos_h_max']}")
    print(f"  ({ack['reinicios_de_contador']} reinicios de contador descartados)")
    print("\nFACTOR DE REINTENTOS que implican, según cada cuánto sondee la NCU:")
    for T in (30, 60, 300, 900):
        print(f"  cada {T:4} s -> {factor_reintentos(ack['fallos_h_media'], T):.4f}"
              f"   (peor nodo {factor_reintentos(ack['fallos_h_max'], T):.4f})")
    print("\nEl modelo suponía 1,15 — o sea un 15 % de tramas repetidas. La malla real")
    print("apenas falla: al ritmo de 60 s el recargo medido es del 0,2 %.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
