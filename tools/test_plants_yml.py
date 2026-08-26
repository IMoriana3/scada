#!/usr/bin/env python3
"""
test_plants_yml.py — carea `config/plants.yml` contra el layout del DWG.

POR QUÉ EXISTE. `plants.yml` mezcla dos cosas distintas:

  · CONFIGURACIÓN DE OPERACIÓN — IPs, puertos, cadencias, driver. El layout no sabe nada de esto y
    se escribe a mano, como debe ser.
  · HECHOS DE LA PLANTA — cuántos TCU tiene cada NCU, cuántas HSU, qué rango de esclavos cuelga de
    cada gateway. Eso ya está medido en el DWG, y tenerlo escrito a mano OTRA VEZ es lo que se
    desincroniza.

Y se desincronizó: `hsu_count` decía 1 en la NCU1 y 0 en la NCU2 cuando el DWG dibuja CUATRO HSU,
una por gateway. El colector leía una de las cuatro y nadie se enteraba, porque nada lo careaba.

No se genera el fichero —se perderían las IPs y las cadencias, que aquí son la autoridad—: se
COMPARA, y si divergen se dice cuál gana y por qué.

    python3 tools/test_plants_yml.py                       usa el repo cobertura-zigbee de al lado
    python3 tools/test_plants_yml.py --layouts /ruta/       si está en otro sitio

Devuelve 1 si algo no cuadra, para poder colgarlo de un gate.
"""
import json
import os
import sys

AQUI = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
arg = [a for a in sys.argv[1:] if a.startswith("--layouts=")]
CAND = ([arg[0].split("=", 1)[1]] if arg else
        [os.path.join(os.path.dirname(AQUI), d) for d in ("Cobertura-Zigbee", "cobertura-zigbee")])

LAYOUTS = next((d for d in CAND if os.path.isdir(d)), None)
if not LAYOUTS:
    print("no encuentro los layouts. Ten al lado el repo cobertura-zigbee o pasa --layouts=<ruta>")
    sys.exit(2)

try:
    import yaml
except ImportError:
    print("falta PyYAML: pip install pyyaml")
    sys.exit(2)

cfg = yaml.safe_load(open(os.path.join(AQUI, "config", "plants.yml"), encoding="utf-8"))
planta = (cfg.get("plant") or {}).get("id")
if not planta:
    print("plants.yml no dice de qué planta es (plant.id)")
    sys.exit(2)

ruta = os.path.join(LAYOUTS, planta + "_layout.json")
if not os.path.exists(ruta):
    print("· %s — no hay layout de esta planta en %s, así que no hay contra qué carear."
          % (planta, LAYOUTS))
    sys.exit(0)

L = json.load(open(ruta, encoding="utf-8"))
T = L.get("trackers") or []
METEO = L.get("meteo") or []
print("· %s — %s contra %s_layout.json\n" % (planta, "config/plants.yml", planta))

malo = 0


def di(ok, texto):
    global malo
    if not ok:
        malo += 1
    print("  %s %s" % ("ok   " if ok else "FALLA", texto))


# ── TCU por NCU ──────────────────────────────────────────────────────────────────────────────
por_ncu = {}
for t in T:
    n = t.get("ncu") or 1
    por_ncu[n] = por_ncu.get(n, 0) + 1
for ncu in cfg.get("ncus") or []:
    num = int("".join(c for c in str(ncu.get("id", "")) if c.isdigit()) or 0)
    dice = ncu.get("tcu_count")
    mide = por_ncu.get(num)
    if mide is None:
        di(False, "NCU%d: plants.yml declara %s TCU y el layout no tiene ninguno de esa NCU" % (num, dice))
        continue
    di(dice == mide, "NCU%d: TCU  yml %s  ·  DWG %d%s"
       % (num, dice, mide, "" if dice == mide else "   ← manda el DWG"))

# ── HSU por NCU ──────────────────────────────────────────────────────────────────────────────
# NO TODA `meteo[].ncu` VALE LO MISMO, y este careo se rompería si las tratase igual. El layout dice
# de dónde sale cada una en `ncu_origen`: en El Burgo es de campo, en Benante y Panbianco la dice el
# nombre del DWG, y en Ayora, San José, Páramo y El Polvorín está DERIVADA por cercanía de seguidores
# (tools/meteo_ncu.mjs, en cobertura-zigbee). Contra un dato derivado esto no puede FALLAR: diría que
# el yml está mal cuando lo que puede estar mal es la deducción. Se informa y no se cuenta.
# Y si alguna HSU se quedó SIN ncu —porque la derivación no llegaba al margen mínimo— el recuento por
# NCU está incompleto por definición, así que tampoco se puede exigir que cuadre.
hsu_ncu = {}
derivadas = 0
for m in METEO:
    n = m.get("ncu")
    if n is not None:
        hsu_ncu[n] = hsu_ncu.get(n, 0) + 1
        if str(m.get("ncu_origen", "")).startswith("DERIVADO"):
            derivadas += 1
sin_ncu = sum(1 for m in METEO if m.get("ncu") is None)

if not hsu_ncu:
    print("  ??    el layout no dice de qué NCU cuelga cada HSU (meteo[].ncu): no se puede carear")
else:
    firme = not derivadas and not sin_ncu
    if derivadas:
        print("  ojo   %d de las %d HSU tienen la NCU DERIVADA por cercanía, no medida. Se compara "
              "para verte, pero no cuenta como fallo" % (derivadas, len(METEO)))
    if sin_ncu:
        print("  ojo   %d HSU del layout no traen NCU (la derivación no llegaba al margen mínimo): "
              "el recuento por NCU está incompleto y no cuenta como fallo" % sin_ncu)
    for ncu in cfg.get("ncus") or []:
        num = int("".join(c for c in str(ncu.get("id", "")) if c.isdigit()) or 0)
        dice = ncu.get("hsu_count")
        mide = hsu_ncu.get(num, 0)
        txt = "NCU%d: HSU  yml %s  ·  DWG %d" % (num, dice, mide)
        if dice == mide:
            di(True, txt)
        elif firme:
            di(False, txt + "   ← manda el DWG")
        else:
            print("  ojo   %s   ← con la NCU derivada o incompleta, esto es un aviso, no un fallo" % txt)

# ── los rangos de esclavos de cada gateway ───────────────────────────────────────────────────
esc = {}
for t in T:
    n, g = t.get("ncu") or 1, t.get("gw")
    if g is None:
        continue
    try:
        esc.setdefault((n, g), []).append(int(t["id"]))
    except (TypeError, ValueError):
        pass
if not esc:
    print("  ??    el layout no trae gateway por seguidor (trackers[].gw): no se carean los rangos")
else:
    for ncu in cfg.get("ncus") or []:
        num = int("".join(c for c in str(ncu.get("id", "")) if c.isdigit()) or 0)
        puertos = {}
        for gw in ncu.get("gateways") or []:
            puertos.setdefault(gw["puerto"], []).append(gw)
        for i, (puerto, filas) in enumerate(sorted(puertos.items()), start=1):
            rangos = sorted((int(f["tcu_ini"]), int(f["tcu_fin"])) for f in filas)
            dice = set()
            for a, b in rangos:
                dice.update(range(a, b + 1))
            mide = set(esc.get((num, i), []))
            if not mide:
                continue
            faltan, sobran = sorted(mide - dice), sorted(dice - mide)
            # DECLARADO A PROPOSITO. Hay esclavos que el SCADA sondea de verdad y el DWG no dibuja
            # -la TCU 109 de El Burgo sale de los .bat de Sunner-. Eso no es una divergencia que
            # arreglar: es un hecho conocido. Si la fila del gateway lo declara con `fuera_de_dwg`,
            # se informa y no cuenta como fallo. Un banco que grita por algo ya sabido se ignora.
            declarados = set()
            for fila in filas:
                for v in (fila.get("fuera_de_dwg") or []):
                    declarados.add(int(v))
            sobran_reales = [v for v in sobran if v not in declarados]
            txt = "NCU%d GW%d: esclavos  yml %d  ·  DWG %d" % (num, i, len(dice), len(mide))
            if faltan:
                txt += "   ← el yml NO sondea %s" % (faltan[:6],)
            if sobran_reales:
                txt += "   ← el yml sondea %s, que el DWG no dibuja" % (sobran_reales[:6],)
            elif sobran:
                txt += "   · %s declarados fuera del DWG" % (sorted(set(sobran) & declarados),)
            di(not faltan and not sobran_reales, txt)

# ── el huso, si el layout lo declara ─────────────────────────────────────────────────────────
if L.get("tzFijo") is not None:
    print("  ··    el layout declara huso FIJO %+d min; plants.yml no lo usa (el colector va en UTC)"
          % L["tzFijo"])

print("\n%s" % ("%d divergencia(s): el DWG es la autoridad, así que lo que hay que corregir es el yml"
                % malo if malo else "plants.yml cuadra con el DWG"))
sys.exit(1 if malo else 0)
