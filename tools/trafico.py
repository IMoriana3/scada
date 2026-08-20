#!/usr/bin/env python3
"""Medidor de tráfico (estimación): qué gasta cada planta en la LAN y en la nube.

Aplica el modelo de bytes de `collector/traffic.py` sobre la configuración, sin
tocar hierro. Sirve para dimensionar el enlace ANTES de instalar: cuánto sube
cada planta al día/mes, y qué pasa si se cambia el ritmo de polling.

    python tools/trafico.py                    # planta configurada + flota
    python tools/trafico.py --intervalo 10,30,60,300   # sensibilidad al ritmo
    python tools/trafico.py --zigbee           # + modelo de la malla NCU<->TCU
    python tools/trafico.py --json             # para tragarlo desde otro script

La flota sale del plano del propio SCADA (`index.html`), donde cada TCU declara
su NCU y su gateway. La planta que el stack tiene configurada sale de
`config/plants.yml`, con su intervalo y sus HSU reales.
"""
import argparse
import glob
import json
import os
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(RAIZ, "collector"))

from traffic import (PRESETS, ZB_SALTOS, cloud_plan, field_weights,  # noqa: E402
                     map_params, ncu_estimate, plant_estimate, zigbee_estimate)


def cargar_yaml(ruta):
    try:
        import yaml
    except ImportError:
        return None
    if not os.path.exists(ruta):
        return None
    with open(ruta, encoding="utf-8") as f:
        return yaml.safe_load(f)


def cargar_modbus_map():
    """El mapa que lee el colector: de aquí salen los tamaños de bloque."""
    return cargar_yaml(os.path.join(RAIZ, "config", "modbus_map.yml"))


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


def normaliza(nombre):
    """Para comparar 'El Burgo I' con 'El Burgo I 23003'."""
    return " ".join(str(nombre).lower().split())


def cargar_flota(_ignorado=None):
    """Inventario de plantas: el MISMO plano que pinta el SCADA (`index.html`).

    Sale de las constantes de planta embebidas en el frontend (`const AYORA=…`),
    que `tools/sync_plantas.mjs` mantiene iguales a las del siting. Cada TCU
    declara su NCU y su gateway, así que el reparto es el real.

    Para San José manda el plano —2289 TCU— y no el `config_tcu_sunner_sanjose.csv`,
    que lista 2186 configurados (decidido con el mantenedor el 2026-08-20): lo que
    cuenta para tráfico es lo que el colector va a pollear.

    Antes esto leía `tools/tcu-toolbox/plantas/*.json` y estaba MAL: ese fichero
    solo lleva las NCU que alguien declaró para la herramienta de campo. En San
    José faltaban 5 de las 21 (1686 TCU en vez de 2289) y no estaban ni Páramo,
    ni Benante, ni Panbianco, ni El Polvorín.
    """
    import re
    ruta = os.path.join(RAIZ, "index.html")
    if not os.path.exists(ruta):
        return []
    with open(ruta, encoding="utf-8") as f:
        html = f.read()

    def objeto(nombre):
        i = html.index("const " + nombre + "={")
        j = html.index("{", i)
        prof = 0
        for k in range(j, len(html)):
            if html[k] == "{":
                prof += 1
            elif html[k] == "}":
                prof -= 1
                if prof == 0:
                    return json.loads(html[j:k + 1])
        return None

    flota = []
    for nombre in re.findall(r'^const ([A-Z0-9_]+)=\{"ox"', html, re.M):
        d = objeto(nombre)
        if not d or not d.get("tcus"):
            continue
        # [x, y, ncu, gw, etiqueta, …] por TCU; [idx, nombre, enlace, x, y, …] por NCU
        nombres = {n[0]: str(n[1]) for n in d.get("ncus", [])}
        tcu, gws = {}, {}
        for t in d["tcus"]:
            idx = t[2]
            tcu[idx] = tcu.get(idx, 0) + 1
            gws.setdefault(idx, set()).add(t[3])
        # HSU: la segunda columna es el nombre de su NCU cuando se conoce; si no,
        # se reparten a partes iguales (son 10 registros, no mueven la aguja).
        hsus = {i: 0 for i in tcu}
        sueltas = 0
        for h in d.get("hsus", []):
            dueno = next((i for i, nom in nombres.items() if nom and nom == str(h[1])), None)
            if dueno in hsus:
                hsus[dueno] += 1
            else:
                sueltas += 1
        if sueltas and tcu:
            reparto, resto = divmod(sueltas, len(tcu))
            for pos, i in enumerate(sorted(tcu)):
                hsus[i] += reparto + (1 if pos < resto else 0)
        flota.append({
            "planta": d.get("name", nombre),
            "ncus": [{"id": nombres.get(i, str(i)), "tcu_count": tcu[i],
                      "hsu_count": hsus[i], "gws": len(gws[i])} for i in sorted(tcu)],
        })
    flota.sort(key=lambda p: -sum(n["tcu_count"] for n in p["ncus"]))
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
    ap.add_argument("--zigbee-saltos", type=float, default=None,
                    help="saltos medios al coordinador (por defecto, los medidos en El Burgo)")
    ap.add_argument("--nube-cada", type=float, default=None, metavar="S",
                    help="subir a la nube solo cada S segundos (minutal, 5 min...); "
                         "el polling de la NCU no cambia")
    ap.add_argument("--plan", choices=sorted(PRESETS), default="todo",
                    help="qué campos se suben (por defecto: todo)")
    ap.add_argument("--agregado", action="store_true",
                    help="subir media/mínimo/máximo de la ventana en vez del último valor")
    ap.add_argument("--planes", action="store_true",
                    help="compara planes de subida para la planta configurada")
    ap.add_argument("--campos", action="store_true",
                    help="cuánto pesa cada campo (quitándolo y volviendo a comprimir)")
    ap.add_argument("--json", action="store_true", help="salida en JSON")
    a = ap.parse_args()

    cfg = cargar_plants_yml(os.path.join(RAIZ, "config", "plants.yml"))
    mmap = cargar_modbus_map()
    mapa_kw = {"mmap": mmap, "polling": cfg.get("polling") if cfg else None} if mmap else {}
    base_int = float(cfg["polling"]["interval_s"]) if cfg else 30.0

    if a.campos:
        print(f"{'campo':<18}{'B crudos/TCU':>13}{'B gz/TCU':>10}  (108 TCU, "
              f"{'agregado' if a.agregado else 'último valor'})")
        for f in field_weights(agregado=a.agregado):
            print(f"{f['campo']:<18}{f['raw_b_tcu']:>13.1f}{f['gz_b_tcu']:>10.2f}")
        print("\nLo que pesa un campo no es su longitud, es su dispersión: si vale lo mismo "
              "en\ntodos los seguidores, el gzip lo deja en nada.")
        return

    if a.planes:
        ncus = cfg["ncus"] if cfg else [{"id": "NCU", "tcu_count": 108, "hsu_count": 2}]
        nombre = cfg["plant"]["name"] if cfg else "planta tipo"
        print(f"=== Planes de subida · {nombre} · polling {base_int:g} s (no cambia) ===\n")
        print(f"{'sube cada':>10} {'campos':<11}{'modo':<14}{'MB/día':>9}{'GB/mes':>9}{'vs hoy':>9}")
        print("-" * 62)
        ref = None
        for up in (base_int, 60, 300, 900, 3600):
            for preset in ("todo", "operacion", "minimo"):
                for agr in (False, True):
                    if agr and up <= base_int:
                        continue          # agregar una ventana de un ciclo no es agregar
                    mb = sum(cloud_plan(int(n["tcu_count"]), int(n.get("hsu_count", 0)),
                                        poll_s=base_int, upload_s=up, preset=preset,
                                        agregado=agr, ncu=str(n["id"]))["cloud_mb_day"]
                             for n in ncus)
                    if ref is None:
                        ref = mb
                    etiqueta = "media/mín/máx" if agr else "último valor"
                    ritmo = f"{up:g} s" if up < 120 else f"{up / 60:g} min"
                    print(f"{ritmo:>10} {preset:<11}{etiqueta:<14}{mb:>9.2f}{mb * 30 / 1000:>9.3f}"
                          f"{100 * mb / ref:>8.0f}%")
        print("\nEl polling de la NCU no se toca: solo cambia cada cuánto se sube y qué se sube.\n"
              "'último valor' = el de la última lectura de la ventana; el resto se queda en "
              "InfluxDB local.")
        return
    intervalos = [float(x) for x in a.intervalo.split(",")] if a.intervalo else [base_int]

    salida = {"intervalos_s": intervalos, "configurada": None, "flota": [], "zigbee": []}
    flota = cargar_flota()
    if cfg:   # la planta configurada va con sus datos buenos; no se repite
        n_cfg = normaliza(cfg["plant"]["name"])
        flota = [p for p in flota if not normaliza(p["planta"]).startswith(n_cfg)]

    nube_kw = {"upload_s": a.nube_cada, "preset": a.plan, "agregado": a.agregado}
    if cfg:
        salida["configurada"] = {
            "planta": cfg["plant"]["name"],
            "por_intervalo": {i: plant_estimate(cfg["ncus"], interval_s=i, **mapa_kw)
                              for i in intervalos},
        }
    for p in flota:
        salida["flota"].append({
            "planta": p["planta"],
            "por_intervalo": {i: plant_estimate(p["ncus"], interval_s=i, **mapa_kw)
                              for i in intervalos},
        })
    if a.zigbee:
        for p in flota:
            for n in p["ncus"]:
                # cada gateway es una malla propia: el aire se ocupa por malla,
                # el volumen se suma en la NCU.
                gws = max(1, n.get("gws", 1))
                z = zigbee_estimate(round(n["tcu_count"] / gws), cycle_s=a.zigbee_ciclo,
                                    **({"hops": a.zigbee_saltos} if a.zigbee_saltos else {}))
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
        todas = salida["flota"] + ([salida["configurada"]] if salida["configurada"] else [])
        tot_nube = sum(p["por_intervalo"][i]["cloud_mb_day"] for p in todas)
        tot_tcu = sum(p["por_intervalo"][i]["tcus"] for p in todas)
        tot_lan = sum(p["por_intervalo"][i]["lan_mb_day"] for p in todas)
        print("-" * len(CAB))
        print(f"{'FLOTA (con la *)':<22} {'':>4} {tot_tcu:>6} {tot_lan:>10.1f} {'':>10} "
              f"{tot_nube:>10.1f} {tot_nube * 30 / 1000:>9.2f}")

    print("\n* planta configurada en config/plants.yml (intervalo y HSU reales); el resto "
          "sale del\n  plano del propio SCADA (index.html), que es el que dice qué TCU cuelga "
          "de qué NCU.")
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
        print(f"Saltos: {a.zigbee_saltos or ZB_SALTOS} "
              f"({'los que has pasado' if a.zigbee_saltos else 'MEDIDOS en El Burgo NCU1-GW2'}). "
              "El resto del modelo\nsigue en collector/traffic.py (ZB_*): la trama la fija el "
              "protocolo y los reintentos siguen supuestos.")


if __name__ == "__main__":
    main()
