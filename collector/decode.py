"""Decodificación de registros Modbus del bloque TCU Compat y HSU.

Convierte listas de registros U16 crudos en dicts de campos físicos
según config/modbus_map.yml. Independiente del transporte: lo usan
tanto el driver Modbus real como los tests.
"""
import math
import struct


def u16_to_s16(v: int) -> int:
    return v - 65536 if v >= 32768 else v


def regs_to_f32(hi: int, lo: int, word_order: str = "big") -> float:
    """Dos registros U16 -> float IEEE754. word_order='big': primer registro = palabra alta."""
    if word_order == "little":
        hi, lo = lo, hi
    raw = struct.pack(">HH", hi, lo)
    return struct.unpack(">f", raw)[0]


def regs_to_u32(hi: int, lo: int, word_order: str = "big") -> int:
    if word_order == "little":
        hi, lo = lo, hi
    return (hi << 16) | lo


def regs_to_s32(hi: int, lo: int, word_order: str = "big") -> int:
    v = regs_to_u32(hi, lo, word_order)
    return v - 0x100000000 if v >= 0x80000000 else v


def extract_bits(value: int, lsb: int, msb: int) -> int:
    width = msb - lsb + 1
    return (value >> lsb) & ((1 << width) - 1)


MAIN_STATE = {0: "OFF", 1: "MANUAL", 2: "AUTO"}
#: El único modo en el que un seguidor está SIGUIENDO. Con nombre para que
#: `tracker_health()` no lleve un 2 suelto que nadie sepa leer dentro de un año.
MAIN_STATE_AUTO = 2


def decode_tcu_block(regs: list[int], field_map: dict, word_order: str = "big") -> dict:
    """Decodifica los 22 registros de un TCU (bloque compat) -> dict de campos."""
    out = {}
    for offset, spec in field_map.items():
        offset = int(offset)
        t = spec["type"]
        name = spec["name"]
        if t == "u16":
            val = regs[offset]
        elif t == "s16":
            val = u16_to_s16(regs[offset])
        elif t == "u8_low":
            val = regs[offset] & 0xFF
        elif t == "f32":
            val = regs_to_f32(regs[offset], regs[offset + 1], word_order)
            if spec.get("to_deg"):
                val = math.degrees(val)
            val = round(val, 2)
        # s32/u32 se caían por el `else: continue` de abajo, EN SILENCIO. Con ello, las tres
        # irradiancias del bloque extendido de la HSU (ghi, poa_tracking, poa_diffuse, que el mapa
        # declara s32 Wm2x100) no llegaban nunca al colector: el campo no salía y nadie se enteraba.
        elif t == "s32":
            val = regs_to_s32(regs[offset], regs[offset + 1], word_order)
        elif t == "u32":
            val = regs_to_u32(regs[offset], regs[offset + 1], word_order)
        else:
            continue
        if spec.get("to_celsius"):  # Kx10 -> °C
            val = round(val / 10.0 - 273.15, 1)
        if spec.get("scale"):
            val = round(val * spec["scale"], 2)
        out[name] = val
        # subcampos de bits
        for bit_name, (lsb, msb) in spec.get("bits", {}).items():
            out[bit_name] = extract_bits(regs[offset], lsb, msb)
    if "main_state" in out:
        out["main_state_txt"] = MAIN_STATE.get(out["main_state"], "?")
    return out


def decode_alarms(alarms1: int, alarms2: int, alarm_bits: dict) -> list[str]:
    """Registros de alarma -> lista de nombres de alarmas activas."""
    active = []
    for reg_val, key in ((alarms1, "alarms1"), (alarms2, "alarms2")):
        for bit, name in alarm_bits.get(key, {}).items():
            if reg_val & (1 << int(bit)):
                active.append(name)
    return active


#: EL RESIDUO CONTRA VECINOS: qué ve, y qué NO ve aunque apetezca decir que sí.
#:
#: `tilt_angle` vs `target_angle` son los dos valores que publica el MISMO
#: equipo, y el lazo cierra sobre la medida. O sea que mide si el seguidor
#: ALCANZA su consigna, y nada sobre si la consigna es la correcta. Esa segunda
#: pregunta está hoy sin vigilar, y es la que mira esto: a la misma marca de
#: tiempo, todas las TCU de una NCU persiguen el mismo θ salvo por el terreno.
#:
#:   · fallo de LAZO       no llega a su consigna        -> tilt vs target (ya estaba)
#:   · fallo de CONSIGNA   la alcanza, pero es la de
#:                         otro instante o de otro sitio -> tilt vs VECINOS (esto)
#:
#: El caso que lo justifica y que hoy sale VERDE: una TCU cuyo seguimiento se
#: queda congelado —objetivo clavado en el de hace tres horas— lo persigue
#: fielmente, así que |tilt − target| ~ 0 y el mapa la pinta en verde mientras
#: sus vecinas están 17° más allá. También lo ve con una TCU cuyas coordenadas,
#: límites mecánicos o reloj propio divergen de los de su NCU, o con un forzado
#: viejo que nadie retiró.
#:
#: LO QUE NO VE, Y VA DICHO PORQUE ES TENTADOR CREER LO CONTRARIO: un sesgo de
#: calibración del encoder. Si la medida es m = real + sesgo y el lazo lleva m
#: hasta el objetivo T, entonces m ~ T en TODAS, también en la descalibrada: su
#: ángulo PUBLICADO coincide con el de sus vecinas y lo que difiere es el real,
#: que no se publica. Ningún residuo calculado sobre los datos del equipo puede
#: verlo —es el mismo dato que el lazo ya absorbió—, y por eso el ensayo D.1.1
#: del Anexo 4 pide instrumento externo. Esto no sustituye a ese ensayo.
#:
#: UMBRAL ABSOLUTO EN GRADOS, Y NO UNA z ROBUSTA, a propósito: con vecinos casi
#: idénticos la MAD tiende a cero y una diferencia de 0,01° sale como «3 sigma»
#: —significativo en estadística, irrelevante en campo—. Lo que decide aquí es
#: la relevancia práctica: cuántos grados justifican coger la furgoneta.
#:
#: 3,0° NO ESTÁ MEDIDO SOBRE ESTA PLANTA, y queda dicho en vez de disfrazado: es
#: el orden de magnitud que documenta el simulador de planta, no la dispersión
#: por terreno observada aquí. Para fijarlo de verdad hay que medir la dispersión
#: de la propia flota en una ventana sin averías y poner el umbral por encima de
#: ella. Mientras no se haga, un terreno muy quebrado puede dar avisos de más — y
#: por eso esto es `warn` y nunca `alarm`.
DESVIO_VECINOS_DEG = 3.0

#: Con dos o tres vecinos la mediana no es una referencia, es una opinión. Por
#: debajo de esto NO se juzga: el residuo devuelve None y la clasificación se
#: comporta igual que antes de existir.
MIN_VECINOS_COMPARABLES = 4


def comparable_como_referencia(fields: dict, alarms: list[str], comms_age_s: float | None,
                               stale_after_s: float = 300) -> bool:
    """¿Sirve el ángulo de este TCU para decir dónde DEBERÍA estar la flota?

    Solo si está siguiendo de verdad. Uno parado en OFF, sin comunicación o con
    una alarma está donde está por otra razón, y meterlo en la mediana la
    envenena: sería comparar a los sanos contra un parado.
    """
    if comms_age_s is None or comms_age_s > stale_after_s:
        return False
    if alarms:
        return False
    if not fields.get("system_ok", 1):
        return False
    if fields.get("main_state") != MAIN_STATE_AUTO:
        return False
    return fields.get("tilt_angle") is not None


def mediana(valores: list[float]) -> float | None:
    """Mediana y no media: con una descalibrada dentro, la media se va con ella."""
    xs = sorted(v for v in valores if v is not None)
    if not xs:
        return None
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2.0


def desvios_entre_vecinos(trackers: list[dict], stale_after_s: float = 300) -> dict:
    """{tcu: grados que su ángulo se separa de la mediana de SUS vecinos}.

    `trackers` son los TCU de UNA NCU en UN ciclo —misma marca de tiempo—, que
    es la única comparación que significa algo: el sol es el mismo para todos.

    El propio TCU se excluye de su referencia. Con la mediana no haría mucha
    falta, pero así «desvío contra los vecinos» quiere decir exactamente eso.
    Devuelve None para los que no se pueden juzgar, y None no es cero.
    """
    refs = [(t.get("tcu"), t["fields"].get("tilt_angle")) for t in trackers
            if comparable_como_referencia(t["fields"], t.get("alarms", []),
                                          t.get("comms_age_s"), stale_after_s)]
    out = {}
    for t in trackers:
        tcu = t.get("tcu")
        tilt = t["fields"].get("tilt_angle")
        vecinos = [a for (k, a) in refs if k != tcu]
        if tilt is None or len(vecinos) < MIN_VECINOS_COMPARABLES:
            out[tcu] = None
            continue
        ref = mediana(vecinos)
        out[tcu] = None if ref is None else round(tilt - ref, 2)
    return out


def tracker_health(fields: dict, alarms: list[str], comms_age_s: float | None,
                   stale_after_s: float = 300,
                   desvio_vecinos: float | None = None) -> str:
    """Clasifica el estado para el mapa: ok / warn / alarm / offline.

    `desvio_vecinos` lo calcula `desvios_entre_vecinos()` sobre la flota de una
    NCU; aquí llega ya resuelto porque esta función ve UN seguidor y la
    referencia son los otros. None = no se ha podido juzgar, y entonces esto se
    comporta exactamente como antes de que el residuo existiera.
    """
    if comms_age_s is None or comms_age_s > stale_after_s:
        return "offline"
    critical = {"axis_blocked", "motor_overcurrent_hw", "motor_overcurrent_sw",
                "batt_critical", "stop_button", "out_of_range"}
    if any(a in critical for a in alarms):
        return "alarm"
    if alarms or not fields.get("system_ok", 1):
        return "warn"
    # EL MODO, y va ANTES que la desviación por un motivo.
    #
    # Un seguidor que no está en AUTO no está siguiendo, tenga el ángulo que
    # tenga. Y el modo no estaba mirándose: se decodifica, se guarda y se sirve
    # en `/live`, pero la clasificación lo ignoraba. Reportado en campo sobre la
    # 14·14 — «sale bien porque está en off, pero coincide que está en la
    # posición en la que estaban los demás… y no está ok».
    #
    # Lo que hacía el fallo difícil de ver es que el modo SÍ se detectaba, pero
    # de rebote: una parada en OFF acababa dando `warn` cuando el sol se movía
    # lo bastante como para separar el ángulo del objetivo. O sea que el aviso
    # llegaba por un síntoma que no era el modo, y **cuando la coincidencia se
    # daba, silencio** — verde exactamente igual que el vecino que sí sigue.
    #
    # Es `warn` y no `alarm` a propósito: parar un seguidor en OFF o MANUAL es
    # una operación legítima de mantenimiento. Lo que no es legítimo es que en
    # el mapa se vea igual que uno operando.
    modo = fields.get("main_state")
    if modo is not None and modo != MAIN_STATE_AUTO:
        return "warn"
    # Desviación ángulo real vs objetivo. Solo dice algo en AUTO: sin mando, el
    # objetivo no se persigue y la comparación no mide seguimiento.
    tilt, target = fields.get("tilt_angle"), fields.get("target_angle")
    if tilt is not None and target is not None and abs(tilt - target) > 5.0:
        return "warn"
    # LA REFERENCIA, y va DESPUÉS del lazo a propósito. Si además de desviarse de
    # sus vecinos no llega a su objetivo, lo que lo explica es el lazo: ése es el
    # motivo más concreto y el que ya se daba. Lo que este orden añade es
    # exactamente el caso que no se veía — EN su objetivo y fuera de sus
    # vecinos—, así que esta línea solo puede convertir un `ok` en `warn` y no
    # puede cambiar ningún veredicto anterior.
    if desvio_vecinos is not None and abs(desvio_vecinos) > DESVIO_VECINOS_DEG:
        return "warn"
    return "ok"


def motivo_health(fields: dict, alarms: list[str], comms_age_s: float | None,
                  stale_after_s: float = 300,
                  desvio_vecinos: float | None = None) -> str:
    """Por qué salió ese `health`. Un color sin motivo obliga a adivinar.

    Mismo orden de decisión que `tracker_health()` — y a propósito NO reimplanta
    el criterio: pregunta por el estado y luego dice cuál de las condiciones lo
    explica, así no pueden separarse.
    """
    estado = tracker_health(fields, alarms, comms_age_s, stale_after_s, desvio_vecinos)
    if estado == "offline":
        return "sin comunicación" if comms_age_s is not None else "sin marca de comunicación"
    if estado == "alarm":
        return "alarma crítica: " + ", ".join(alarms)
    if estado == "warn":
        if alarms:
            return "alarma: " + ", ".join(alarms)
        if not fields.get("system_ok", 1):
            return "system_ok = 0"
        modo = fields.get("main_state")
        if modo is not None and modo != MAIN_STATE_AUTO:
            return f"en {MAIN_STATE.get(modo, '?')}: no está siguiendo"
        tilt, target = fields.get("tilt_angle"), fields.get("target_angle")
        if tilt is not None and target is not None and abs(tilt - target) > 5.0:
            return "desviado del objetivo más de 5°"
        return (f"en su objetivo pero {abs(desvio_vecinos):.1f}° fuera de sus vecinos: "
                "persigue una consigna distinta (¿seguimiento congelado, reloj o "
                "configuración divergente?)")
    return "en AUTO, sin alarmas y en su objetivo"
