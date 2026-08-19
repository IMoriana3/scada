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


def test_visor_html():
    """El modelo del visor (JS) tiene que dar lo mismo que el de Python.

    `trafico.html` reimplementa el lado Modbus en JavaScript y lleva horneada
    una curva para el lado nube. Si una de las dos partes se desvía, aquí se ve.
    """
    import json
    import shutil
    import subprocess
    html = os.path.join(RAIZ, "trafico.html")
    if not shutil.which("node"):
        print("  --  visor trafico.html (no hay node)")
        return
    js = r"""
      const fs=require('fs');
      const src=fs.readFileSync(process.argv[1],'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
      // el bloque toca el DOM al final: se corta justo antes de los manejadores
      const modelo=src.slice(0, src.indexOf('/* ---------- estado ----------'));
      const f=new Function(modelo+'; return {DATOS, cicloModbus, interpNube, zigbee};')();
      const out={ncus:[],curva:[]};
      for(const p of f.DATOS.plantas) for(const n of p.ncus){
        const m=f.cicloModbus(n.tcu,n.hsu);
        out.ncus.push({id:n.id,tcu:n.tcu,hsu:n.hsu,lanJs:m.lan,txJs:m.tx,lanDato:n.lan,txDato:n.tx});
      }
      for(const plan of ['todo','operacion','minimo']) for(const agr of [0,1])
        for(const n of [7,33,64,111,250,777,1500])
          out.curva.push({n, plan, agr, gz:f.interpNube(n,plan,agr).gz});
      console.log(JSON.stringify(out));
    """
    r = subprocess.run(["node", "-e", js, html], capture_output=True, text=True)
    if r.returncode:
        check("el visor evalúa", False, r.stderr.strip()[:200])
        return
    out = json.loads(r.stdout)
    check("el visor lleva la flota horneada", len(out["ncus"]) > 30, f"({len(out['ncus'])} NCU)")
    malos = [n for n in out["ncus"] if n["lanJs"] != n["lanDato"] or n["txJs"] != n["txDato"]]
    check("el modelo LAN del visor == el de Python", not malos,
          f"({len(malos)} NCU descuadran, p.ej. {malos[0] if malos else ''})")
    peor, peor_txt = 0, ""
    for c in out["curva"]:
        real = T.cloud_cycle(c["n"], 1, campos=T.PRESETS[c["plan"]],
                             agregado=bool(c["agr"]))["cloud_gz_b"]
        e = abs(c["gz"] - real) / real
        if e > peor:
            peor, peor_txt = e, f'{c["plan"]}/{"agr" if c["agr"] else "últ"} n={c["n"]}'
    check("las curvas de nube (3 planes x 2 modos) interpolan con menos del 2 %",
          peor < 0.02, f"(peor {100 * peor:.1f} % en {peor_txt})")


def test_visor_al_dia():
    """El bloque de datos del visor tiene que ser el que sale del inventario de hoy."""
    sys.path.insert(0, os.path.join(RAIZ, "tools"))
    import gen_trafico
    html = os.path.join(RAIZ, "trafico.html")
    with open(html, encoding="utf-8") as f:
        actual = f.read()
    esperado = gen_trafico.bloque(gen_trafico.construir())
    check("trafico.html lleva el inventario al día", esperado in actual,
          "regenera con: python tools/gen_trafico.py --write")


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


def test_planes_de_subida():
    """Leer a un ritmo y subir a otro: lo que pide el 4G de una caseta."""
    base = T.cloud_plan(108, 2, poll_s=30)
    minutal = T.cloud_plan(108, 2, poll_s=30, upload_s=60)
    check("subir la mitad de veces cuesta la mitad",
          math.isclose(minutal["cloud_mb_day"], base["cloud_mb_day"] / 2, rel_tol=1e-9))
    check("no se puede subir más a menudo de lo que se lee",
          T.cloud_plan(108, 2, poll_s=30, upload_s=5)["upload_s"] == 30)
    todo = base["cloud_mb_day"]
    oper = T.cloud_plan(108, 2, poll_s=30, preset="operacion")["cloud_mb_day"]
    mini = T.cloud_plan(108, 2, poll_s=30, preset="minimo")["cloud_mb_day"]
    check("menos campos, menos subida", todo > oper > mini, f"({todo:.1f} {oper:.1f} {mini:.1f})")
    check("el mínimo no baja de la mitad: la cabecera y las etiquetas no se van",
          mini > todo * 0.3, f"(mínimo {100 * mini / todo:.0f} % de todo)")
    agr = T.cloud_plan(108, 2, poll_s=30, upload_s=60, agregado=True)["cloud_mb_day"]
    check("agregar la ventana pesa más que mandar el último valor",
          agr > minutal["cloud_mb_day"])
    check("minutal agregado puede salir MÁS caro que 30 s a pelo (media/mín/máx triplica campos)",
          agr > todo, f"(agregado {agr:.1f} vs hoy {todo:.1f})")


def test_peso_por_campo():
    pesos = T.field_weights(n_tcu=108, n_hsu=2)
    d = {p["campo"]: p for p in pesos}
    check("todos los campos tienen peso", len(pesos) == 17, f"({len(pesos)})")
    check("lo que no varía casi no pesa comprimido: target_angle < soc",
          d["target_angle"]["gz_b_tcu"] < d["soc"]["gz_b_tcu"],
          f'({d["target_angle"]["gz_b_tcu"]:.2f} vs {d["soc"]["gz_b_tcu"]:.2f})')
    check("y aun así ocupa más en crudo (el gzip es quien decide)",
          d["target_angle"]["raw_b_tcu"] > d["soc"]["raw_b_tcu"])
    check("la suma de los campos no se pasa del total",
          sum(p["gz_b_tcu"] for p in pesos) < T.cloud_cycle(108, 2)["cloud_gz_b"] / 108)


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
               test_estimacion_vs_driver, test_line_protocol_real, test_visor_html,
               test_visor_al_dia, test_escala, test_planes_de_subida,
               test_peso_por_campo, test_zigbee):
        print(f"\n{fn.__name__}:")
        fn()
    print()
    if FALLOS:
        print(f"{len(FALLOS)} FALLOS: {', '.join(FALLOS)}")
        sys.exit(1)
    print("Todo OK")
