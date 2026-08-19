#!/usr/bin/env python3
"""Banco del medidor de tráfico. `python tools/test_trafico.py` (sin pytest).

Comprueba tres cosas que es fácil romper sin enterarse:
  1. el modelo de bytes (troceo, tamaño de ADU, handshake),
  2. que la ESTIMACIÓN y lo que el driver CONTABILIZA de verdad coinciden,
  3. que el line protocol de ejemplo es el mismo que genera influxdb_client
     (si la librería está instalada; si no, ese caso se salta).
"""
import asyncio
import math
import os
import sys

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(RAIZ, "collector"))

import traffic as T  # noqa: E402

FALLOS = []


def check(nombre, cond, detalle=""):
    if cond:
        print(f"  ok  {nombre}")
    else:
        print(f"FALLO {nombre} {detalle}")
        FALLOS.append(nombre)


def test_troceo():
    check("troceo exacto", T.split_reads(220, 110) == [110, 110])
    check("troceo con resto", T.split_reads(216, 110) == [110, 106])
    check("troceo de 0", T.split_reads(0, 110) == [])
    n = 108 * 22
    check("el troceo conserva los registros", sum(T.split_reads(n, 110)) == n)
    check("ningún trozo pasa del límite Modbus",
          all(x <= 125 for x in T.split_reads(n, 110)))


def test_bytes_adu():
    up, down = T.read_bytes(110, overhead_b=0)
    check("petición FC03 = 12 B", up == 12, f"({up})")
    check("respuesta 110 regs = 229 B", down == 229, f"({down})")
    up, down = T.read_bytes(1)
    check("con cabecera IP+TCP", (up, down) == (52, 51), f"({up},{down})")


def test_medidor():
    m = T.TrafficMeter()
    m.connection()
    m.read(110)
    s = m.snapshot(30)
    check("la conexión cuesta 7 segmentos", s["lan_b"] - (52 + 269) == 7 * 40,
          f"({s['lan_b']})")
    check("una transacción contada", s["modbus_tx"] == 1)
    check("snapshot deja el contador a cero", m.snapshot(1)["lan_b"] == 0)


def test_nube():
    m = T.TrafficMeter()
    lineas = T.sample_lines("elburgo", "NCU1", 108, 2)
    m.cloud_write(lineas)
    s = m.snapshot(30)
    check("crudo = suma de líneas",
          s["cloud_raw_b"] == sum(len(l) + 1 for l in lineas))
    check("comprimido < crudo", s["cloud_gz_b"] < s["cloud_raw_b"])
    check("el gzip no es milagroso (ratio < 20x)",
          s["cloud_raw_b"] / max(1, s["cloud_gz_b"] - T.HTTP_OVERHEAD_B) < 20,
          f"(ratio {s['cloud_raw_b'] / max(1, s['cloud_gz_b'] - T.HTTP_OVERHEAD_B):.1f})")
    check("cobra la cabecera HTTP una vez por escritura",
          s["cloud_gz_b"] > T.HTTP_OVERHEAD_B)
    m2 = T.TrafficMeter()
    m2.cloud_write(lineas)
    check("dos ciclos iguales pesan igual", m2.snapshot(30)["cloud_gz_b"] == s["cloud_gz_b"])
    check("escritura vacía no cuenta", T.TrafficMeter().snapshot(1)["cloud_writes"] == 0)


def test_estimacion_vs_driver():
    """Lo estimado tiene que ser EXACTAMENTE lo que el driver contabiliza."""
    import yaml
    with open(os.path.join(RAIZ, "config", "modbus_map.yml"), encoding="utf-8") as f:
        mmap = yaml.safe_load(f)
    from drivers.simulated import SimulatedNCUDriver

    ncu = {"id": "NCU1", "tcu_count": 108, "hsu_count": 2}
    m = T.TrafficMeter()
    drv = SimulatedNCUDriver(ncu, mmap, "big", meter=m, max_regs=110)

    async def un_ciclo():
        await drv.connect()
        await drv.read_trackers()
        await drv.read_ncu()
        await drv.read_meteo()
        await drv.close()

    asyncio.run(un_ciclo())
    real = m.snapshot(30)
    est = T.modbus_cycle(108, 2, max_regs=110)
    check("transacciones estimadas = contadas",
          est["modbus_tx"] == real["modbus_tx"], f"({est['modbus_tx']} vs {real['modbus_tx']})")
    check("bytes estimados = contados",
          est["lan_b"] == real["lan_b"], f"({est['lan_b']} vs {real['lan_b']})")


def test_line_protocol_real():
    try:
        from influxdb_client import Point
    except ImportError:
        print("  --  line protocol vs influxdb_client (librería no instalada)")
        return
    linea = T.sample_lines("elburgo", "NCU1", 1)[0]
    medida, _, campos = linea.partition(" ")
    p = Point("tracker_status").tag("plant", "elburgo").tag("ncu", "NCU1").tag("tcu", "1")
    for kv in campos.split(","):
        k, _, v = kv.partition("=")
        p.field(k, v.strip('"') if v.startswith('"') else float(v))
    real = p.to_line_protocol()
    check("las etiquetas van como las escribe influxdb_client",
          real.split(" ")[0] == medida, f"\n    {real.split(' ')[0]}\n    {medida}")
    check("los campos van como los escribe influxdb_client",
          real.split(" ", 1)[1] == campos, f"\n    {real.split(' ', 1)[1]}\n    {campos}")


def test_escala():
    """Sanidad de la extrapolación: el doble de TCU no puede costar menos."""
    a = T.ncu_estimate(50, 1, interval_s=30, ncu="N1")
    b = T.ncu_estimate(100, 1, interval_s=30, ncu="N2")
    check("más TCU, más tráfico", b["cloud_mb_day"] > a["cloud_mb_day"])
    lento = T.ncu_estimate(100, 1, interval_s=60, ncu="N2")
    check("la mitad de ritmo, la mitad de tráfico",
          math.isclose(lento["cloud_mb_day"], b["cloud_mb_day"] / 2, rel_tol=0.02))
    planta = T.plant_estimate([{"id": "N1", "tcu_count": 50, "hsu_count": 1},
                               {"id": "N2", "tcu_count": 100, "hsu_count": 1}])
    check("la planta suma sus NCU",
          math.isclose(planta["cloud_mb_day"], a["cloud_mb_day"] + b["cloud_mb_day"],
                       rel_tol=1e-9))
    check("GB/mes coherente con MB/día",
          math.isclose(planta["cloud_gb_month"], planta["cloud_mb_day"] * 30 / 1000,
                       rel_tol=1e-9))


def test_zigbee():
    z = T.zigbee_estimate(52, cycle_s=60)
    check("ocupación de aire razonable en una malla de 52",
          0 < z["airtime_pct"] < 10, f"({z['airtime_pct']:.1f}%)")
    rapido = T.zigbee_estimate(52, cycle_s=10)
    check("refrescar 6x más rápido ocupa 6x más aire",
          math.isclose(rapido["airtime_pct"], z["airtime_pct"] * 6, rel_tol=1e-6))
    check("más saltos, más aire",
          T.zigbee_estimate(52, hops=3)["mb_day"] > z["mb_day"])


if __name__ == "__main__":
    for fn in (test_troceo, test_bytes_adu, test_medidor, test_nube,
               test_estimacion_vs_driver, test_line_protocol_real, test_escala,
               test_zigbee):
        print(f"\n{fn.__name__}:")
        fn()
    print()
    if FALLOS:
        print(f"{len(FALLOS)} FALLOS: {', '.join(FALLOS)}")
        sys.exit(1)
    print("Todo OK")
