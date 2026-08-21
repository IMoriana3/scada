"""Banco de `comms_age_s`: la resta es NCU−NCU, y se mide en COLOR DE FLOTA.

`tcu_lastcomm` (29500) es una marca que pone **la NCU** con su reloj. El
colector le restaba la hora de **su propio host**, así que el desvío entre los
dos relojes entraba entero en la edad. Y `tracker_health()` da por `offline`
todo lo que pase de 300 s: una NCU media hora atrasada daba **su flota entera
por offline**, con los TCUs hablando perfectamente.

Lo que se mide aquí NO es la aritmética de la resta -- eso lo comprobaría un
test que no sirve de nada, porque el bug no era aritmético: los dos números
estaban bien, y estaban tomados de dos sitios distintos. Lo que se mide es la
CONSECUENCIA: cuántos trackers se pintan de cada color antes y después. Ese es
el número por el que el mantenedor tenía la decisión reservada.

    python tools/test_comms_age.py
"""
import asyncio
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(RAIZ / "collector"))
sys.path.insert(0, str(RAIZ / "collector" / "drivers"))

import yaml                                                    # noqa: E402
from decode import tracker_health                              # noqa: E402
from drivers.simulated import SimulatedNCUDriver               # noqa: E402

MMAP = yaml.safe_load((RAIZ / "config" / "modbus_map.yml").read_text())
N = 108                       # una NCU de El Burgo
UMBRAL = 300                  # `stale_after_s` de tracker_health()

ok = 0
fallos = []


def chk(nombre, actual, esperado):
    global ok
    if actual == esperado:
        ok += 1
        print(f"  ok    {nombre} = {actual}")
    else:
        fallos.append(f"{nombre}: {actual!r} != {esperado!r}")
        print(f"  FALLO {nombre}: {actual!r} != {esperado!r}")


def chk_true(nombre, cond, detalle=""):
    global ok
    if cond:
        ok += 1
        print(f"  ok    {nombre}{(' — ' + detalle) if detalle else ''}")
    else:
        fallos.append(nombre)
        print(f"  FALLO {nombre}{(' — ' + detalle) if detalle else ''}")


async def flota(skew_s, con_reloj=True):
    """Corre un ciclo y devuelve el reparto de colores + el diagnóstico.

    `con_reloj=False` reproduce el comportamiento ANTERIOR: sin el reloj de la
    NCU, la resta cae al host y el desvío entra en la edad. Es el mutante, y
    tiene que salir rojo.
    """
    drv = SimulatedNCUDriver({"id": "NCU-01", "tcu_count": N, "hsu_count": 0,
                              "ncu_skew_s": skew_s}, MMAP)
    await drv.connect()
    if con_reloj:
        await drv.read_ncu()          # el ciclo real lee la NCU PRIMERO
    trs = await drv.read_trackers()
    await drv.close()
    cnt = {"ok": 0, "warn": 0, "alarm": 0, "offline": 0}
    for t in trs:
        cnt[tracker_health(t["fields"], t["alarms"], t["comms_age_s"], UMBRAL)] += 1
    return cnt, trs


async def main():
    print("=== el reloj de la NCU al día: nada cambia ===")
    cnt, trs = await flota(0)
    chk_true("con desvío 0 no hay ni un tracker dado por offline de más",
             cnt["offline"] <= N // 40, f"{cnt['offline']} de {N} (los deliberados del simulado)")
    chk("todos declaran de dónde sale su edad",
        sorted({t["comms_age_src"] for t in trs}), ["ncu"])
    chk_true("y el desvío publicado es 0", all(abs(t["skew_s"]) <= 1 for t in trs),
             f"skew = {trs[0]['skew_s']} s")

    print("\n=== una NCU MEDIA HORA atrasada: el caso que rompía la flota ===")
    cnt_b, trs_b = await flota(1800)
    cnt_m, trs_m = await flota(1800, con_reloj=False)
    print(f"  antes (host−NCU, el bug):  {cnt_m}")
    print(f"  ahora (NCU−NCU, arreglado): {cnt_b}")
    chk_true("EL MUTANTE: sin el reloj de la NCU, media hora de desvío apaga la flota entera",
             cnt_m["offline"] == N, f"{cnt_m['offline']} de {N} en offline")
    chk_true("y con la resta NCU−NCU la flota sigue viva",
             cnt_b["offline"] <= N // 40, f"{cnt_b['offline']} de {N}")
    chk_true("el desvío no se tira: sale como skew_s para poder vigilarlo",
             abs(trs_b[0]["skew_s"] - 1800) < 5, f"skew_s = {trs_b[0]['skew_s']} s")

    print("\n=== el desvío al OTRO lado (NCU adelantada) ===")
    # Un reloj adelantado daba edades NEGATIVAS, que pasaban el umbral y se
    # leían como "recién hablado" -- el bug en su version silenciosa: no pinta
    # nada raro, solo miente a favor.
    cnt_a, trs_a = await flota(-1800)
    chk_true("con la NCU adelantada la edad sigue siendo la de verdad, no negativa",
             all(t["comms_age_s"] >= 0 for t in trs_a),
             f"minima = {min(t['comms_age_s'] for t in trs_a)} s")
    chk_true("y el skew_s lo dice con su signo", trs_a[0]["skew_s"] < 0,
             f"skew_s = {trs_a[0]['skew_s']} s")

    print("\n=== el fallback va DECLARADO, no callado ===")
    _, trs_f = await flota(0, con_reloj=False)
    chk("sin reloj de NCU la fuente se declara 'host'",
        sorted({t["comms_age_src"] for t in trs_f}), ["host"])
    chk_true("y entonces no se inventa un skew", all(t["skew_s"] is None for t in trs_f))

    print("\n=== una marca que no existe no es una edad de 0 ===")
    drv = SimulatedNCUDriver({"id": "NCU-01", "tcu_count": 1, "hsu_count": 0}, MMAP)
    await drv.read_ncu()
    edad, skew, origen = drv.edad_comms(0, 1_000_000.0)
    chk("last_comm = 0 -> sin edad", edad, None)
    chk("y se dice por que", origen, "sin_marca")

    print(f"\n{'Todo OK' if not fallos else 'FALLAN ' + str(len(fallos))} ({ok} comprobaciones)")
    return 1 if fallos else 0


sys.exit(asyncio.run(main()))
