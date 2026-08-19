#!/usr/bin/env python3
"""Medidor de tráfico (estimación): qué gasta cada planta en la LAN y en la nube.

Aplica el modelo de bytes de `collector/traffic.py` sobre la configuración, sin
tocar hierro. Sirve para dimensionar el enlace ANTES de instalar: cuánto sube
cada planta al día/mes, y qué pasa si se cambia el ritmo de polling.

    python tools/trafico.py                    # planta configurada + flota
    python tools/trafico.py --intervalo 10,30,60,300   # sensibilidad al ritmo
    python tools/trafico.py --zigbee           # + modelo de la malla NCU<->TCU
    python tools/trafico.py --json             # para tragarlo desde otro script

La flota sale de `tools/tcu-toolbox/plantas/*.json` (generados de plants.yml y
de los .bat de Sunner), que es el único inventario con el nº de TCU de todas
las plantas. La planta que el stack tiene configurada sale de
`config/plants.yml`, con su intervalo y sus HSU reales.
"""
import argparse
import glob
import json
import os
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(RAIZ, "collector"))

from traffic import ncu_estimate, plant_estimate, zigbee_estimate  # noqa: E402


def cargar_plants_yml(ruta):
    try:
        import yaml
    except ImportError:
        print("(sin PyYAML: me salto config/plants.yml)", file=sys.stderr)
        return None
    if not os.path.exists(ruta):
        return None
    with open(ruta, encoding="utf-8") as f:
        return yaml.safe_load(f)


def cargar_flota(dir_plantas):
    """Inventario de plantas de la toolbox -> [{nombre, ncus:[{id,tcu_count,hsu_count}]}].

    Un gateway NO es una NCU: la NCU es la IP. Se agrupa por IP porque el
    tráfico Modbus es una conexión por NCU, no por gateway.
    """
    flota = []
    for ruta in sorted(glob.glob(os.path.join(dir_plantas, "*.json"))):
        with open(ruta, encoding="utf-8") as f:
            d = json.load(f)
        por_ip = {}
        for gw in d.get("plantas", []):
            ip = gw.get("ip", "?")
            n = max(0, int(gw.get("tcu_fin", 0)) - int(gw.get("tcu_ini", 0)) + 1)
            e = por_ip.setdefault(ip, {"id": ip, "tcu_count": 0, "hsu_count": 0,
                                       "puertos": set()})
            e["tcu_count"] += n
            e["hsu_count"] += int(gw.get("hsus", 0))
            # gateway = puerto del passthrough, no fila: una NCU puede declarar
            # dos rangos en el mismo gateway (un TCU suelto, p.ej.).
            e["puertos"].add(gw.get("puerto"))
        for e in por_ip.values():
            e["gws"] = len(e.pop("puertos"))
        if por_ip:
            flota.append({"planta": os.path.basename(ruta).replace(".json", ""),
                          "ncus": list(por_ip.values())})
    return flota


def fila(nombre, est):
    return (f"{nombre:<22} {est['ncus']:>4} {est['tcus']:>6} "
            f"{est['lan_mb_day']:>10.1f} {est['cloud_raw_mb_day']:>10.1f} "
            f"{est['cloud_mb_day']:>10.1f} {est['cloud_gb_month']:>9.2f}")


CAB = (f"{'planta':<22} {'NCU':>4} {'TCU':>6} {'LAN MB/d':>10} "
       f"{'crudo MB/d':>10} {'nube MB/d':>10} {'nube GB/m':>9}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--intervalo", default=None,
                    help="segundos de polling; lista separada por comas para comparar")
    ap.add_argument("--zigbee", action="store_true",
                    help="añade el modelo de la malla Zigbee NCU<->TCU")
    ap.add_argument("--zigbee-ciclo", type=float, default=60,
                    help="periodo con el que la NCU refresca cada TCU (s, por defecto 60)")
    ap.add_argument("--json", action="store_true", help="salida en JSON")
    a = ap.parse_args()

    cfg = cargar_plants_yml(os.path.join(RAIZ, "config", "plants.yml"))
    base_int = float(cfg["polling"]["interval_s"]) if cfg else 30.0
    intervalos = [float(x) for x in a.intervalo.split(",")] if a.intervalo else [base_int]

    salida = {"intervalos_s": intervalos, "configurada": None, "flota": [], "zigbee": []}
    flota = cargar_flota(os.path.join(RAIZ, "tools", "tcu-toolbox", "plantas"))

    if cfg:
        salida["configurada"] = {
            "planta": cfg["plant"]["name"],
            "por_intervalo": {i: plant_estimate(cfg["ncus"], interval_s=i) for i in intervalos},
        }
    for p in flota:
        salida["flota"].append({
            "planta": p["planta"],
            "por_intervalo": {i: plant_estimate(p["ncus"], interval_s=i) for i in intervalos},
        })
    if a.zigbee:
        for p in flota:
            for n in p["ncus"]:
                # cada gateway es una malla propia: el aire se ocupa por malla,
                # el volumen se suma en la NCU.
                gws = max(1, n.get("gws", 1))
                z = zigbee_estimate(round(n["tcu_count"] / gws), cycle_s=a.zigbee_ciclo)
                salida["zigbee"].append({"planta": p["planta"], "ncu": n["id"],
                                         "gateways": gws, "tcus_ncu": n["tcu_count"],
                                         "mb_day_ncu": z["mb_day"] * gws} | z)

    if a.json:
        print(json.dumps(salida, indent=2, ensure_ascii=False))
        return

    for i in intervalos:
        print(f"\n=== Polling cada {i:g} s "
              f"({86400 / i:,.0f} ciclos/día por NCU) ===".replace(",", "."))
        print(CAB)
        print("-" * len(CAB))
        if salida["configurada"]:
            c = salida["configurada"]
            print(fila(c["planta"] + " *", c["por_intervalo"][i]))
        for p in salida["flota"]:
            print(fila(p["planta"], p["por_intervalo"][i]))
        tot_nube = sum(p["por_intervalo"][i]["cloud_mb_day"] for p in salida["flota"])
        tot_tcu = sum(p["por_intervalo"][i]["tcus"] for p in salida["flota"])
        print("-" * len(CAB))
        print(f"{'FLOTA (inventario toolbox)':<22} {'':>4} {tot_tcu:>6} {'':>10} {'':>10} "
              f"{tot_nube:>10.1f} {tot_nube * 30 / 1000:>9.2f}")

    print("\n* planta configurada en config/plants.yml (intervalo y HSU reales). "
          "El Burgo sale dos veces a propósito: la fila * y la del inventario, "
          "que no siempre coinciden.")
    print("LAN = Modbus TCP colector<->NCU (ida+vuelta, cabeceras IP incluidas).")
    print("nube = line protocol comprimido + cabeceras HTTP/TLS; crudo = sin comprimir.")

    if a.zigbee:
        print(f"\n=== Malla Zigbee (modelo, refresco cada {a.zigbee_ciclo:g} s) ===")
        print(f"{'planta':<22} {'NCU':<14} {'GW':>3} {'TCU':>6} {'TCU/GW':>7} "
              f"{'MB/día':>8} {'aire %/GW':>10}")
        for z in salida["zigbee"]:
            aviso = "  <-- apretado" if z["airtime_pct"] > 30 else ""
            print(f"{z['planta']:<22} {str(z['ncu']):<14} {z['gateways']:>3} "
                  f"{z['tcus_ncu']:>6} {z['tcus']:>7} {z['mb_day_ncu']:>8.1f} "
                  f"{z['airtime_pct']:>10.1f}{aviso}")
        print("aire % = ocupación del canal de UNA malla (un gateway). Si dos gateways "
              "de la misma NCU comparten canal, súmalos.")
        print("MODELO, no medida: la NCU no expone contadores de radio. "
              "Parámetros en collector/traffic.py (ZB_*), a validar en campo.")


if __name__ == "__main__":
    main()
