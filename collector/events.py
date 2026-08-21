"""Histórico de EVENTOS: los flancos, no las muestras (B5-a).

`tracker_status` guarda una muestra cada 30 s. Para "¿qué pasó anoche?" eso es
la pregunta equivocada: hay que barrer 2.880 muestras por TCU para encontrar el
instante en que una pasó de `ok` a `alarm`, y el que la mira acaba deduciendo el
flanco a ojo sobre una gráfica. Un evento es ese flanco, escrito UNA vez.

Tres decisiones que son el fichero entero:

**1. La hora es la del DATO, no la de guardarlo.** Cada punto lleva `.time()`
explícito. Sin él InfluxDB sella con la hora de ESCRITURA, y no es lo mismo: el
ciclo puede reintentar tras un backoff, la NCU puede tardar, y entonces el
flanco queda archivado minutos después de ocurrir — justo en el incidente donde
el orden de los sucesos es lo único que se está mirando. Es la misma lección de
la toolbox v11.59 (#206) en el otro extremo del sistema.

Y con ella, la que la hace honesta: **un flanco visto por muestreo no se conoce
mejor que el periodo de muestreo**. Sabemos que ocurrió ENTRE dos ciclos, no
cuándo. Se sella en el ciclo que lo detecta y se publica `res_s` con el periodo,
para que nadie lea una precisión que no existe. Fingir el instante exacto sería
inventar dato; no decir nada, dejar que se lo inventen.

**2. Ámbitos REALES.** Una alarma de viento es de la NCU: ocurre UNA vez, no 108
veces. Replicarla por TCU seria multiplicar por 108 un suceso que no lo es —
falso en el histórico y caro en la nube. Cada evento se escribe en el ámbito
donde de verdad ocurre, y el `tcu` solo se etiqueta cuando el ámbito es el TCU:
en InfluxDB una etiqueta vacía no es lo mismo que una ausente.

**3. El primer ciclo NO es un flanco.** Al arrancar (o tras reconectar) no hay
estado anterior, y tratar la primera lectura como un cambio llenaría el
histórico de 108 transiciones falsas con la hora del arranque del colector —
que es exactamente el ruido que enterraría los eventos de verdad. Sin estado
previo se aprende, no se emite.
"""
from influxdb_client import Point

#: Bits de la NCU que son SUCESOS de planta. `date_time` no está: es un reloj,
#: cambia en cada ciclo por definición y no es un flanco de nada.
NCU_SUCESOS = ("alarm_any_wind", "alarm_any_snow", "gw1_alarm", "gw2_alarm",
               "battery_low", "ups_power_fault", "alarm_battery_low", "stop_button")
#: Lo mismo para una estación meteo.
HSU_SUCESOS = ("alarm_wind", "alarm_snow", "alarm_com", "alarm_flood",
               "wind_sensor_fail", "snow_sensor_fail")


class RegistroEventos:
    """Compara el ciclo con el anterior y emite un punto por flanco."""

    def __init__(self, plant_id: str, ncu_id: str, interval_s: float):
        self.plant = plant_id
        self.ncu = ncu_id
        self.res_s = float(interval_s)
        self._prev = None          # None = todavía no hay con qué comparar

    # -- construcción de un punto -------------------------------------------
    def _punto(self, ambito: str, tipo: str, de, a, ts, tcu=None, hsu=None, detalle=None):
        p = (Point("event")
             .tag("plant", self.plant).tag("ncu", self.ncu)
             .tag("scope", ambito)        # "tcu" | "ncu" | "hsu"
             .tag("kind", tipo))
        # La etiqueta del equipo SOLO en su ámbito: una etiqueta vacía crearía
        # una serie distinta de la que no la lleva, y ensuciaría el histórico.
        if tcu is not None:
            p.tag("tcu", str(tcu))
        if hsu is not None:
            p.tag("hsu", str(hsu))
        p.field("from", "" if de is None else str(de))
        p.field("to", "" if a is None else str(a))
        p.field("res_s", self.res_s)     # resolución del flanco, ver cabecera
        if detalle:
            p.field("detail", str(detalle))
        return p.time(ts)                # <- la hora del DATO, explícita

    # -- API ----------------------------------------------------------------
    def flancos(self, trackers, ncu_status, meteo, ts):
        """Puntos de los flancos de este ciclo. `ts` es un datetime con zona.

        Devuelve [] en el primer ciclo, a propósito: ver la cabecera.
        """
        ahora = self._instantanea(trackers, ncu_status, meteo)
        if self._prev is None:
            self._prev = ahora
            return []
        ev = []
        ev += self._flancos_tcu(self._prev["tcu"], ahora["tcu"], ts)
        ev += self._flancos_bits("ncu", self._prev["ncu"], ahora["ncu"], ts)
        for hsu in sorted(set(self._prev["hsu"]) | set(ahora["hsu"])):
            ev += self._flancos_bits("hsu", self._prev["hsu"].get(hsu, {}),
                                     ahora["hsu"].get(hsu, {}), ts, hsu=hsu)
        self._prev = ahora
        return ev

    # -- interno ------------------------------------------------------------
    @staticmethod
    def _instantanea(trackers, ncu_status, meteo):
        return {
            "tcu": {t["tcu"]: {"health": t["health"],
                               "alarms": frozenset(t["alarms"]),
                               "modo": t["fields"].get("main_state_txt")}
                    for t in trackers},
            "ncu": {k: v for k, v in (ncu_status or {}).items() if k in NCU_SUCESOS},
            "hsu": {m["hsu"]: {k: v for k, v in m["fields"].items() if k in HSU_SUCESOS}
                    for m in (meteo or [])},
        }

    def _flancos_tcu(self, antes, ahora, ts):
        ev = []
        for tcu in sorted(set(antes) | set(ahora)):
            a, b = antes.get(tcu), ahora.get(tcu)
            if a is None or b is None:
                # Un TCU que aparece o desaparece del barrido no es un flanco de
                # salud: es un cambio de INVENTARIO, y se dice como tal.
                ev.append(self._punto("tcu", "inventario", "presente" if a else "ausente",
                                      "presente" if b else "ausente", ts, tcu=tcu))
                continue
            if a["health"] != b["health"]:
                ev.append(self._punto("tcu", "health", a["health"], b["health"], ts, tcu=tcu))
            if a["modo"] != b["modo"]:
                ev.append(self._punto("tcu", "modo", a["modo"], b["modo"], ts, tcu=tcu))
            # Cada alarma va por separado, con su nombre: "aparecieron dos
            # alarmas" no se puede filtrar, "axis_blocked entró" sí.
            for al in sorted(b["alarms"] - a["alarms"]):
                ev.append(self._punto("tcu", "alarma", "no", "si", ts, tcu=tcu, detalle=al))
            for al in sorted(a["alarms"] - b["alarms"]):
                ev.append(self._punto("tcu", "alarma", "si", "no", ts, tcu=tcu, detalle=al))
        return ev

    def _flancos_bits(self, ambito, antes, ahora, ts, hsu=None):
        ev = []
        for k in sorted(set(antes) | set(ahora)):
            a, b = antes.get(k), ahora.get(k)
            if a != b and a is not None and b is not None:
                ev.append(self._punto(ambito, k, a, b, ts, hsu=hsu))
        return ev
