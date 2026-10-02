"""Banco del residuo contra vecinos: una TCU que persigue la consigna de hace tres horas.

`tilt_angle` vs `target_angle` son los dos valores que publica el MISMO equipo, y
el lazo cierra sobre la medida. Mide si el seguidor ALCANZA su consigna, y nada
sobre si la consigna es la correcta. El caso que por eso salía VERDE:

    una TCU con el seguimiento congelado persigue FIELMENTE el objetivo de hace
    tres horas, así que |tilt − target| ~ 0 y el mapa la pinta igual que a sus
    vecinas, que están 17° más allá.

**El caso de referencia de este fichero es el que COINCIDE con su objetivo**: en
cualquier otro, el fallo lo caza ya la desviación de lazo y este banco no
probaría nada. Es la misma elección que hizo `test_health_modo.py` con el ángulo
que coincide, y por el mismo motivo.

LO QUE ESTE BANCO FIJA COMO **NO** DETECTABLE, y es igual de importante: un sesgo
de calibración del encoder. Si la medida es m = real + sesgo y el lazo lleva m
hasta T, entonces m ~ T en todas —también en la descalibrada—, su ángulo
PUBLICADO coincide con el de sus vecinas, y lo que difiere es el real, que no se
publica. Hay una comprobación dedicada a eso: si algún día alguien «arregla» el
residuo para que cace ese caso sobre estos datos, se pondrá roja, porque no se
puede. Ese ensayo es el D.1.1 del Anexo 4 y necesita instrumento externo.

    python tools/test_health_vecinos.py
"""
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(RAIZ / "collector"))

from decode import (tracker_health, motivo_health, desvios_entre_vecinos,       # noqa: E402
                    comparable_como_referencia, mediana,
                    DESVIO_VECINOS_DEG, MIN_VECINOS_COMPARABLES, MAIN_STATE)

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


def tcu(n, tilt, target=None, modo=2, system_ok=1, alarms=None, edad=FRESCO):
    """Un TCU como lo monta el colector. `target=None` -> clavado en su medida,
    que es el régimen de un seguimiento que funciona… o que está congelado."""
    return {"tcu": n, "comms_age_s": edad, "alarms": alarms or [],
            "fields": {"main_state": modo, "main_state_txt": MAIN_STATE.get(modo, "?"),
                       "tilt_angle": tilt,
                       "target_angle": tilt if target is None else target,
                       "system_ok": system_ok}}


def flota(angulo_sano=5.0, n=6):
    return [tcu(i, angulo_sano) for i in range(1, n + 1)]


print("=== el caso: seguimiento congelado, EN su objetivo, fuera de sus vecinas ===")
sanas = flota()                       # seis en AUTO a +5°, cada una en su objetivo
congelada = tcu(99, -12.0)            # clavada a −12 y persiguiendo −12
grupo = sanas + [congelada]
d = desvios_entre_vecinos(grupo)

# EL FIXTURE CONTIENE EL MECANISMO: si el lazo pudiera verlo, este banco no
# probaría nada. Se comprueba que NO puede antes de pedir que el residuo sí.
f = congelada["fields"]
chk_true("el lazo NO puede ver este caso: |tilt − target| = 0",
         abs(f["tilt_angle"] - f["target_angle"]) == 0,
         f"tilt {f['tilt_angle']} target {f['target_angle']}")
chk("…y por eso HOY, sin el residuo, sale ok",
    tracker_health(f, [], FRESCO), "ok")

chk("el residuo la mide: 17° fuera de sus vecinas", d[99], -17.0)
chk("y ahora sale warn", tracker_health(f, [], FRESCO, 300, d[99]), "warn")
chk_true("con su motivo, que nombra la consigna y no el encoder",
         "consigna distinta" in motivo_health(f, [], FRESCO, 300, d[99]),
         motivo_health(f, [], FRESCO, 300, d[99]))
chk("una vecina sana sigue en ok",
    tracker_health(sanas[0]["fields"], [], FRESCO, 300, d[1]), "ok")
chk_true("y las dos NO salen iguales, que es el punto",
         tracker_health(f, [], FRESCO, 300, d[99])
         != tracker_health(sanas[0]["fields"], [], FRESCO, 300, d[1]))
chk("el desvío de una sana es 0, no None", d[1], 0.0)

print("=== lo que NO detecta, fijado a propósito ===")
# Sesgo de encoder: el lazo lo absorbe, así que TODAS publican el mismo ángulo.
# La descalibrada está 3,5° torcida de verdad y NADA en estos datos lo dice.
sesgada = flota(n=6)                  # las seis publican +5, una de ellas miente
d2 = desvios_entre_vecinos(sesgada)
chk_true("un sesgo de encoder NO lo ve: todas publican lo mismo",
         all(abs(v) < 0.001 for v in d2.values()),
         str(d2))
chk("…y la sesgada sale ok, como no puede ser de otro modo",
    tracker_health(sesgada[0]["fields"], [], FRESCO, 300, d2[1]), "ok")
chk_true("un desajuste COMÚN a toda la NCU tampoco: la mediana se va con él",
         all(abs(v) < 0.001 for v in desvios_entre_vecinos(flota(angulo_sano=40.0)).values()))

print("=== la referencia no se envenena con quien no está siguiendo ===")
# CUATRO PARADAS, NO UNA, y el fixture lo necesita. Con una sola, la mediana de
# cinco sanas la ignora sola y la comprobación saldría verde aunque el filtro no
# existiera: probaría la robustez de la mediana, no el filtro. Con cuatro
# paradas a −40° frente a cinco sanas, SIN filtro la mediana se va a −17,5 y una
# sana sale `warn` por tener vecinas aparcadas. Lo que se exige es que una sana
# siga en `ok` con desvío 0.
PARADAS = [
    ("en OFF", lambda n: tcu(n, -40.0, modo=0)),
    ("en MANUAL", lambda n: tcu(n, -40.0, modo=1)),
    ("sin comunicación", lambda n: tcu(n, -40.0, edad=9999.0)),
    ("con alarma", lambda n: tcu(n, -40.0, alarms=["axis_blocked"])),
    ("con system_ok=0", lambda n: tcu(n, -40.0, system_ok=0)),
]
for nombre, hacer in PARADAS:
    g = flota(n=5) + [hacer(50 + i) for i in range(4)]
    dd = desvios_entre_vecinos(g)
    chk_true(f"cuatro {nombre} no envenenan la referencia de una sana",
             dd[1] == 0.0 and tracker_health(g[0]["fields"], [], FRESCO, 300, dd[1]) == "ok",
             f"desvío de la sana {dd[1]}")
chk("y comparable_como_referencia lo dice sola",
    comparable_como_referencia({"main_state": 0, "tilt_angle": 1.0}, [], FRESCO), False)
chk("…y aprueba a una que sí sigue",
    comparable_como_referencia({"main_state": 2, "tilt_angle": 1.0, "system_ok": 1},
                               [], FRESCO), True)

print("=== con pocos vecinos NO se juzga, y None no es cero ===")
# NÚMEROS LITERALES, 3 y 4, NO `MIN_VECINOS_COMPARABLES ± 1`. La primera versión
# de estas tres usaba la constante para construir su fixture, así que el fixture
# se encogía con ella: bajar el mínimo a 1 dejaba las tres VERDES —medido, mató
# cero—. Una comprobación que deriva su caso de lo que vigila no vigila su valor.
# El valor se exige aparte y a pelo.
chk("el mínimo declarado son 4 vecinos", MIN_VECINOS_COMPARABLES, 4)
pocos = flota(n=3) + [congelada]
chk("con 3 vecinos comparables: sin veredicto",
    desvios_entre_vecinos(pocos)[99], None)
chk("…y entonces la clasificación es la de antes del residuo",
    tracker_health(congelada["fields"], [], FRESCO, 300,
                   desvios_entre_vecinos(pocos)[99]), "ok")
justos = flota(n=4) + [congelada]
chk("con 4 ya se juzga", desvios_entre_vecinos(justos)[99], -17.0)
sin_angulo = flota() + [tcu(98, None)]
chk("sin ángulo, sin veredicto", desvios_entre_vecinos(sin_angulo)[98], None)

print("=== la mediana, y el seguidor fuera de su propia referencia ===")
chk("mediana impar", mediana([1.0, 5.0, 2.0]), 2.0)
chk("mediana par", mediana([1.0, 3.0]), 2.0)
chk("mediana de nada es None", mediana([]), None)
# Dos congeladas en el mismo sitio: con MEDIA la referencia se iría hacia ellas;
# con mediana, no. Cinco sanas a +5 y dos a −12 -> la mediana sigue siendo +5.
dos = flota(n=5) + [tcu(90, -12.0), tcu(91, -12.0)]
chk_true("con dos desviadas la mediana no se va con ellas",
         desvios_entre_vecinos(dos)[90] == -17.0,
         f"desvío {desvios_entre_vecinos(dos)[90]}")
# CUATRO Y CUATRO, y la aritmética es el motivo. Con seis sanas y una congelada,
# meter al propio seguidor en su referencia NO mueve la mediana (sigue siendo 5),
# así que esa comprobación saldría verde sin exclusión ninguna. Con 4 sanas a +5
# y 4 congeladas a −12: excluyéndose, los vecinos de una congelada son
# [5,5,5,5,−12,−12,−12] -> mediana 5 -> desvío −17. Incluyéndose serían ocho
# valores -> mediana (−12+5)/2 = −3,5 -> desvío −8,5. Ahí sí se nota.
cuatro_y_cuatro = flota(n=4) + [tcu(90 + i, -12.0) for i in range(4)]
chk("cada seguidor se excluye de su propia referencia",
    desvios_entre_vecinos(cuatro_y_cuatro)[90], -17.0)

print("=== el umbral, en sus dos lados ===")
# Mismo cuidado: 2,99 y 3,01 LITERALES. Con `DESVIO_VECINOS_DEG + 0.01` el caso
# se mueve con el umbral y aflojarlo a 30° dejaba estas dos verdes.
chk("el umbral declarado son 3,0°", DESVIO_VECINOS_DEG, 3.0)
base = tcu(1, 5.0)["fields"]
chk("2,99° no avisa", tracker_health(base, [], FRESCO, 300, 2.99), "ok")
chk("3,01° sí", tracker_health(base, [], FRESCO, 300, 3.01), "warn")
chk("y en negativo igual, es el valor absoluto",
    tracker_health(base, [], FRESCO, 300, -3.01), "warn")

print("=== el residuo solo puede convertir ok en warn ===")
# Ningún veredicto anterior puede cambiar por culpa de esto. Se comprueba sobre
# los cuatro, con un desvío enorme.
ENORME = 90.0
casos = [
    ("offline manda", tcu(1, 5.0, edad=9999.0), "offline"),
    ("alarma crítica manda", tcu(2, 5.0, alarms=["axis_blocked"]), "alarm"),
    ("alarma no crítica manda", tcu(3, 5.0, alarms=["otra"]), "warn"),
    ("system_ok=0 manda", tcu(4, 5.0, system_ok=0), "warn"),
    ("OFF manda", tcu(5, 5.0, modo=0), "warn"),
    ("desviada del objetivo manda", tcu(6, 5.0, target=-30.0), "warn"),
]
for nombre, t, esperado in casos:
    sin = tracker_health(t["fields"], t["alarms"], t["comms_age_s"])
    con = tracker_health(t["fields"], t["alarms"], t["comms_age_s"], 300, ENORME)
    chk_true(nombre, sin == con == esperado, f"sin={sin} con={con}")
# Y el motivo tampoco cambia para esos.
t = casos[5][1]
chk("el motivo del fallo de lazo sigue siendo el del lazo",
    motivo_health(t["fields"], t["alarms"], t["comms_age_s"], 300, ENORME),
    "desviado del objetivo más de 5°")

print()
if fallos:
    print(f"FALLOS: {len(fallos)} de {ok + len(fallos)}")
    for f_ in fallos:
        print("  ·", f_)
    sys.exit(1)
print(f"Todo OK ({ok} comprobaciones)")
