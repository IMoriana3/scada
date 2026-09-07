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
    # la estimación se arma con los tamaños del MAPA, no con números a mano
    est = T.modbus_cycle(108, 2, **T.map_params(mmap, {"max_regs_per_read": 110}))
    check("transacciones estimadas = contadas",
          est["modbus_tx"] == real["modbus_tx"], f"({est['modbus_tx']} vs {real['modbus_tx']})")
    check("bytes estimados = contados",
          est["lan_b"] == real["lan_b"], f"({est['lan_b']} vs {real['lan_b']})")


def test_hsu_externa_estimacion_vs_driver():
    """Las dos familias de HSU A LA VEZ: estimado = contado, y sin colision de ids.

    Una NCU puede tener HSUs basicas (30200) Y una externa (28000) -- el caso
    del 21/8 en Ayora. `hsu_ext_count` añade las externas SIN tocar la familia
    basica, y este test es la garantia de que el medidor sigue midiendo lo que
    el driver hace por ese camino nuevo.
    """
    import asyncio
    import yaml
    with open(os.path.join(RAIZ, "config", "modbus_map.yml"), encoding="utf-8") as f:
        mmap = yaml.safe_load(f)
    from drivers.simulated import SimulatedNCUDriver

    ncu = {"id": "NCU2", "tcu_count": 45, "hsu_count": 2, "hsu_ext_count": 1}
    m = T.TrafficMeter()
    drv = SimulatedNCUDriver(ncu, mmap, "big", meter=m, max_regs=110)

    async def un_ciclo():
        await drv.connect()
        await drv.read_trackers()
        await drv.read_ncu()
        return await drv.read_meteo()

    filas = asyncio.run(un_ciclo())
    real = m.snapshot(30)
    est = T.modbus_cycle(45, 2, n_hsu_ext=1,
                         **T.map_params(mmap, {"max_regs_per_read": 110}))
    check("con HSU externa: transacciones estimadas = contadas",
          est["modbus_tx"] == real["modbus_tx"], f"({est['modbus_tx']} vs {real['modbus_tx']})")
    check("con HSU externa: bytes estimados = contados",
          est["lan_b"] == real["lan_b"], f"({est['lan_b']} vs {real['lan_b']})")
    # y el mutante del propio test: sin declararla, la estimacion se queda corta
    sin = T.modbus_cycle(45, 2, **T.map_params(mmap, {"max_regs_per_read": 110}))
    check("y sin declararla la estimacion se queda CORTA: el parametro mide",
          sin["lan_b"] < real["lan_b"], f"({sin['lan_b']} vs {real['lan_b']})")

    ids = [str(f["hsu"]) for f in filas]
    check("los ids no colisionan: basicas 1..N y externas ext1..extM",
          ids == ["1", "2", "ext1"], f"({ids})")

    # la config contradictoria se dice ALTO, no se resuelve en silencio
    malo = SimulatedNCUDriver({"id": "X", "tcu_count": 1, "hsu_count": 2,
                               "hsu_extended": True, "hsu_ext_count": 1}, mmap, "big")
    try:
        asyncio.run(malo.read_meteo())
        check("hsu_extended + hsu_ext_count a la vez revienta con mensaje", False)
    except ValueError as e:
        check("hsu_extended + hsu_ext_count a la vez revienta con mensaje",
              "dos" in str(e) or "hsu_ext_count" in str(e))

    # la nube tambien: una linea mas por estacion externa, en el POST de estado
    con = T.cloud_cycle(45, 2, n_hsu_ext=1)
    sin_n = T.cloud_cycle(45, 2)
    check("la subida cuenta la linea de la externa",
          con["cloud_raw_b"] > sin_n["cloud_raw_b"])


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


def test_mapa_modbus():
    """La estimación tiene que salir del mapa, no de números escritos a mano.

    El driver lee `config/modbus_map.yml`; si el modelo llevara el 22 y el 10 a
    mano, un cambio de mapa movería al driver y dejaría quieta la estimación,
    que es justo la clase de desviación silenciosa que este banco existe para
    evitar.
    """
    import copy

    import yaml
    with open(os.path.join(RAIZ, "config", "modbus_map.yml"), encoding="utf-8") as f:
        mmap = yaml.safe_load(f)
    with open(os.path.join(RAIZ, "config", "plants.yml"), encoding="utf-8") as f:
        pol = yaml.safe_load(f)["polling"]
    p = T.map_params(mmap, pol)
    check("el stride del bloque compat sale del mapa",
          p["stride"] == mmap["tcu_compat"]["stride"], f'({p["stride"]})')
    check("el tamaño de la HSU sale del mapa (recortado a 30 como hace el driver)",
          p["hsu_regs"] == min(mmap["hsu"]["stride"], 30), f'({p["hsu_regs"]})')
    check("el troceo máximo sale de plants.yml",
          p["max_regs"] == pol["max_regs_per_read"], f'({p["max_regs"]})')
    check("la HSU extendida (bloque 28000) se lee más larga",
          T.map_params(mmap, pol, hsu_extended=True)["hsu_regs"] == 30)

    otro = copy.deepcopy(mmap)
    otro["tcu_compat"]["stride"] = 30
    base = T.modbus_cycle(108, 2, **T.map_params(mmap, pol))
    cambiado = T.modbus_cycle(108, 2, **T.map_params(otro, pol))
    check("si el mapa engorda el bloque, la estimación engorda con él",
          cambiado["lan_b"] > base["lan_b"],
          f'({base["lan_b"]} -> {cambiado["lan_b"]})')


def test_inventario_vs_botones():
    """El inventario contado tiene que ser el que anuncia la propia herramienta.

    Cada planta real declara en su botón «N TCU · M NCU». Si el recuento que
    saca el estimador del plano no coincide con ese rótulo, o se ha roto el
    lector o el rótulo miente: en los dos casos hay que enterarse aquí y no en
    una reunión.

    Decidido con el mantenedor (2026-08-20): para San José manda EL PLANO
    (2289 TCU), no el `config_tcu_sunner_sanjose.csv` (2186). El plano es lo que
    el colector va a pollear.
    """
    import re
    sys.path.insert(0, os.path.join(RAIZ, "tools"))
    from trafico import cargar_flota

    with open(os.path.join(RAIZ, "index.html"), encoding="utf-8") as f:
        html = f.read()
    rotulos = {}
    for m in re.finditer(r'data-sc="[a-z]+"[^>]*>([^<]+?) · proyecto real<small>'
                         r'([\d.]+) TCU · (\d+) NCU', html):
        rotulos[m.group(1).strip()] = (int(m.group(2).replace(".", "")), int(m.group(3)))
    check("los botones declaran su recuento", len(rotulos) >= 10, f"({len(rotulos)})")

    contado = {p["planta"]: (sum(n["tcu_count"] for n in p["ncus"]), len(p["ncus"]))
               for p in cargar_flota()}
    for nombre, (tcu, ncu) in sorted(rotulos.items()):
        real = contado.get(nombre)
        check(f"{nombre}: {tcu} TCU / {ncu} NCU contados en el plano",
              real == (tcu, ncu), f"contados {real}")


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


def test_calibracion_zigbee():
    """Los saltos del modelo son los MEDIDOS, y salen del fichero de la malla real."""
    import json
    import shutil
    sys.path.insert(0, os.path.join(RAIZ, "tools"))
    import calibrar_zigbee as C

    ruta = next((c for c in C.CANDIDATAS if c and os.path.exists(c)), None)
    if not ruta:
        print("  --  malla medida (elburgo_real.geojson no está al lado)")
        return
    r = C.calibrar(C.cargar(ruta))
    check("la malla medida trae los 52 TCU de la NCU1-GW2", r["nodos"] == 52, f'({r["nodos"]})')
    check("todos tienen salto conocido", r["con_salto"] == r["nodos"])
    check("el modelo usa los saltos medidos",
          abs(T.ZB_SALTOS - r["saltos_medios"]) < 0.01,
          f'(modelo {T.ZB_SALTOS} vs medido {r["saltos_medios"]})')
    check("y los medidos son bastantes más de los 2,0 que se suponían",
          r["saltos_medios"] > 3.5, f'({r["saltos_medios"]})')

    # La evidencia derivada vive en el repo (unos kB); el CSV crudo, de 16 MB, no.
    with open(os.path.join(RAIZ, "config", "malla_medida.json"), encoding="utf-8") as f:
        ev = json.load(f)
    check("la evidencia guardada lleva los mismos saltos",
          abs(ev["saltos_medios"] - T.ZB_SALTOS) < 0.01)
    check("el modelo usa los fallos de ACK medidos",
          abs(ev["ack"]["fallos_h_media"] - T.ZB_FALLOS_ACK_H) < 0.001,
          f'(modelo {T.ZB_FALLOS_ACK_H} vs medido {ev["ack"]["fallos_h_media"]})')
    check("la campaña es la que dice ser (52 TCU, miles de nodo·hora)",
          ev["ack"]["nodos"] == 52 and ev["ack"]["horas_nodo"] > 5000,
          f'({ev["ack"]["nodos"]} TCU, {ev["ack"]["horas_nodo"]} nodo·hora)')

    f60 = T.retry_factor_medido(60)
    check("a 60 s los reintentos medidos son calderilla, no el 15 % supuesto",
          1.0 < f60 < 1.01, f"({f60:.4f})")
    check("y pesan más cuanto más lento se sondea",
          T.retry_factor_medido(900) > T.retry_factor_medido(60))
    del shutil


def test_zigbee():
    z = T.zigbee_estimate(52, cycle_s=60)
    check("ocupación de aire razonable en una malla de 52",
          0 < z["airtime_pct"] < 15, f"({z['airtime_pct']:.1f}%)")
    check("con los saltos medidos ocupa el doble que con los 2,0 supuestos",
          math.isclose(z["airtime_pct"] / T.zigbee_estimate(52, cycle_s=60, hops=2.0)["airtime_pct"],
                       T.ZB_SALTOS / 2.0, rel_tol=1e-6))
    viejo = T.zigbee_estimate(52, cycle_s=60, hops=2.0, retry_factor=1.15)["airtime_pct"]
    check("las dos correcciones no se cancelan: la nueva cifra es mayor",
          z["airtime_pct"] > viejo, f'({z["airtime_pct"]:.2f} % vs {viejo:.2f} %)')
    rapido = T.zigbee_estimate(52, cycle_s=10)
    # Ya NO es proporcionalidad exacta: los reintentos medidos son fallos por
    # HORA, así que a un sondeo más rápido le tocan menos fallos por trama. El
    # efecto es del 0,1 %, pero fijarlo a 1e-6 sería fijar el modelo viejo.
    check("refrescar 6x más rápido ocupa ~6x más aire (los reintentos matizan)",
          math.isclose(rapido["airtime_pct"], z["airtime_pct"] * 6, rel_tol=5e-3),
          f'({rapido["airtime_pct"] / z["airtime_pct"]:.4f}x)')
    check("y el matiz va en la dirección buena: algo menos de 6x",
          rapido["airtime_pct"] < z["airtime_pct"] * 6)
    check("más saltos, más aire",
          T.zigbee_estimate(52, cycle_s=60, hops=6)["mb_day"] >
          T.zigbee_estimate(52, cycle_s=60, hops=3)["mb_day"])


if __name__ == "__main__":
    for fn in (test_troceo, test_bytes_adu, test_medidor, test_nube,
               test_estimacion_vs_driver, test_hsu_externa_estimacion_vs_driver,
               test_line_protocol_real, test_visor_html,
               test_visor_al_dia, test_mapa_modbus, test_inventario_vs_botones,
               test_escala, test_planes_de_subida, test_calibracion_zigbee,
               test_peso_por_campo, test_zigbee):
        print(f"\n{fn.__name__}:")
        fn()
    print()
    if FALLOS:
        print(f"{len(FALLOS)} FALLOS: {', '.join(FALLOS)}")
        sys.exit(1)
    print("Todo OK")
