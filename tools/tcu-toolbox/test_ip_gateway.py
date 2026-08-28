#!/usr/bin/env python3
"""
test_ip_gateway.py — la IP del GATEWAY de la hoja «Direcciones IP».

POR QUE EXISTE. La hoja trae 'IP GW 1' e 'IP GW 2' y `make_plantas.py` NO leia su
valor: las usaba solo como MARCADOR de columna para encontrar el segundo
'Esclavos' y las RSU. Asi que el JSON del toolbox salia con una sola direccion,
la 'IP NCU' — que es el MODBUS TCP de la NCU (503/504) — y quien tiene que hablar
con el gateway (el ConnectPort DIGI, por HTTP/RCI y telnet) se quedaba sin la
suya.

ESO NO ES UN DETALLE. El paquete que se lleva al PC de la planta prepara los dos
recolectores con la IP del gateway; sin ella hay que ponerla a mano, y quien la
confunda con la del Modbus mide contra el sitio equivocado sin saber por que.

SE PRUEBA CON UNA PASADA DE VERDAD, no contra cabeceras: el Excel maestro no esta
en ningun repo —y no debe estarlo—, asi que aqui se FABRICA una hoja minima con
los nombres de columna reales y se pasa por `modo_excel`. Lo que no cubre es que
la hoja real se llame exactamente asi; para eso, una pasada con la de verdad.

    python3 tools/tcu-toolbox/test_ip_gateway.py
"""
import json
import os
import sys
import tempfile

AQUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, AQUI)
from make_plantas import modo_excel                                    # noqa: E402

fallos = []


def di(ok, texto, extra=None):
    if not ok:
        fallos.append(texto)
    print("  %s %s%s" % ("ok   " if ok else "FALLA", texto,
                         "" if ok or extra is None else "  -> %s" % (extra,)))


CAB = ["Nº", "Proyecto", "NCU", "IP NCU", "IP GW 1", "Esclavos", "RSU",
       "IP GW 2", "Esclavos", "RSU"]


def pasada(filas, cab=CAB):
    """Una pasada de verdad: fabrica la hoja, corre `modo_excel` y devuelve las
    entradas del JSON que escribe. EN UN DIRECTORIO APARTE — `modo_excel` escribe
    en `plantas/` relativo al directorio actual, y corriendo aqui sin mas te
    machaca los JSON del repo (me paso)."""
    ruta = hoja(filas, cab)
    prev = os.getcwd()
    tmp = tempfile.mkdtemp()
    try:
        os.chdir(tmp)
        salidas = modo_excel(ruta, "Direcciones IP", [503, 504], [], "")
        destino = salidas[0][0]          # devuelve (ruta, nº de entradas)
        return json.loads(open(destino, encoding="utf-8").read())["plantas"]
    finally:
        os.chdir(prev)


def hoja(filas, cab=CAB, nombre="Direcciones IP"):
    """Un .xlsx minimo con la estructura de la hoja real."""
    from openpyxl import Workbook
    wb = Workbook()
    ws = wb.active
    ws.title = nombre
    ws.append(cab)
    ws.append([""] * len(cab))            # la hoja real trae una subcabecera: modo_excel salta la fila 2
    for f in filas:
        ws.append(f)
    ruta = os.path.join(tempfile.mkdtemp(), "maestro.xlsx")
    wb.save(ruta)
    return ruta


# ── El Burgo: dos gateways por NCU, IP de NCU .52 y gateways .53/.54 ──────────────────────────────
ent = pasada([
    ["23003", "El Burgo I", 1, "10.100.1.52", "10.100.1.53", "1-56", "", "10.100.1.54", "57-108", ""],
    ["",      "",           2, "10.100.1.56", "10.100.1.57", "1-45", "", "10.100.1.58", "46-107", ""],
])
print("· El Burgo: dos gateways por NCU")
di(len(ent) == 4, "salen las cuatro entradas (NCU1/2 x GW1/2)", len(ent))
di([e.get("ip_gw") for e in ent] == ["10.100.1.53", "10.100.1.54", "10.100.1.57", "10.100.1.58"],
   "cada una con la IP de SU gateway", [e.get("ip_gw") for e in ent])
di([e["ip"] for e in ent] == ["10.100.1.52", "10.100.1.52", "10.100.1.56", "10.100.1.56"],
   "y la IP de la NCU intacta, que es su Modbus", [e["ip"] for e in ent])
di([e["puerto"] for e in ent] == [503, 504, 503, 504], "con un puerto Modbus por gateway")
di(all(e["ip_gw"] != e["ip"] for e in ent), "el gateway NUNCA es la IP del Modbus")

# ── Ayora: UN gateway por NCU. Es el caso que se perdia aguas abajo ───────────────────────────────
ent = pasada([
    ["24025", "Ayora", 1, "192.168.4.10", "192.168.4.11", "1-63", "", "", "", ""],
    ["",      "",      2, "192.168.4.20", "192.168.4.21", "1-69", "", "", "", ""],
])
print("· Ayora: un gateway por NCU")
di(len(ent) == 2 and [e.get("ip_gw") for e in ent] == ["192.168.4.11", "192.168.4.21"],
   "tambien lleva su IP de gateway", [e.get("ip_gw") for e in ent])
di(all(" GW" not in e["nombre"] for e in ent),
   "y sin sufijo de gateway en el nombre, que solo hay uno", [e["nombre"] for e in ent])

# ── lo que NO debe hacer ─────────────────────────────────────────────────────────────────────────
print("· lo que no debe inventarse")
ent = pasada([["24007", "Fayon", 1, "10.0.0.1", "", "1-24", "", "", "", ""]])
di("ip_gw" not in ent[0], "celda vacia: NO se escribe ip_gw", ent[0].get("ip_gw"))
ent = pasada([["24007", "Fayon", 1, "10.0.0.1", "no es una ip", "1-24", "", "", "", ""]])
di("ip_gw" not in ent[0], "celda con basura: tampoco", ent[0].get("ip_gw"))

# Sin la columna, la hoja vieja tiene que seguir pasando: avisa y sigue.
CAB_VIEJA = ["Nº", "Proyecto", "NCU", "IP NCU", "Esclavos", "RSU", "IP GW 2", "Esclavos", "RSU"]
ent = pasada([["24021", "Tunez", 1, "10.0.0.9", "1-19", "", "", "", ""]], cab=CAB_VIEJA)
di(len(ent) == 1 and "ip_gw" not in ent[0] and ent[0]["ip"] == "10.0.0.9",
   "una hoja SIN la columna sigue pasando, solo que sin ip_gw", ent[0])

print("\n%d comprobaciones, %d fallos" % (12, len(fallos)))
sys.exit(1 if fallos else 0)
