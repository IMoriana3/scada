#!/usr/bin/env python3
"""Genera plantas.json para TCU Toolbox a partir del config del SCADA.

Lee ``config/plants.yml`` (el mismo fichero que usa el collector) y emite un
``plantas.json`` con una entrada por NCU y puerto de gateway. La toolbox habla
con los TCU a traves del passthrough Modbus de la NCU (unit id = numero de
TCU), que en El Burgo escucha en los puertos 503/504 (uno por gateway Zigbee);
por eso se generan entradas por puerto y no una sola por NCU.

Uso (desde tools/tcu-toolbox/):

    python make_plantas.py                          # usa ../../config/plants.yml
    python make_plantas.py --plants otra/plants.yml
    python make_plantas.py --puertos 503 504        # puertos passthrough por NCU
    python make_plantas.py --salida plantas.json

Los rangos de TCU se rellenan con 1..tcu_count de cada NCU; si en tu planta
cada gateway atiende un subrango (p. ej. GW1 1-56, GW2 57-108), ajusta los
valores a mano despues de generar: el fichero es JSON normal y la toolbox lo
relee al arrancar.

Solo necesita PyYAML (ya esta en requirements del collector).
"""

import argparse
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("Falta PyYAML: pip install pyyaml")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--plants", default="../../config/plants.yml",
                    help="ruta a plants.yml del SCADA (defecto: ../../config/plants.yml)")
    ap.add_argument("--puertos", nargs="+", type=int, default=[503, 504],
                    help="puertos passthrough de la NCU, uno por gateway (defecto: 503 504)")
    ap.add_argument("--salida", default="plantas.json", help="fichero de salida")
    args = ap.parse_args()

    ruta = Path(args.plants)
    if not ruta.exists():
        sys.exit(f"No existe {ruta} (ejecuta desde tools/tcu-toolbox/ o pasa --plants)")

    cfg = yaml.safe_load(ruta.read_text(encoding="utf-8"))
    nombre_planta = (cfg.get("plant") or {}).get("name") or (cfg.get("plant") or {}).get("id") or "Planta"
    ncus = cfg.get("ncus") or []
    if not ncus:
        sys.exit("plants.yml no tiene NCUs")

    plantas = []
    for ncu in ncus:
        host = ncu.get("host")
        if not host:
            continue
        tcus = int(ncu.get("tcu_count") or 0) or 1
        for i, puerto in enumerate(args.puertos, start=1):
            sufijo = f" GW{i}" if len(args.puertos) > 1 else ""
            plantas.append({
                "nombre": f"{nombre_planta} {ncu.get('id', host)}{sufijo}",
                "ip": host,
                "puerto": puerto,
                "tcu_ini": 1,
                "tcu_fin": tcus,
            })

    salida = {
        "_comentario": (f"Generado desde {ruta} por make_plantas.py. Ajusta los rangos "
                        "tcu_ini/tcu_fin por gateway si cada GW atiende un subrango."),
        "version": 1,
        "plantas": plantas,
    }
    Path(args.salida).write_text(json.dumps(salida, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{args.salida}: {len(plantas)} entradas ({len(ncus)} NCUs x {len(args.puertos)} puertos)")


if __name__ == "__main__":
    main()
