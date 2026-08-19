#!/usr/bin/env python3
"""Compara `config/modbus_map.yml` con el mapa R7 publicado en la plataforma.

`config/modbus_map.yml` es un SUBCONJUNTO escrito a mano del documento de
fabricante. El mapa completo, ya extraído a JSON, vive en el repo de Cobertura
Zigbee (`tools/modbus_src/ncu_r7_hsu_r23.json`, el mismo que genera la ficha
`modbus.html` del Panel). Este banco comprueba que el subconjunto no se ha
desviado de él: bases y tamaños de bloque, offsets y tipos de cada campo del
bloque compat, y los bits de alarma que deciden el estado `health`.

    python tools/test_modbus_map.py
    python tools/test_modbus_map.py --fuente /ruta/ncu_r7_hsu_r23.json

Si no encuentra la fuente no falla: avisa y sale. En un portátil de campo el
otro repo puede no estar clonado.
"""
import argparse
import json
import os
import sys

import yaml

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CANDIDATAS = [
    os.environ.get("MODBUS_SRC", ""),
    os.path.join(RAIZ, "..", "cobertura-zigbee", "tools", "modbus_src", "ncu_r7_hsu_r23.json"),
    os.path.expanduser("~/cobertura-zigbee/tools/modbus_src/ncu_r7_hsu_r23.json"),
]

# El documento y el YAML no hablan igual: aquí la traducción de tipos.
TIPOS = {"u16": {"U16"}, "s16": {"S16"}, "u32": {"U32"}, "s32": {"S32"},
         "f32": {"F32"}, "u8_low": {"U8"}}

# Diferencias CONOCIDAS y deliberadas, con su motivo. Cualquier otra es un fallo.
ERRATAS = {
    ("tcu_compat", 13): "El R7 solapa StateOfCharge (U8 bajo) y RemainingCapacity (U16) en 30513; "
                        "el colector lee el SoC del byte bajo, confirmado en R7.1",
    ("tcu_compat", 1): "El doc etiqueta MSR como U8, pero coloca MainState en los bits 9..8 y "
                       "SafePosition en 15..13: el registro se lee entero (U16) y se extraen bits",
}

ok, ko = 0, 0


def check(nombre, cond, extra=""):
    global ok, ko
    if cond:
        ok += 1
        print("  ok  " + nombre)
    else:
        ko += 1
        print("FALLO " + nombre + (" -> " + extra if extra else ""))


def bloque(src, nombre):
    return next((b for b in src["bloques_r7"] if b["nombre"] == nombre), None)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fuente", default=None, help="ncu_r7_hsu_r23.json del repo de Cobertura")
    a = ap.parse_args()

    ruta = a.fuente or next((c for c in CANDIDATAS if c and os.path.exists(c)), None)
    if not ruta or not os.path.exists(ruta):
        print("No encuentro el mapa R7 extraído (ncu_r7_hsu_r23.json).")
        print("Está en el repo cobertura-zigbee: tools/modbus_src/. Clónalo al lado de este,")
        print("o pásalo con --fuente. Sin él no puedo comparar; no doy por bueno nada.")
        return 0

    src = json.load(open(ruta, encoding="utf-8"))
    with open(os.path.join(RAIZ, "config", "modbus_map.yml"), encoding="utf-8") as f:
        y = yaml.safe_load(f)
    print(f"Fuente: {os.path.relpath(ruta, RAIZ)}\n")

    print("bloques:")
    for clave, nombre_doc, campos in (
        ("tcu_compat", "TCU Data", ("base", "stride", "max_tcus")),
        ("tcu_lastcomm", "TCUs Last Comunication", ("base", "stride")),
        ("hsu", "HSU Data", ("base", "stride", "max_hsus")),
        ("hsu_ext", "HSU Data extended", ("base", "stride")),
    ):
        b = bloque(src, nombre_doc)
        n = y.get(clave, {})
        check(f"{clave}: base {n.get('base')} = {nombre_doc} @{b['de']}", n.get("base") == b["de"])
        check(f"{clave}: stride {n.get('stride')} = {b['tam']}", n.get("stride") == b["tam"])
        if "max_tcus" in campos or "max_hsus" in campos:
            declarado = n.get("max_tcus", n.get("max_hsus"))
            check(f"{clave}: unidades {declarado} = {b['unidades']}", declarado == b["unidades"])
    b = bloque(src, "HSU Last Comunication")
    check(f"hsu: lastcomm_base {y['hsu'].get('lastcomm_base')} = @{b['de']}",
          y["hsu"].get("lastcomm_base") == b["de"])
    ncu = bloque(src, "NCU Base Info")
    fuera = [r["addr"] for r in y["ncu"]["registers"].values()
             if not (ncu["de"] <= r["addr"] <= ncu["a"])]
    check(f"los registros de NCU caen dentro de {ncu['de']}..{ncu['a']}", not fuera, str(fuera))

    print("\nbloque compat, campo a campo:")
    tc = {r["offset"]: r for r in src["ncu_r7"]["TCU Compat"] if r.get("offset") is not None}
    for off, spec in sorted(y["tcu_compat"]["fields"].items(), key=lambda kv: int(kv[0])):
        off = int(off)
        doc = tc.get(off)
        if doc is None:
            check(f"offset {off} ({spec['name']}) existe en el documento", False, "no está")
            continue
        motivo = ERRATAS.get(("tcu_compat", off))
        bien = doc["tipo"] in TIPOS.get(spec["type"], set())
        if motivo:
            print(f"  --  offset {off} ({spec['name']}) vs {doc['nombre']}: errata conocida")
            print(f"      {motivo}")
            continue
        check(f"offset {off}: {spec['name']} ({spec['type']}) = {doc['nombre']} ({doc['tipo']})", bien)

    print("\nbits de alarma (los que deciden el health):")
    doc_bits = {"alarms1": {}, "alarms2": {}}
    actual = None
    for r in src["ncu_r7"]["TCU Compat"]:
        if r.get("offset") == 2:
            actual = "alarms1"
        elif r.get("offset") == 3:
            actual = "alarms2"
        elif r.get("offset") is not None:
            actual = None
        elif actual and r["bits"].startswith("("):
            lsb = int(r["bits"].strip("()").split("..")[-1])
            doc_bits[actual][lsb] = r["nombre"]
    for reg, bits in y["alarm_bits"].items():
        for bit, nombre in bits.items():
            doc = doc_bits[reg].get(int(bit))
            check(f"{reg} bit {bit} ({nombre}) existe en el documento", doc is not None,
                  f"el doc no declara ese bit; los que hay: {sorted(doc_bits[reg])}")
        sobran = sorted(set(doc_bits[reg]) - {int(b) for b in bits})
        if sobran:
            print(f"  --  {reg}: el documento declara además los bits {sobran} "
                  f"({', '.join(doc_bits[reg][b] for b in sobran)}), que el colector no decodifica")

    print()
    if ko:
        print(f"{ko} FALLOS, {ok} OK")
        return 1
    print(f"Todo OK ({ok} comprobaciones)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
