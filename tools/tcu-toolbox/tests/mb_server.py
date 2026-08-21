#!/usr/bin/env python3
"""Servidor Modbus TCP minimo para probar TCU Toolbox (FC03/FC16/FC22)."""
import socket, struct, threading, sys, time

regs = {}  # (unit, addr) -> value

def preset(unit, addr, vals):
    for i, v in enumerate(vals):
        regs[(unit, addr + i)] = v & 0xFFFF

# TCU 5: datos de prueba
# estado 30001..30006: main, al1(seta+socbajo), al2(eje bloqueado), al3, al4, status(ok=0,motor lock)
preset(5, 30001, [0x0280, (1 << 4) | (1 << 13), (1 << 8), 0, 0, (1 << 11)])
preset(5, 30094, [25837, 65036, (95 << 8) | 87, 215, 312])  # vbat, ibat=-500, soh95/soc87, tbat21.5, tpcb31.2
preset(5, 30111, [155, 460])   # tilt 15.5, target 46.0
preset(5, 30153, [5])          # CC
# fecha BCD 30079: 2026-08-04 12:34:56 -> reg0: mes 0x08 lo, ano 0x26 hi
preset(5, 30079, [0x2608, 0x0412, 0x3456])
# u32 en 30086: 123456 J -> lo=0xE240 hi=0x0001
preset(5, 30086, [0xE240, 0x0001])
# f32 en 41010: -0.02941 rad
import math
b = struct.pack('<f', -0.02941)
preset(5, 41010, [struct.unpack('<H', b[0:2])[0], struct.unpack('<H', b[2:4])[0]])
# identidad 30300+
preset(5, 30300, [0x0121, (1 << 8) | 4, (3 << 8) | 7, 11, 22, 33, 2, 9, 0x2021, 0x1009])
preset(5, 30310, [0x5678, 0x1234, 0xBBBB, 0x00AA])  # MAC low=0x12345678 high=0x00AABBBB
serial = "SN2024FACTIUN00042"  # 18 chars: char1..18
# regs 30314..30322: (18,17)...(2,1) -> reg i tiene chars (18-2k) LSB y (17-2k) MSB
for k in range(9):
    c_lsb = serial[17 - 2 * k]      # char (18-2k)
    c_msb = serial[16 - 2 * k]      # char (17-2k)
    regs[(5, 30314 + k)] = (ord(c_msb) << 8) | ord(c_lsb)
preset(5, 30323, [(2 << 8) | 0, (1 << 8) | 5])
preset(5, 30325, [(8 << 8) | 15])
preset(5, 30326, [2024, 77, 88, 3])

# TCU 6: sin alarmas, todo OK
preset(6, 30001, [0x0280, 0, 0, 0, 0, 1 << 15])
preset(6, 30094, [26000, 200, (98 << 8) | 90, 220, 300])
preset(6, 30111, [100, 100])
preset(6, 30153, [7])
# TCU 8: solo SoC bajo L3 (bit 12) -> AVISO (criterio decode.py: L3 no es critico)
# TCU 10: el mismo caso de campo por Zigbee directo. Copia del 6 salvo el modo.
preset(10, 30001, [0x0080, 0, 0, 0, 0, 1 << 15])   # OFF, de dia, system OK, sin alarmas
preset(10, 30094, [26000, 200, (98 << 8) | 90, 220, 300])
preset(10, 30111, [100, 100])                      # tilt = objetivo -> dif 0
preset(10, 30153, [7])

preset(8, 30001, [0x0280, 1 << 12, 0, 0, 0, 1 << 15])
preset(8, 30094, [26000, 200, (98 << 8) | 20, 220, 300])
preset(8, 30111, [100, 100])
preset(8, 30153, [5])
# TCU 9: batt_critical (bit 14, SoC<10%) -> ALARMA
preset(9, 30001, [0x0280, 1 << 14, 0, 0, 0, 1 << 15])
preset(9, 30094, [22000, -100 & 0xFFFF, (98 << 8) | 5, 220, 300])
preset(9, 30111, [100, 100])
preset(9, 30153, [2])

def f32w(x):
    d = struct.pack('<f', x)
    return [struct.unpack('<H', d[0:2])[0], struct.unpack('<H', d[2:4])[0]]

# HSU esclavo 185: meteo en vivo + config + caja negra
hsu_live = [0x040F, (3 << 12) | 2, 1 << 9] + f32w(12.5) + f32w(270.0) + f32w(0.05) + [0, 3000, 450]
irr = 85000
hsu_live += [irr & 0xFFFF, irr >> 16]
preset(185, 30000, hsu_live)                                # 30000..30013
preset(185, 30021, [3600] + f32w(11.0) + f32w(265.0) + [300, 3300, 12000])   # 30021..30028
preset(185, 41002, [185, 0, 185, 0, 0, 0, (1 << 5) | (1 << 6)])              # 41002..41008
preset(185, 40008, [150])
preset(185, 41011, f32w(15.0) + f32w(18.0) + [0, 0, 3, 5])   # low, mid, -, -, tLow, tMid
for m in range(6):   # caja negra: primeros 6 minutos con patron
    preset(185, 31000 + m * 4, [100 + m, 10 | (20 + m) << 8, 3, 5005])

# NCU (unit 1): 30100 din, 30101 main (GW2 caido), 30104/5 epoch
epoch = 1785916800   # 2026-08-05 08:00:00 UTC
preset(1, 30100, [0, 1 << 5, 0, 0, epoch & 0xFFFF, epoch >> 16])

# Bloque compacto de TCUs cacheado por la NCU (30500+, 22 regs/TCU) + lastComm
def compat(tcu, msr, al1, al2, fl, tilt_rad, targ_rad, soc, soh, lastcomm):
    base = 30500 + (tcu - 1) * 22
    regs22 = ([0, msr, al1, al2, fl, 30000] + f32w(tilt_rad) + [120, 300] + f32w(targ_rad)
              + [50, soc, 0, 0, 26600, 0, (-50) & 0xFFFF, 3105, 3026, soh])
    preset(1, base, regs22)
    preset(1, 29500 + (tcu - 1) * 2, [lastcomm & 0xFFFF, lastcomm >> 16])

compat(1, 0x0200, 0, 0, 0x8000, -0.9599, -0.9599, 90, 100, epoch - 30)   # OK, AUTO
compat(2, 0x0200, 0, 0, 0x8000, 0.0, 0.0, 50, 99, 0)                     # nunca leido -> OFFLINE
compat(3, 0x0100, 0, 1 << 8, 0x8000, 0.1, 0.1, 80, 98, epoch - 10)       # eje bloqueado -> ALARMA
# El caso de campo (scada#210): un TCU PARADO, sin alarmas, con el eje en la
# misma posicion que el resto. Identico al 1 salvo los bits 9:8 del MSR. Si el
# modo no entra en la salud, sale verde y en el barrido de despues de una
# intervencion no se distingue de los que si estan siguiendo.
compat(4, 0x0000, 0, 0, 0x8000, -0.9599, -0.9599, 90, 100, epoch - 30)   # OFF,    dif 0
compat(6, 0x0100, 0, 0, 0x8000, -0.9599, -0.9599, 90, 100, epoch - 30)   # MANUAL, dif 0

# HSU 1 cacheada por la NCU (30200+): alarma de viento activa, nivel 2
preset(1, 30200, [0x040F, 2, 1 << 9] + f32w(12.5) + f32w(270.0) + f32w(0.05) + [0])
preset(1, 29440, [(epoch - 20) & 0xFFFF, (epoch - 20) >> 16])
# TCU 7 no existe -> GatewayTargetNoResponse (0x0B)

# TCU 77: reproduce el fallo de campo. La NCU deja de contestar una vez (0x0B)
# y a partir de ahi va UNA RESPUESTA POR DETRAS: contesta a cada peticion con
# el cuerpo de la anterior, pero sellado con el TID de la peticion en curso,
# asi que comprobar el TID no lo detecta. Efecto en la toolbox: cada variable
# muestra el valor de la anterior (east_pitch con los radianes de max_tilt...).
preset(77, 41111, f32w(math.radians(55)))    # max_tilt_west_r1 -> 55 grados
preset(77, 41106, f32w(6.0))                 # east_pitch -> 6 m
preset(77, 41125, f32w(math.radians(30)))    # min_tilt_east_r1 -> 30 grados
atrasada = {}          # id(conn) -> pdu que tocaba contestar en la peticion anterior
# el disparo se rearma tras 5 s sin trafico en la 77, para que cada pasada
# de las pruebas vuelva a encontrarse el fallo sin reiniciar el simulador
disparo = {'usado': False, 't': 0.0}

def handle(conn):
    try:
        while True:
            hdr = b''
            while len(hdr) < 7:
                chunk = conn.recv(7 - len(hdr))
                if not chunk:
                    return
                hdr += chunk
            tid, pid, length, unit = struct.unpack('>HHHB', hdr)
            body = b''
            while len(body) < length - 1:
                chunk = conn.recv(length - 1 - len(body))
                if not chunk:
                    return
                body += chunk
            fc = body[0]
            def reply(pdu):
                conn.sendall(struct.pack('>HHHB', tid, 0, len(pdu) + 1, unit) + pdu)
            def exc(code):
                reply(bytes([fc | 0x80, code]))
            if unit == 7:
                exc(0x0B); continue
            if unit == 77:
                ahora = time.time()
                if ahora - disparo['t'] > 5:
                    disparo['usado'] = False
                disparo['t'] = ahora
                if fc == 3:
                    addr, n = struct.unpack('>HH', body[1:5])
                    vals = [regs.get((77, addr + i), 0) for i in range(n)]
                    toca = bytes([3, 2 * n]) + b''.join(struct.pack('>H', v) for v in vals)
                else:
                    toca = bytes([fc])
                previa = atrasada.get(id(conn))
                if previa is None and not disparo['usado']:
                    disparo['usado'] = True      # el fallo que descoloca la tuberia
                    atrasada[id(conn)] = toca
                    exc(0x0B); continue
                if previa is not None:
                    atrasada[id(conn)] = toca
                    reply(previa); continue      # una por detras
                reply(toca); continue
            if fc == 3:
                addr, n = struct.unpack('>HH', body[1:5])
                vals = [regs.get((unit, addr + i), 0) for i in range(n)]
                reply(bytes([3, 2 * n]) + b''.join(struct.pack('>H', v) for v in vals))
            elif fc == 16:
                addr, n, bc = struct.unpack('>HHB', body[1:6])
                for i in range(n):
                    regs[(unit, addr + i)] = struct.unpack('>H', body[6 + 2 * i:8 + 2 * i])[0]
                reply(bytes([16]) + struct.pack('>HH', addr, n))
            elif fc == 22:
                addr, am, om = struct.unpack('>HHH', body[1:7])
                cur = regs.get((unit, addr), 0)
                regs[(unit, addr)] = (cur & am) | (om & ~am)
                reply(body[:7])
            else:
                exc(1)
    finally:
        atrasada.pop(id(conn), None)   # sin esto, un id reutilizado heredaria el desfase
        conn.close()

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('127.0.0.1', 15020))
srv.listen(5)
print('listo', flush=True)
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
