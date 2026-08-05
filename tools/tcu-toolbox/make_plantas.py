#!/usr/bin/env python3
"""Genera plantas.json para TCU Toolbox a partir del config del SCADA.

Lee ``config/plants.yml`` (el mismo fichero que usa el collector) y emite un
``plantas.json`` con una entrada por NCU y puerto de gateway. La toolbox habla
con los TCU a traves del passthrough Modbus de la NCU (unit id = numero de
TCU), que en El Burgo escucha en los puertos 503/504 (uno por gateway Zigbee);
por eso se generan entradas por puerto y no una sola por NCU.

Fuente de verdad de los gateways: la clave opcional ``gateways`` de cada NCU
en plants.yml (el collector la ignora)::

    gateways:
      - { puerto: 503, tcu_ini: 1,  tcu_fin: 56 }
      - { puerto: 504, tcu_ini: 57, tcu_fin: 108 }

Con ``gateways`` declarado, el fichero generado no necesita retoques y puede
regenerarse automaticamente (hay un workflow de GitHub Actions que lo hace en
cada cambio de plants.yml). Si una NCU no lo declara, se cae al modo antiguo:
una entrada por puerto de --puertos con rango 1..tcu_count, a ajustar a mano.

Uso (desde tools/tcu-toolbox/):

    python make_plantas.py                          # usa ../../config/plants.yml
    python make_plantas.py --plants otra/plants.yml
    python make_plantas.py --puertos 503 504        # fallback si no hay gateways
    python make_plantas.py --salida plantas.json

Solo necesita PyYAML (ya esta en requirements del collector).
"""

import argparse
import json
import re
import sys
import unicodedata
from pathlib import Path


def parse_rango(texto):
    """'1-56' -> (1, 56); '109' -> (109, 109); '-'/vacio -> None."""
    t = str(texto or "").strip()
    m = re.match(r"^(\d+)\s*-\s*(\d+)$", t)
    if m:
        return int(m.group(1)), int(m.group(2))
    if re.match(r"^\d+$", t):
        return int(t), int(t)
    return None


def slug(texto):
    t = unicodedata.normalize("NFKD", str(texto)).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "-", t.lower()).strip("-") or "planta"


def modo_excel(ruta, hoja, puertos, excluir, comentario_extra):
    """Lee la hoja 'Direcciones IP' del Excel maestro y devuelve
    {(num, proyecto): [entradas plantas.json]}. Solo usa IP NCU y los rangos
    de esclavos por gateway: las columnas de credenciales NI SE LEEN."""
    try:
        from openpyxl import load_workbook
    except ImportError:
        sys.exit("Falta openpyxl: pip install openpyxl")
    wb = load_workbook(ruta, data_only=True)
    if hoja not in wb.sheetnames:
        sys.exit(f"El Excel no tiene la hoja '{hoja}' (tiene: {wb.sheetnames})")
    filas = list(wb[hoja].iter_rows(values_only=True))
    head = [str(c).strip() if c is not None else "" for c in filas[0]]

    def col(nombre, desde=0):
        try:
            return head.index(nombre, desde)
        except ValueError:
            sys.exit(f"La hoja '{hoja}' no tiene la columna '{nombre}'")

    i_num, i_proy, i_ncu = col("Nº"), col("Proyecto"), col("NCU")
    i_ip = col("IP NCU")
    i_esc1 = col("Esclavos")
    i_esc2 = col("Esclavos", col("IP GW 2"))   # segundo 'Esclavos', tras IP GW 2

    plantas = {}
    actual = None
    ncu_auto = 0
    for fila in filas[2:]:
        def v(i):
            return str(fila[i]).strip() if (i < len(fila) and fila[i] is not None) else ""
        num, proy = v(i_num), v(i_proy)
        if num and proy:
            num = re.sub(r"\.0$", "", num)
            actual = (num, proy)
            ncu_auto = 0
            plantas.setdefault(actual, [])
        if not actual:
            continue
        ip = v(i_ip)
        if not re.match(r"^\d+\.\d+\.\d+\.\d+$", ip):
            continue
        ncu_auto += 1
        ntxt = re.sub(r"\.0$", "", v(i_ncu))
        n = int(ntxt) if re.match(r"^\d+$", ntxt) else ncu_auto
        rangos = [parse_rango(v(i_esc1)), parse_rango(v(i_esc2))]
        gws = [(puertos[k], r) for k, r in enumerate(rangos) if r and k < len(puertos)]
        if not gws:
            continue
        for gidx, (puerto, (ini, fin)) in enumerate(gws, start=1):
            sufijo = f" GW{gidx}" if len(gws) > 1 else ""
            plantas[actual].append({
                "nombre": f"{proy} NCU{n}{sufijo}",
                "ip": ip,
                "puerto": puerto,
                "tcu_ini": ini,
                "tcu_fin": fin,
            })

    ficheros = []
    for (num, proy), entradas in sorted(plantas.items()):
        if not entradas or num in excluir:
            continue
        destino = Path("plantas") / f"{num}-{slug(proy)}.json"
        destino.parent.mkdir(parents=True, exist_ok=True)
        destino.write_text(json.dumps({
            "_comentario": (f"Planta {num} ({proy}) generada desde el Excel maestro "
                            f"(hoja '{hoja}') por make_plantas.py --excel. Solo topologia: "
                            "sin credenciales. NO subir el Excel al repo." + comentario_extra),
            "version": 1,
            "plantas": entradas,
        }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        ficheros.append((destino, len(entradas)))
        print(f"{destino}: {len(entradas)} entradas ({proy})")
    if not ficheros:
        sys.exit("El Excel no produjo ninguna planta (revisa la hoja y las columnas)")
    return ficheros


try:
    import yaml
except ImportError:
    yaml = None


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--plants", default="../../config/plants.yml",
                    help="ruta a plants.yml del SCADA (defecto: ../../config/plants.yml)")
    ap.add_argument("--excel", default=None,
                    help="modo Excel maestro: ruta al .xlsx con la hoja 'Direcciones IP'; "
                         "genera plantas/<num>-<planta>.json por cada planta (sin credenciales)")
    ap.add_argument("--hoja", default="Direcciones IP", help="hoja del Excel (defecto: Direcciones IP)")
    ap.add_argument("--excluir", nargs="*", default=[],
                    help="numeros de proyecto a saltar en modo Excel (p.ej. --excluir 23003)")
    ap.add_argument("--puertos", nargs="+", type=int, default=[503, 504],
                    help="puertos passthrough de la NCU, uno por gateway (defecto: 503 504)")
    ap.add_argument("--salida", default=None,
                    help="fichero de salida (defecto: plantas/<plant_id>.json, un JSON por planta)")
    args = ap.parse_args()

    if args.excel:
        modo_excel(Path(args.excel), args.hoja, args.puertos, set(args.excluir), "")
        return

    if yaml is None:
        sys.exit("Falta PyYAML: pip install pyyaml")
    ruta = Path(args.plants)
    if not ruta.exists():
        sys.exit(f"No existe {ruta} (ejecuta desde tools/tcu-toolbox/ o pasa --plants)")

    cfg = yaml.safe_load(ruta.read_text(encoding="utf-8"))
    nombre_planta = (cfg.get("plant") or {}).get("name") or (cfg.get("plant") or {}).get("id") or "Planta"
    ncus = cfg.get("ncus") or []
    if not ncus:
        sys.exit("plants.yml no tiene NCUs")

    plantas = []
    a_mano = False
    for ncu in ncus:
        host = ncu.get("host")
        if not host:
            continue
        gws = ncu.get("gateways") or []
        if gws:
            # mismo puerto = mismo gateway fisico; una fila extra del mismo
            # puerto (p.ej. TCU suelta 109) se distingue por su rango
            indice_gw = {}
            vistos = {}
            for gw in gws:
                puerto = int(gw["puerto"])
                if puerto not in indice_gw:
                    indice_gw[puerto] = len(indice_gw) + 1
                ini = int(gw.get("tcu_ini", 1))
                fin = int(gw.get("tcu_fin", ncu.get("tcu_count") or 1))
                sufijo = f" GW{indice_gw[puerto]}" if len(gws) > 1 else ""
                if puerto in vistos:
                    sufijo += f" (TCU {ini}-{fin})"
                vistos[puerto] = True
                plantas.append({
                    "nombre": gw.get("nombre") or f"{nombre_planta} {ncu.get('id', host)}{sufijo}",
                    "ip": host,
                    "puerto": puerto,
                    "tcu_ini": ini,
                    "tcu_fin": fin,
                })
        else:
            # fallback sin gateways declarados: rangos 1..tcu_count a ajustar a mano
            a_mano = True
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

    comentario = f"Generado desde {ruta.name} por make_plantas.py. NO editar a mano: declara los gateways en plants.yml y regenera."
    if a_mano:
        comentario = (f"Generado desde {ruta.name} por make_plantas.py. Hay NCUs sin 'gateways' en plants.yml: "
                      "ajusta sus rangos tcu_ini/tcu_fin a mano o, mejor, declaralos en plants.yml y regenera.")
    salida = {
        "_comentario": comentario,
        "version": 1,
        "plantas": plantas,
    }
    if args.salida:
        destino = Path(args.salida)
    else:
        pid = (cfg.get("plant") or {}).get("id") or "planta"
        destino = Path("plantas") / f"{pid}.json"
    destino.parent.mkdir(parents=True, exist_ok=True)
    destino.write_text(json.dumps(salida, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{destino}: {len(plantas)} entradas ({len(ncus)} NCUs)")


if __name__ == "__main__":
    main()
