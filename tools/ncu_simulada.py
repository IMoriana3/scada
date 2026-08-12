#!/usr/bin/env python3
"""NCU simulada: un esclavo Modbus TCP que sirve el mapa REAL de config/modbus_map.yml.

Ya existe drivers/simulated.py, pero ese entra por debajo del transporte: fabrica los dicts
de telemetría directamente y se salta el Modbus entero. Justo donde viven los fallos —
aritmética de direcciones, troceado a 110 registros por transacción, orden de palabra,
decode_tcu_block — no se ejercita nunca.

Esto es lo contrario: un servidor de verdad al que apuntar el driver de hierro
(ModbusNCUDriver) sin tener planta. Los registros se rellenan desde el MISMO YAML que lee
el colector, así que si alguien cambia una dirección en el mapa, la simulada cambia con él.

    python3 tools/ncu_simulada.py                       # 200 TCU, 2 HSU, puerto 5020
    python3 tools/ncu_simulada.py --tcus 60 --averias 3 # 3 TCU sin responder y con alarmas
    python3 tools/ncu_simulada.py --autotest            # arranca, se lee a sí misma y sale

Los valores son verosímiles, no reales: el ángulo sigue una curva de día, el SoC baja de
noche y sube de día, y las averías se inyectan a propósito. NO sirven para validar nada de
la planta — sirven para que el camino de datos se recorra entero.
"""
import argparse, asyncio, math, os, random, struct, sys, time

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(RAIZ, "collector"))

try:
    import yaml
except ImportError:
    sys.exit("falta pyyaml:  pip install pyyaml")


# ---------- codificación (la inversa exacta de collector/decode.py) ----------
def f32_regs(v, word_order="big"):
    hi, lo = struct.unpack(">HH", struct.pack(">f", float(v)))
    return [lo, hi] if word_order == "little" else [hi, lo]


def u32_regs(v, word_order="big"):
    v = int(v) & 0xFFFFFFFF
    hi, lo = (v >> 16) & 0xFFFF, v & 0xFFFF
    return [lo, hi] if word_order == "little" else [hi, lo]


def s16_reg(v):
    v = int(round(v))
    return v + 65536 if v < 0 else v & 0xFFFF


def pon_bits(base, campos, valores):
    """Compone una palabra a partir de {nombre: [lsb,msb]} y {nombre: valor}."""
    w = base
    for nombre, (lsb, msb) in campos.items():
        if nombre not in valores:
            continue
        anc = msb - lsb + 1
        m = ((1 << anc) - 1) << lsb
        w = (w & ~m) | ((int(valores[nombre]) << lsb) & m)
    return w & 0xFFFF


# ---------- estado de la planta simulada ----------
class Planta:
    def __init__(self, mmap, n_tcu, n_hsu, averias, ext, semilla=7):
        self.m, self.n_tcu, self.n_hsu, self.ext = mmap, n_tcu, n_hsu, ext
        self.rnd = random.Random(semilla)
        # las averías son deterministas: el mismo --semilla da los mismos TCU tocados
        self.mudos = set(self.rnd.sample(range(1, n_tcu + 1), min(averias, n_tcu)))
        self.t0 = time.time()

    def hora_del_dia(self):
        lt = time.localtime()
        return lt.tm_hour + lt.tm_min / 60.0

    def angulo(self, i):
        """Curva de seguimiento: ±55° entre las 6 y las 20, plano de noche. Con un desfase
           pequeño por TCU para que no salgan los 200 clavados, que oculta errores de índice."""
        h = self.hora_del_dia()
        if h < 6 or h > 20:
            return 0.0
        a = -55.0 + 110.0 * (h - 6) / 14.0
        return a + math.sin(i * 0.7) * 0.8

    def soc(self, i):
        h = self.hora_del_dia()
        base = 55 + 40 * math.sin(math.pi * max(0.0, min(1.0, (h - 6) / 14.0)))
        return max(5, min(100, int(base - (i % 7))))

    # ---- bloque de 22 registros de un TCU ----
    def bloque_tcu(self, i, wo):
        f = self.m["tcu_compat"]["fields"]
        regs = [0] * self.m["tcu_compat"]["stride"]
        mudo = i in self.mudos
        ang = self.angulo(i)
        soc = 12 if mudo else self.soc(i)

        def campos(off):
            return {int(k): v for k, v in f.items()}[off].get("bits", {})

        regs[1] = pon_bits(0, campos(1), {"bt_active": 1 if 9 < self.hora_del_dia() < 17 else 0,
                                          "sleep_state": 0, "day_time": 1 if 6 < self.hora_del_dia() < 20 else 0,
                                          "main_state": 0 if mudo else 2, "safe_position": 0})
        a1 = 0
        if soc < 20:
            a1 |= 1 << 13                      # batt_low (L1)
        if mudo:
            a1 |= 1 << 8                       # zigbee_fail
        regs[2] = a1
        regs[3] = (1 << 8) if mudo else 0      # axis_blocked
        regs[4] = pon_bits(0, campos(4), {"west_limit": 0, "east_limit": 0,
                                          "motor_locked": 1 if mudo else 0, "system_ok": 0 if mudo else 1})
        regs[5] = 0 if mudo else int(11000 + 900 * math.sin(i))         # panel_voltage mV
        regs[6], regs[7] = f32_regs(math.radians(ang), wo)              # tilt_angle (rad)
        regs[8] = 0 if mudo else int(300 + 200 * abs(math.sin(i * 1.3)))
        regs[9] = 0 if mudo else int(900 + 500 * abs(math.cos(i * 1.1)))
        regs[10], regs[11] = f32_regs(math.radians(ang), wo)            # target_angle (rad)
        regs[12] = s16_reg(0 if mudo else 120)
        regs[13] = soc & 0xFF                                            # u8_low
        regs[16] = int(12800 + soc * 8)                                  # battery_voltage mV
        regs[18] = s16_reg(0 if mudo else (400 if 8 < self.hora_del_dia() < 16 else -260))
        regs[19] = int((291.15 + 6 * math.sin(i)) * 10)                  # temp_pcb Kx10
        regs[20] = int((290.15 + 4 * math.cos(i)) * 10)                  # temp_battery Kx10
        regs[21] = max(70, 100 - (i % 25))                               # soh
        return regs

    def lastcomm_tcu(self, i):
        # los mudos llevan 45 min sin hablar: es lo que dispara comms_age_s en el colector
        return int(time.time()) - (2700 if i in self.mudos else self.rnd.randint(2, 40))

    # ---- bloque de 10 registros de una HSU ----
    def bloque_hsu(self, i, wo):
        h = self.m["hsu"]
        regs = [0] * h["stride"]
        f = {int(k): v for k, v in h["fields"].items()}
        viento = 3.0 + 5.0 * abs(math.sin(time.time() / 900 + i))
        nivel = 0 if viento < 8 else (1 if viento < 12 else 2)
        regs[1] = pon_bits(0, f[1].get("bits", {}), {"wind_level": nivel, "wind_dir_east": i % 2})
        regs[2] = pon_bits(0, f[2].get("bits", {}), {"alarm_wind": 1 if nivel >= 2 else 0})
        regs[3], regs[4] = f32_regs(viento, wo)
        regs[5], regs[6] = f32_regs((i * 37 + time.time() / 60) % 360, wo)
        regs[7], regs[8] = f32_regs(0.0, wo)
        return regs

    def bloque_hsu_ext(self, i, wo):
        e = self.m["hsu_ext"]
        regs = [0] * e["stride"]
        h = self.hora_del_dia()
        ghi = max(0.0, 950 * math.sin(math.pi * max(0.0, min(1.0, (h - 6) / 14.0))))
        viento = 3.0 + 5.0 * abs(math.sin(time.time() / 900 + i))
        regs[4], regs[5] = f32_regs(viento, wo)
        regs[6], regs[7] = f32_regs((i * 37) % 360, wo)
        regs[8], regs[9] = f32_regs(0.0, wo)
        regs[16] = 13200
        regs[21], regs[22] = u32_regs(int(ghi * 100), wo)
        regs[23], regs[24] = u32_regs(int(ghi * 1.12 * 100), wo)
        regs[25], regs[26] = u32_regs(int(ghi * 0.18 * 100), wo)
        return regs

    # ---- registros propios de la NCU ----
    def regs_ncu(self, wo):
        r = self.m["ncu"]["registers"]
        out = {}
        out[r["hsu_global"]["addr"]] = pon_bits(0, r["hsu_global"]["bits"],
                                                {"alarm_any_wind": 0, "wind_highest_level": 1})
        out[r["digital_input"]["addr"]] = pon_bits(0, r["digital_input"]["bits"],
                                                  {"battery_low": 0, "ups_power_fault": 0,
                                                   "cleaning_switch_1": 1, "stop_button": 0})
        out[r["main_status"]["addr"]] = pon_bits(0, r["main_status"]["bits"], {"gw1_alarm": 0})
        hi, lo = u32_regs(int(time.time()), wo)
        out[r["date_time"]["addr"]] = hi
        out[r["date_time"]["addr"] + 1] = lo
        return out


def construye(planta, wo):
    """Vuelca toda la planta en un dict {direccion: valor} con las direcciones ABSOLUTAS
       del mapa, que es como las pide el colector (30500, 29500, 30200, 28000…)."""
    m, vals = planta.m, {}
    tc = m["tcu_compat"]
    for i in range(1, planta.n_tcu + 1):
        base = tc["base"] + (i - 1) * tc["stride"]
        for k, v in enumerate(planta.bloque_tcu(i, wo)):
            vals[base + k] = v
        lc = m["tcu_lastcomm"]["base"] + (i - 1) * 2
        hi, lo = u32_regs(planta.lastcomm_tcu(i), wo)
        vals[lc], vals[lc + 1] = hi, lo
    h = m["hsu"]
    for i in range(1, planta.n_hsu + 1):
        base = h["base"] + (i - 1) * h["stride"]
        for k, v in enumerate(planta.bloque_hsu(i, wo)):
            vals[base + k] = v
        lc = h["lastcomm_base"] + (i - 1) * 2
        hi, lo = u32_regs(int(time.time()) - 5, wo)
        vals[lc], vals[lc + 1] = hi, lo
        if planta.ext:
            e = m["hsu_ext"]
            eb = e["base"] + (i - 1) * e["stride"]
            for k, v in enumerate(planta.bloque_hsu_ext(i, wo)):
                vals[eb + k] = v
    vals.update(planta.regs_ncu(wo))
    return vals


# ---------- servidor Modbus TCP, escrito a mano ----------
# NO se usa el almacen de datos de pymodbus a proposito. Su API cambia entre versiones (en la 3.9
# ModbusSlaveContext paso a ModbusDeviceContext y en la 3.14 los bloques ya no tienen setValues y
# quedan deprecados a favor de SimData/SimDevice), y ademas su mapeo de direcciones arrastra el
# off-by-one clasico de Modbus. Para servir FC03/FC04 de solo lectura el protocolo es pequeno, asi
# que se implementa aqui: cero dependencias, y la direccion se sirve 1:1 tal como la pide el
# colector, que es lo que hace la NCU real (sondeo de El Burgo: 30000 responde como 30000).
class Servidor:
    def __init__(self, planta, args):
        self.planta, self.args, self.vals = planta, args, {}
        self.refresca()

    def refresca(self):
        self.vals = construye(self.planta, self.args.word_order)

    async def cliente(self, lector, escritor):
        try:
            while True:
                cab = await lector.readexactly(7)                 # MBAP
                tid, pid, largo, uid = struct.unpack(">HHHB", cab)
                cuerpo = await lector.readexactly(largo - 1)
                fc = cuerpo[0]
                if fc in (3, 4) and len(cuerpo) >= 5:
                    dir0, n = struct.unpack(">HH", cuerpo[1:5])
                    if n < 1 or n > 125:
                        pdu = bytes([fc | 0x80, 3])               # cantidad ilegal
                    elif uid != self.args.unit:
                        pdu = bytes([fc | 0x80, 11])              # esa unidad no existe
                    else:
                        datos = b"".join(struct.pack(">H", self.vals.get(dir0 + k, 0) & 0xFFFF)
                                         for k in range(n))
                        pdu = bytes([fc, len(datos)]) + datos
                else:
                    pdu = bytes([fc | 0x80, 1])                   # funcion no admitida
                escritor.write(struct.pack(">HHHB", tid, pid, len(pdu) + 1, uid) + pdu)
                await escritor.drain()
        except (asyncio.IncompleteReadError, ConnectionResetError, BrokenPipeError):
            pass
        finally:
            escritor.close()


async def sirve(args, mmap):
    planta = Planta(mmap, args.tcus, args.hsus, args.averias, args.ext, args.semilla)
    srv = Servidor(planta, args)
    servidor = await asyncio.start_server(srv.cliente, args.host, args.port)
    print(f"NCU simulada en {args.host}:{args.port} · unit {args.unit} · "
          f"{args.tcus} TCU ({len(planta.mudos)} sin responder: {sorted(planta.mudos) or '—'}) · "
          f"{args.hsus} HSU{' + extendido' if args.ext else ''} · orden de palabra {args.word_order} · "
          f"{len(srv.vals)} registros servidos")
    print(f"Apunta el colector con:  ncus: [{{host: {args.host}, port: {args.port}, "
          f"unit_id: {args.unit}, tcu_count: {args.tcus}}}]")

    async def latido():
        while True:
            await asyncio.sleep(args.periodo)
            srv.refresca()

    asyncio.create_task(latido())
    async with servidor:
        await servidor.serve_forever()


async def autotest(args, mmap):
    """Arranca la simulada y le mete el DRIVER DE HIERRO por delante. Si esto pasa, el camino
       entero (Modbus -> troceado -> decode) funciona; que es lo que drivers/simulated.py no
       llega a tocar nunca."""
    srv = asyncio.create_task(sirve(args, mmap))
    await asyncio.sleep(1.2)
    from drivers.modbus_ncu import ModbusNCUDriver
    d = ModbusNCUDriver({"host": args.host, "port": args.port, "unit_id": args.unit,
                         "tcu_count": args.tcus, "hsu_count": args.hsus,
                         "hsu_extended": args.ext}, mmap, word_order=args.word_order)
    await d.connect()
    fallos = 0

    def ok(c, m):
        nonlocal fallos
        print(("  ok    " if c else "  FALLO ") + m)
        if not c:
            fallos += 1

    trk = await d.read_trackers()
    ok(len(trk) == args.tcus, f"lee los {args.tcus} TCU ({len(trk)})")
    ang = [t["fields"].get("tilt_angle") for t in trk if t["fields"].get("tilt_angle") is not None]
    ok(len(ang) == args.tcus, f"todos traen tilt_angle ({len(ang)})")
    ok(all(-90 <= a <= 90 for a in ang), f"ángulos en rango: {min(ang):.2f}° … {max(ang):.2f}°")
    ok(len(set(round(a, 2) for a in ang)) > 1, "los ángulos NO salen todos iguales (detecta índice mal calculado)")
    socs = [t["fields"].get("soc") for t in trk]
    ok(all(isinstance(s, int) and 0 <= s <= 100 for s in socs), f"SoC 0..100 ({min(socs)}…{max(socs)})")
    tmp = [t["fields"].get("temp_pcb") for t in trk]
    ok(all(-40 <= x <= 90 for x in tmp), f"temp_pcb convertida de K×10 a °C ({min(tmp):.1f}…{max(tmp):.1f})")
    mudos = sorted(t["tcu"] for t in trk if t["comms_age_s"] and t["comms_age_s"] > 600)
    ok(mudos == sorted(Planta(mmap, args.tcus, args.hsus, args.averias, args.ext, args.semilla).mudos),
       f"los TCU averiados salen por comms_age_s: {mudos}")
    ok(any(t["alarms"] for t in trk), "las alarmas se decodifican por nombre: " +
       str(next((t["alarms"] for t in trk if t["alarms"]), [])))

    ncu = await d.read_ncu()
    ok(ncu.get("cleaning_switch_1") == 1, f"el interruptor de limpieza 1 llega hasta el colector ({ncu.get('cleaning_switch_1')})")
    ok(abs(ncu.get("date_time", 0) - time.time()) < 120, "la hora de la NCU (U32 epoch) se recompone bien")

    met = await d.read_meteo()
    ok(len(met) == args.hsus, f"lee las {args.hsus} HSU ({len(met)})")
    ws = met[0]["fields"].get("wind_speed") if met else None
    ok(ws is not None and 0 <= ws <= 60, f"viento en rango ({ws})")
    if args.ext:
        ghi = met[0]["fields"].get("ghi")
        ok(ghi is not None and 0 <= ghi <= 1500, f"bloque extendido (28000): GHI {ghi} W/m²")

    await d.close()
    srv.cancel()
    print("\n" + ("✓ el driver de hierro recorre el camino entero contra la simulada"
                  if not fallos else f"✗ {fallos} FALLOS"))
    return 1 if fallos else 0


def main():
    p = argparse.ArgumentParser(description="Esclavo Modbus TCP que simula una NCU con el mapa real")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=5020)
    p.add_argument("--unit", type=int, default=1)
    p.add_argument("--tcus", type=int, default=200)
    p.add_argument("--hsus", type=int, default=2)
    p.add_argument("--averias", type=int, default=2, help="TCU que dejan de responder")
    p.add_argument("--ext", action="store_true", help="publica también el bloque extendido de HSU (28000)")
    p.add_argument("--periodo", type=float, default=5.0, help="cada cuánto se refrescan los valores (s)")
    p.add_argument("--semilla", type=int, default=7)
    p.add_argument("--word-order", default="big", choices=["big", "little"])
    p.add_argument("--mapa", default=os.path.join(RAIZ, "config", "modbus_map.yml"))
    p.add_argument("--autotest", action="store_true", help="arranca, se lee con el driver real y sale")
    a = p.parse_args()
    mmap = yaml.safe_load(open(a.mapa, encoding="utf-8"))
    if a.autotest:
        sys.exit(asyncio.run(autotest(a, mmap)))
    try:
        asyncio.run(sirve(a, mmap))
    except KeyboardInterrupt:
        print("\nparada")


if __name__ == "__main__":
    main()
