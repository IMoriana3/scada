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

    def col_opcional(*nombres):
        """Igual que col() pero devuelve None si no esta: para columnas que
        todavia no existen en todos los Excel."""
        for n in nombres:
            if n in head:
                return head.index(n)
        return None

    i_num, i_proy, i_ncu = col("Nº"), col("Proyecto"), col("NCU")
    i_ip = col("IP NCU")
    i_esc1 = col("Esclavos")
    i_esc2 = col("Esclavos", col("IP GW 2"))   # segundo 'Esclavos', tras IP GW 2
    # El numero de esclavo Modbus de la HSU (estacion meteo) de cada NCU. La
    # hoja no lo trae todavia: en cuanto exista una columna 'HSU' (o
    # 'HSU esclavo'), con el numero por fila de NCU, sale solo en el JSON y la
    # toolbox lo preselecciona en vez de tirar del 185 por defecto.
    # Admite un numero ('230') o varios si esa NCU lleva mas de una estacion
    # ('230,231'), en el orden de los huecos HSU1, HSU2... de la cache de la NCU.
    i_hsu = col_opcional("HSU esclavo", "Esclavo HSU", "HSU")
    if i_hsu is None:
        print(f"aviso: la hoja '{hoja}' no tiene columna 'HSU esclavo'; se conservan "
              "los que ya tenga el JSON y el resto saldra sin el (la toolbox usara 185)")
    # CUANTAS estaciones lleva cada NCU si lo dicen las columnas 'RSU' (una por
    # gateway). Ahi va un numero de orden dentro de la planta (1, 2, 3...), NO
    # el esclavo Modbus: volcarlo en hsu_esclavo mandaria a la toolbox a hablar
    # con el esclavo 5, que es un TCU. Solo se cuenta, para poder decir cuantas
    # deberia encontrar BUSCAR HSUs.
    i_rsu1 = col_opcional("RSU")
    i_rsu2 = None
    if i_rsu1 is not None and "IP GW 2" in head:
        try:
            i_rsu2 = head.index("RSU", head.index("IP GW 2"))
        except ValueError:
            i_rsu2 = None

    plantas = {}
    actual = None
    ncu_auto = 0
    ultima_entrada = None      # las entradas de la ultima NCU con IP, para las filas de continuacion
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
        # El Excel solo pone el nombre en la PRIMERA fila de cada planta, asi
        # que usar el de la fila dejaba " NCU2", " NCU3"... sin nombre. Y la
        # toolbox agrupa la entrada "(Planta completa)" por ese prefijo: con
        # los nombres partidos salian dos grupos, uno con la NCU1 sola (que se
        # descarta por tener menos de dos) y otro con el resto. Ayora se
        # quedaba con 15 de 16 NCUs.
        proy = actual[1]

        def rsus_fila():
            """Cuantas RSU/HSU declara esta fila, entre los dos gateways."""
            return sum(1 for i in (i_rsu1, i_rsu2)
                       if i is not None and re.match(r"^\d+$", re.sub(r"\.0$", "", v(i))))

        def esclavos_fila():
            """Los esclavos Modbus que declara esta fila: '230' o '230,231'."""
            if i_hsu is None:
                return []
            crudo = re.sub(r"\.0$", "", v(i_hsu))
            return [int(x) for x in re.split(r"[,;/ ]+", crudo) if re.match(r"^\d+$", x)]

        ip = v(i_ip)
        if not re.match(r"^\d+\.\d+\.\d+\.\d+$", ip):
            # Una NCU con DOS estaciones ocupa dos filas: la segunda solo lleva
            # el numero de RSU, sin NCU ni IP, y cuelga de la NCU de arriba.
            # Ayora es asi: la NCU15 tiene la 8 y la 9. Saltandola entera se
            # perdia una de las diez.
            if ultima_entrada is not None and rsus_fila():
                for e in ultima_entrada:
                    e["hsus"] = e.get("hsus", 0) + rsus_fila()
                    for esc in esclavos_fila():
                        e.setdefault("hsu_esclavos", []).append(esc)
            continue
        ncu_auto += 1
        ntxt = re.sub(r"\.0$", "", v(i_ncu))
        n = int(ntxt) if re.match(r"^\d+$", ntxt) else ncu_auto
        rangos = [parse_rango(v(i_esc1)), parse_rango(v(i_esc2))]
        gws = [(puertos[k], r) for k, r in enumerate(rangos) if r and k < len(puertos)]
        if not gws:
            continue
        escl = esclavos_fila()
        nRsu = rsus_fila()
        ultima_entrada = []
        for gidx, (puerto, (ini, fin)) in enumerate(gws, start=1):
            sufijo = f" GW{gidx}" if len(gws) > 1 else ""
            entrada = {
                "nombre": f"{proy} NCU{n}{sufijo}",
                "ip": ip,
                "puerto": puerto,
                "tcu_ini": ini,
                "tcu_fin": fin,
            }
            # La HSU cuelga de UN gateway, no de los dos, pero cual es no lo
            # dice el Excel: se pone en las entradas de la NCU y la toolbox ya
            # avisa de cambiar el puerto si no responde por ese.
            if escl:
                entrada["hsu_esclavos"] = list(escl)
            if nRsu:
                entrada["hsus"] = nRsu
            plantas[actual].append(entrada)
            ultima_entrada.append(entrada)

    ficheros = []
    for (num, proy), entradas in sorted(plantas.items()):
        if not entradas or num in excluir:
            continue
        destino = Path("plantas") / f"{num}-{slug(proy)}.json"
        destino.parent.mkdir(parents=True, exist_ok=True)
        # Los esclavos de las HSUs no estan en el Excel (todavia): si el JSON
        # anterior los traia puestos a mano, regenerar no puede borrarlos. Solo
        # se conservan los que el Excel NO manda; en cuanto la hoja tenga la
        # columna, manda la hoja.
        if destino.exists():
            try:
                previo = json.loads(destino.read_text(encoding="utf-8"))
                antes = {e.get("nombre"): e for e in previo.get("plantas", [])}
            except (ValueError, OSError):
                antes = {}
            conservados = 0
            for e in entradas:
                viejo = antes.get(e.get("nombre"))
                if viejo and "hsu_esclavos" not in e and viejo.get("hsu_esclavos"):
                    e["hsu_esclavos"] = viejo["hsu_esclavos"]
                    conservados += 1
            if conservados:
                print(f"  {destino}: conservados los esclavos de HSU de {conservados} entradas "
                      "(no estan en el Excel)")
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
                entrada = {
                    "nombre": gw.get("nombre") or f"{nombre_planta} {ncu.get('id', host)}{sufijo}",
                    "ip": host,
                    "puerto": puerto,
                    "tcu_ini": ini,
                    "tcu_fin": fin,
                }
                # La estación meteo cuelga de UN gateway, no de los dos, y ahora
                # el gateway lo dice: `hsu_esclavo` en su fila de plants.yml
                # (230 en el GW1, 231 en el GW2). Antes esto no se sabía y el
                # esclavo se repetía en las entradas de la NCU entera, dejando a
                # la toolbox adivinando el puerto.
                esc = gw.get("hsu_esclavo", gw.get("hsu_esclavos"))
                if esc is not None:
                    escl = [int(x) for x in (esc if isinstance(esc, (list, tuple)) else [esc])]
                    if escl:
                        entrada["hsus"] = len(escl)
                        entrada["hsu_esclavos"] = escl
                plantas.append(entrada)
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
