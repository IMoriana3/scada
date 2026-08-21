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


def tracker_health(fields: dict, alarms: list[str], comms_age_s: float | None,
                   stale_after_s: float = 300) -> str:
    """Clasifica el estado para el mapa: ok / warn / alarm / offline."""
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
    return "ok"


def motivo_health(fields: dict, alarms: list[str], comms_age_s: float | None,
                  stale_after_s: float = 300) -> str:
    """Por qué salió ese `health`. Un color sin motivo obliga a adivinar.

    Mismo orden de decisión que `tracker_health()` — y a propósito NO reimplanta
    el criterio: pregunta por el estado y luego dice cuál de las condiciones lo
    explica, así no pueden separarse.
    """
    estado = tracker_health(fields, alarms, comms_age_s, stale_after_s)
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
        return "desviado del objetivo más de 5°"
    return "en AUTO, sin alarmas y en su objetivo"
