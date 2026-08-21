"""Banco del modo en `health`: la 14·14 en OFF no puede verse igual que un vecino en AUTO.

Reportado en campo: *«la 14·14 sale bien porque está en off, pero coincide que
está en la posición en la que estaban los demás… y no está ok»*.

Lo que hacía el fallo difícil de ver —y lo que este banco fija— es que el modo
SÍ acababa detectándose, pero **de rebote**: una parada en OFF daba `warn`
cuando el sol se movía lo bastante como para separar el ángulo del objetivo. El
aviso llegaba por un síntoma que no era el modo, y **en la coincidencia no
llegaba**. Por eso el caso de referencia de este fichero es el ángulo QUE
COINCIDE: en el otro, el bug no se puede ver.

    python tools/test_health_modo.py
"""
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(RAIZ / "collector"))

from decode import tracker_health, motivo_health, MAIN_STATE   # noqa: E402

FRESCO = 12.0          # comms recientes: no es offline
ok, fallos = 0, []


def chk(nombre, actual, esperado):
    global ok
    if actual == esperado:
        ok += 1
        print(f"  ok    {nombre} = {actual!r}")
    else:
        fallos.append(nombre)
        print(f"  FALLO {nombre}: {actual!r} != {esperado!r}")


def chk_true(nombre, cond, detalle=""):
    global ok
    if cond:
        ok += 1
        print(f"  ok    {nombre}{(' — ' + detalle) if detalle else ''}")
    else:
        fallos.append(nombre)
        print(f"  FALLO {nombre}{(' — ' + detalle) if detalle else ''}")


def tcu(modo=2, tilt=-12.0, target=-12.0, system_ok=1):
    return {"main_state": modo, "main_state_txt": MAIN_STATE.get(modo, "?"),
            "tilt_angle": tilt, "target_angle": target, "system_ok": system_ok}


print("=== el caso de campo: OFF, en la posición en la que estaban los demás ===")
la1414 = tcu(modo=0)                       # OFF, ángulo coincidiendo
vecina = tcu(modo=2)                       # AUTO, mismo ángulo
chk("la 14·14 en OFF ya NO sale ok", tracker_health(la1414, [], FRESCO), "warn")
chk("y dice por qué", motivo_health(la1414, [], FRESCO), "en OFF: no está siguiendo")
chk("la vecina en AUTO sigue en ok", tracker_health(vecina, [], FRESCO), "ok")
chk_true("y ya no son indistinguibles",
         tracker_health(la1414, [], FRESCO) != tracker_health(vecina, [], FRESCO),
         "que es justo lo que se reportó")

print("\n=== el régimen donde el bug NO se podía ver ===")
# Con el ángulo separado, el viejo criterio ya daba warn -- por la razón
# equivocada. Un test escrito aquí habría dado verde CON el bug dentro.
off_desviada = tcu(modo=0, tilt=-12.0, target=25.0)
chk("OFF y desviada: warn, como antes", tracker_health(off_desviada, [], FRESCO), "warn")
chk("pero ahora el motivo es el MODO, no la desviación",
    motivo_health(off_desviada, [], FRESCO), "en OFF: no está siguiendo")

print("\n=== MANUAL tampoco es seguir ===")
chk("MANUAL coincidiendo", tracker_health(tcu(modo=1), [], FRESCO), "warn")
chk("con su motivo", motivo_health(tcu(modo=1), [], FRESCO), "en MANUAL: no está siguiendo")

print("\n=== lo que NO cambia (nada de esto se toca) ===")
chk("AUTO, sin alarmas, en su sitio", tracker_health(tcu(), [], FRESCO), "ok")
chk("AUTO desviada sigue siendo warn", tracker_health(tcu(tilt=-12, target=25), [], FRESCO), "warn")
chk("y por su motivo", motivo_health(tcu(tilt=-12, target=25), [], FRESCO),
    "desviado del objetivo más de 5°")
chk("una alarma crítica manda sobre el modo",
    tracker_health(tcu(modo=0), ["axis_blocked"], FRESCO), "alarm")
chk("y sin comunicación manda sobre todo", tracker_health(tcu(modo=0), [], 9999.0), "offline")
chk("system_ok=0 sigue avisando", tracker_health(tcu(system_ok=0), [], FRESCO), "warn")

print("\n=== firmware que no publica el modo: no se inventa ===")
sin_modo = {"tilt_angle": -12.0, "target_angle": -12.0, "system_ok": 1}
chk("sin `main_state` se clasifica como antes, no como sospechoso",
    tracker_health(sin_modo, [], FRESCO), "ok")

print("\n=== EL MUTANTE: quitar la comprobación del modo ===")
import decode                                                   # noqa: E402
_auto = decode.MAIN_STATE_AUTO
decode.MAIN_STATE_AUTO = 0          # ahora OFF cuenta como "siguiendo"
muerto = tracker_health(la1414, [], FRESCO)
decode.MAIN_STATE_AUTO = _auto
chk_true("con el criterio mutado la 14·14 vuelve a salir ok: el banco mide",
         muerto == "ok", f"mutado = {muerto!r}")

print("\n=== cuánto cambia el color de flota ===")
# El número por el que esto es decisión del mantenedor y no un detalle.
flota = [tcu() for _ in range(105)] + [tcu(modo=0) for _ in range(2)] + [tcu(modo=1)]
antes = sum(1 for f in flota if f.get("main_state") == 2)
cnt = {}
for f in flota:
    cnt[tracker_health(f, [], FRESCO)] = cnt.get(tracker_health(f, [], FRESCO), 0) + 1
print(f"  flota de {len(flota)}: {cnt}")
chk_true("solo cambian de color los que NO están en AUTO",
         cnt.get("warn", 0) == len(flota) - antes,
         f"{len(flota) - antes} pasan de ok a warn; los {antes} en AUTO no se mueven")

print(f"\n{'Todo OK' if not fallos else 'FALLAN ' + str(len(fallos))} ({ok} comprobaciones)")
sys.exit(1 if fallos else 0)
