"""Driver simulado: genera telemetría realista sin hierro.

Ángulos según posición solar real (pvlib, con backtracking aproximado),
SoC con ciclo día/noche, alarmas aleatorias de baja probabilidad y
algunos TCUs deliberadamente offline. Sirve para desarrollar frontend
y validar todo el pipeline antes de conectar a una NCU real.
"""
import math
import random
import time
from datetime import datetime, timezone

from drivers.modbus_ncu import NCUDriver
from traffic import split_reads

try:
    import pvlib
    import pandas as pd
    HAS_PVLIB = True
except ImportError:
    HAS_PVLIB = False

LAT, LON = 41.65, -0.88  # Zaragoza aprox


def solar_tracker_angle(when: datetime) -> float:
    """Ángulo de un tracker N-S horizontal con backtracking, en grados."""
    if HAS_PVLIB:
        times = pd.DatetimeIndex([when])
        sp = pvlib.solarposition.get_solarposition(times, LAT, LON)
        tr = pvlib.tracking.singleaxis(
            sp["apparent_zenith"], sp["azimuth"],
            axis_azimuth=180, max_angle=55, backtrack=True, gcr=0.35,
        )
        ang = tr["tracker_theta"].iloc[0]
        return 0.0 if math.isnan(ang) else float(ang)
    # fallback sin pvlib: senoide diurna
    h = when.hour + when.minute / 60
    if h < 7 or h > 21:
        return 0.0
    return -55 * math.cos((h - 7) / 14 * math.pi)


class SimulatedNCUDriver(NCUDriver):
    def __init__(self, ncu_cfg, mmap, word_order="big", meter=None, max_regs=110, **_):
        super().__init__(ncu_cfg, mmap, word_order, meter)
        self.max_regs = max_regs
        n = ncu_cfg["tcu_count"]
        rnd = random.Random(hash(ncu_cfg["id"]))
        self.offline = set(rnd.sample(range(1, n + 1), max(1, n // 50)))
        self.lagging = set(rnd.sample(range(1, n + 1), max(1, n // 40)))
        self.alarmed = {rnd.randint(1, n): "axis_blocked"}

    async def connect(self):
        self._count_connection()

    async def close(self): pass

    def _count_span(self, count):
        """Contabiliza el troceo que HARÍA el driver real para esa lectura.

        Sin esto el medidor de tráfico solo serviría con hierro delante; así se
        puede dimensionar una planta con el stack en simulado.
        """
        for n in split_reads(count, self.max_regs):
            self._count_read(n)

    async def read_trackers(self) -> list[dict]:
        n = self.cfg["tcu_count"]
        self._count_span(n * self.mmap["tcu_compat"]["stride"])   # bloque compat
        self._count_span(n * 2)                                   # lastComm (U32/TCU)
        now = datetime.now(timezone.utc)
        base_angle = solar_tracker_angle(now)
        day = 7 <= now.hour + 1 <= 21
        out = []
        ahora = time.time()
        # `tcu_lastcomm` lo escribe LA NCU con SU reloj, no el host. Y lo escribe
        # SIEMPRE: el hierro tiene su hora la lea el colector o no. Por eso sale
        # de `_reloj_ncu()` y no de `self.ncu_clock`, que es lo que el COLECTOR
        # sabe -- confundir las dos cosas dejaba el simulado incapaz de
        # reproducir el bug que este driver existe para poder probar.
        reloj = self._reloj_ncu()
        for i in range(1, self.cfg["tcu_count"] + 1):
            if i in self.offline:
                lc = int(reloj) - 7200
                edad, skew, origen = self.edad_comms(lc, ahora)
                out.append({"tcu": i, "fields": {}, "alarms": [], "last_comm": lc,
                            "comms_age_s": edad, "comms_age_src": origen, "skew_s": skew})
                continue
            jitter = random.uniform(-0.4, 0.4)
            tilt = base_angle + jitter
            target = base_angle
            alarms = []
            if i in self.alarmed:
                alarms = [self.alarmed[i]]
                tilt = 0.0  # bloqueado en horizontal
            elif i in self.lagging:
                tilt = base_angle * 0.7  # se queda atrás -> warn por desviación
            soc = 85 + 10 * math.sin(now.hour / 24 * 2 * math.pi) + random.uniform(-2, 2)
            fields = {
                "tilt_angle": round(tilt, 2),
                "target_angle": round(target, 2),
                "main_state": 2, "main_state_txt": "AUTO",
                "bt_active": int(day and abs(base_angle) > 40),
                "day_time": int(day),
                "safe_position": 0,
                "soc": round(max(10, min(100, soc))),
                "soh": 97,
                "battery_voltage": random.randint(12600, 13400),
                "battery_current": random.randint(-300, 800),
                "temp_battery": round(random.uniform(15, 35), 1),
                "temp_pcb": round(random.uniform(20, 45), 1),
                "motor_current": random.randint(0, 1200) if day else 0,
                "panel_voltage": random.randint(17000, 21000) if day else 0,
                "system_ok": 0 if alarms else 1,
                "alarms1": 0, "alarms2": 0,
            }
            lc = int(reloj) - int(random.uniform(0, 25))
            edad, skew, origen = self.edad_comms(lc, ahora)
            out.append({"tcu": i, "fields": fields, "alarms": alarms, "last_comm": lc,
                        "comms_age_s": edad, "comms_age_src": origen, "skew_s": skew})
        return out

    def _reloj_ncu(self) -> int:
        """La hora que marca ESTA NCU. `ncu_skew_s` en la config la desvía, que
        es el caso que daba la flota entera por offline (positivo = atrasada)."""
        return int(time.time() - self.cfg.get("ncu_skew_s", 0))

    async def read_ncu(self) -> dict:
        self._count_read(1)   # 30002 (HSU global)
        self._count_read(6)   # 30100..30105
        out = {"alarm_any_wind": 0, "wind_highest_level": 0, "alarm_any_snow": 0,
               "gw1_alarm": 0, "gw2_alarm": 0, "battery_low": 0, "ups_power_fault": 0,
               "date_time": self._reloj_ncu()}
        self.ncu_clock = out["date_time"]
        return out

    async def read_meteo(self) -> list[dict]:
        h = self.mmap["hsu_ext"] if self.cfg.get("hsu_extended") else self.mmap["hsu"]
        for _ in range(self.cfg.get("hsu_count", 0)):
            self._count_read(min(h["stride"], 30))
        return [{"hsu": i + 1, "fields": {
            "wind_speed": round(random.uniform(1, 8), 1),
            "wind_direction": round(random.uniform(0, 360)),
            "snow_level": 0.0, "wind_level": 0,
            "alarm_wind": 0, "alarm_snow": 0, "alarm_com": 0,
        }} for i in range(self.cfg.get("hsu_count", 0))]
