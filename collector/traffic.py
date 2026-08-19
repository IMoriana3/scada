"""Medidor de tráfico: qué cuesta el SCADA en la LAN de planta y cuánto sube a la nube.

Dos usos con el MISMO modelo de bytes, para que la estimación y la medida sean
comparables:

1. **Medida real** (`TrafficMeter`): el colector cuenta cada transacción Modbus
   contra la NCU y cada escritura a InfluxDB, y publica el resultado como una
   serie más (`traffic`). Es tráfico *contabilizado*, no capturado: se calcula
   del tamaño real de cada ADU y de cada payload, no de un sniffer.
2. **Estimación** (`modbus_cycle`, `cloud_cycle`, `plant_estimate`): el mismo
   modelo aplicado sobre la configuración, para dimensionar una planta ANTES de
   conectar nada — típicamente el plan de datos del router 4G de la caseta.

Modelo de la capa Modbus TCP (function 03, solo lectura):

    petición  = MBAP(7) + FC(1) + dirección(2) + nº registros(2)      = 12 B
    respuesta = MBAP(7) + FC(1) + byte count(1) + 2·nº registros      = 9 + 2n B

a lo que se suma la cabecera IPv4+TCP de cada segmento (40 B por defecto) y,
una vez por ciclo y NCU, el handshake y el cierre de la conexión (el colector
abre y cierra en cada vuelta): 7 segmentos sin datos.

Los ACK puros no se cuentan: en un polling petición/respuesta el ACK viaja
montado en el segmento de datos siguiente. El error por ese lado es como mucho
40 B por transacción, y siempre a la baja.
"""
import gzip

# --- Modbus TCP -------------------------------------------------------------
MBAP_B = 7               # transaction + protocol + length + unit id
REQ_PDU_B = 5            # FC + dirección + nº de registros
RESP_PDU_HEAD_B = 2      # FC + byte count
# IPv4(20) + TCP(20) sin opciones. Ethernet (18 B más por trama) queda fuera:
# lo que se factura en un enlace 4G/VPN es la carga IP, no la trama del switch.
L3L4_B = 40
# SYN, SYN/ACK, ACK, FIN/ACK, ACK, FIN/ACK, ACK
HANDSHAKE_FRAMES = 7

# --- Escritura a la nube ----------------------------------------------------
# Cabeceras HTTP + registro TLS de un POST /api/v2/write con token: medido
# contra InfluxDB 2.7, redondeado al alza.
HTTP_OVERHEAD_B = 500


def split_reads(count: int, max_regs: int) -> list[int]:
    """Trocea una lectura de `count` registros como lo hace el driver."""
    out = []
    while count > 0:
        n = min(max_regs, count)
        out.append(n)
        count -= n
    return out


def read_bytes(n_regs: int, overhead_b: int = L3L4_B) -> tuple[int, int]:
    """Bytes (subida, bajada) de UNA transacción FC03 de `n_regs` registros."""
    up = MBAP_B + REQ_PDU_B + overhead_b
    down = MBAP_B + RESP_PDU_HEAD_B + 2 * n_regs + overhead_b
    return up, down


class TrafficMeter:
    """Contador de bytes de una NCU: LAN de planta y subida a la nube.

    Acumula desde el último `snapshot()`; el colector lo vuelca una vez por
    ciclo, así cada punto de la serie `traffic` es el coste de ESE ciclo.
    """

    def __init__(self, overhead_b: int = L3L4_B, http_overhead_b: int = HTTP_OVERHEAD_B):
        self.overhead_b = overhead_b
        self.http_overhead_b = http_overhead_b
        self.reset()

    def reset(self):
        self.lan_up_b = 0
        self.lan_down_b = 0
        self.modbus_tx = 0
        self.connections = 0
        self.cloud_raw_b = 0
        self.cloud_gz_b = 0
        self.cloud_points = 0
        self.cloud_writes = 0

    def connection(self):
        """Apertura + cierre de la conexión TCP contra la NCU."""
        self.connections += 1
        # el handshake lo reparten los dos extremos; a efectos de volumen
        # facturado da igual, se reparte mitad y mitad.
        b = HANDSHAKE_FRAMES * self.overhead_b
        self.lan_up_b += b // 2 + b % 2
        self.lan_down_b += b // 2

    def read(self, n_regs: int):
        """Una transacción Modbus de lectura de `n_regs` registros."""
        up, down = read_bytes(n_regs, self.overhead_b)
        self.lan_up_b += up
        self.lan_down_b += down
        self.modbus_tx += 1

    def cloud_write(self, lines: list[str]):
        """Una escritura a InfluxDB, con sus líneas ya en line protocol."""
        if not lines:
            return
        payload = ("\n".join(lines) + "\n").encode()
        self.cloud_raw_b += len(payload)
        # mtime=0: el gzip debe depender solo del contenido (si no, dos ciclos
        # idénticos darían tamaños distintos y el test no sería reproducible).
        self.cloud_gz_b += len(gzip.compress(payload, compresslevel=6, mtime=0)) + self.http_overhead_b
        self.cloud_points += len(lines)
        self.cloud_writes += 1

    def snapshot(self, period_s: float, reset: bool = True) -> dict:
        """Vuelca los contadores del periodo y (por defecto) los pone a cero.

        `cloud_gz_b` ya lleva dentro la cabecera HTTP/TLS de cada escritura:
        es lo que de verdad sale por el router, no el payload pelado.
        """
        snap = {
            "lan_up_b": self.lan_up_b,
            "lan_down_b": self.lan_down_b,
            "lan_b": self.lan_up_b + self.lan_down_b,
            "modbus_tx": self.modbus_tx,
            "connections": self.connections,
            "cloud_raw_b": self.cloud_raw_b,
            "cloud_gz_b": self.cloud_gz_b,
            "cloud_points": self.cloud_points,
            "cloud_writes": self.cloud_writes,
            "period_s": round(period_s, 2),
        }
        if reset:
            self.reset()
        return snap


# --- Estimación a partir de la configuración --------------------------------

def modbus_cycle(n_tcu: int, n_hsu: int = 0, *, stride: int = 22, lastcomm_regs: int = 2,
                 hsu_regs: int = 10, ncu_reads: tuple[int, ...] = (1, 6),
                 max_regs: int = 110, overhead_b: int = L3L4_B,
                 reconnect: bool = True) -> dict:
    """Bytes de UN ciclo de polling de una NCU, con el mismo troceo del driver."""
    reads: list[int] = []
    reads += split_reads(n_tcu * stride, max_regs)        # bloque compat
    reads += split_reads(n_tcu * lastcomm_regs, max_regs)  # lastComm (U32/TCU)
    reads += list(ncu_reads)                               # estado de la NCU
    reads += [min(hsu_regs, max_regs)] * n_hsu             # una lectura por HSU (bloque básico: 10 regs)

    m = TrafficMeter(overhead_b=overhead_b)
    if reconnect:
        m.connection()
    for n in reads:
        m.read(n)
    return m.snapshot(0)


def sample_lines(plant: str, ncu: str, n_tcu: int, n_hsu: int = 0) -> list[str]:
    """Line protocol representativo de un ciclo, en el formato que escribe el colector.

    Reproduce a mano lo que genera `Point.to_line_protocol()` para no arrastrar
    influxdb_client fuera del contenedor. `tools/test_trafico.py` comprueba que
    ambos coinciden cuando la librería está instalada.
    """
    lines = []
    for i in range(1, n_tcu + 1):
        # Los valores VARÍAN por TCU a propósito: si todas las líneas fueran
        # iguales el gzip las aplastaría y la estimación de subida saldría
        # optimista. Esta dispersión imita la de un campo real (mismo ángulo
        # ±0,5°, SoC y tensiones repartidas).
        tilt = -23.5 + (i % 17) * 0.06
        lines.append(
            f'tracker_status,ncu={ncu},plant={plant},tcu={i} '
            f'alarms="",battery_current={-300 + (i * 37) % 1100},'
            f'battery_voltage={12600 + (i * 53) % 800},bt_active=0,'
            f'comms_age_s={round(3 + (i * 7) % 27 + 0.1 * (i % 10), 1)},'
            f'health="ok",main_state=2,motor_current={(i * 91) % 1200},'
            f'panel_voltage={17000 + (i * 131) % 4000},safe_position=0,'
            f'soc={70 + (i * 11) % 30},soh={92 + i % 8},system_ok=1,'
            f'target_angle=-23.5,temp_battery={round(15 + (i * 3) % 20 + 0.1 * (i % 10), 1)},'
            f'temp_pcb={round(20 + (i * 5) % 25 + 0.1 * (i % 10), 1)},'
            f'tilt_angle={round(tilt, 2)}'
        )
    lines.append(
        f'ncu_status,ncu={ncu},plant={plant} '
        'alarm_any_snow=0,alarm_any_wind=0,battery_low=0,date_time=1755600000,'
        'gw1_alarm=0,gw2_alarm=0,ups_power_fault=0,wind_highest_level=0'
    )
    for h in range(1, n_hsu + 1):
        lines.append(
            f'meteo,hsu={h},ncu={ncu},plant={plant} '
            'alarm_com=0,alarm_snow=0,alarm_wind=0,snow_level=0,'
            'wind_direction=212,wind_level=0,wind_speed=4.7'
        )
    return lines


def cloud_cycle(n_tcu: int, n_hsu: int = 0, *, plant: str = "planta", ncu: str = "NCU1",
                http_overhead_b: int = HTTP_OVERHEAD_B, writes: int = 2) -> dict:
    """Bytes que subiría a la nube UN ciclo de una NCU (crudo y comprimido).

    `writes`: escrituras HTTP por ciclo (el colector hace una del bloque de
    trackers y otra del estado de NCU/meteo), porque la cabecera se paga en cada
    una.
    """
    m = TrafficMeter(http_overhead_b=http_overhead_b)
    lines = sample_lines(plant, ncu, n_tcu, n_hsu)
    corte = max(1, len(lines) - 1 - n_hsu) if writes > 1 else len(lines)
    m.cloud_write(lines[:corte])
    if writes > 1:
        m.cloud_write(lines[corte:])
    return m.snapshot(0)


def ncu_estimate(n_tcu: int, n_hsu: int = 0, *, interval_s: float = 30, **kw) -> dict:
    """Tráfico diario de una NCU: LAN de planta y subida a la nube."""
    mb_kw = {k: v for k, v in kw.items() if k in
             ("stride", "lastcomm_regs", "hsu_regs", "ncu_reads", "max_regs",
              "overhead_b", "reconnect")}
    cl_kw = {k: v for k, v in kw.items() if k in ("plant", "ncu", "http_overhead_b", "writes")}
    lan = modbus_cycle(n_tcu, n_hsu, **mb_kw)
    cloud = cloud_cycle(n_tcu, n_hsu, **cl_kw)
    cycles = 86400.0 / interval_s
    return {
        "tcus": n_tcu,
        "hsus": n_hsu,
        "interval_s": interval_s,
        "cycles_day": round(cycles, 1),
        "modbus_tx_cycle": lan["modbus_tx"],
        "lan_b_cycle": lan["lan_b"],
        "cloud_raw_b_cycle": cloud["cloud_raw_b"],
        "cloud_gz_b_cycle": cloud["cloud_gz_b"],
        "lan_mb_day": lan["lan_b"] * cycles / 1e6,
        "cloud_mb_day": cloud["cloud_gz_b"] * cycles / 1e6,
        "cloud_raw_mb_day": cloud["cloud_raw_b"] * cycles / 1e6,
    }


def plant_estimate(ncus: list[dict], *, interval_s: float = 30, **kw) -> dict:
    """Agrega el tráfico de todas las NCU de una planta.

    `ncus`: lista de dicts con `id`, `tcu_count` y `hsu_count` (el formato de
    `config/plants.yml`).
    """
    detail = []
    for n in ncus:
        e = ncu_estimate(int(n.get("tcu_count", 0)), int(n.get("hsu_count", 0)),
                         interval_s=interval_s, ncu=str(n.get("id", "NCU")), **kw)
        e["ncu"] = n.get("id", "NCU")
        detail.append(e)
    tot = {
        "ncus": len(detail),
        "tcus": sum(d["tcus"] for d in detail),
        "interval_s": interval_s,
        "lan_mb_day": sum(d["lan_mb_day"] for d in detail),
        "cloud_mb_day": sum(d["cloud_mb_day"] for d in detail),
        "cloud_raw_mb_day": sum(d["cloud_raw_mb_day"] for d in detail),
        "modbus_tx_day": sum(d["modbus_tx_cycle"] * d["cycles_day"] for d in detail),
    }
    tot["cloud_gb_month"] = tot["cloud_mb_day"] * 30 / 1000
    tot["lan_gb_month"] = tot["lan_mb_day"] * 30 / 1000
    tot["detail"] = detail
    return tot


# --- Malla Zigbee (NCU <-> TCU) --------------------------------------------
# El tráfico de la malla NO se puede medir por Modbus: la NCU sirve de su caché
# y no expone contadores de radio. Esto es un MODELO con los parámetros a la
# vista, para saber si un cambio de ritmo cabe en el aire (250 kbps, canal
# compartido por toda la planta). Validar en campo antes de tomarlo por bueno.
ZB_OVERHEAD_B = 41       # 802.15.4 MAC (~25) + NWK (~8) + APS (~8)
ZB_REQ_PAYLOAD_B = 12    # petición de estado de la NCU al TCU
ZB_RESP_PAYLOAD_B = 44   # respuesta con el bloque compat de 22 registros
ZB_RATE_BPS = 250_000
ZB_FRAME_FIXED_S = 0.0015  # CSMA/CA + ACK de nivel MAC por trama


def zigbee_estimate(n_tcu: int, *, cycle_s: float = 60, hops: float = 2.0,
                    retry_factor: float = 1.15) -> dict:
    """Tráfico y ocupación de aire de la malla de UN gateway.

    `hops`: saltos medios al coordinador (de las capturas de `cobertura-zigbee`,
    2–3 en El Burgo). Cada salto es una retransmisión: ocupa aire otra vez.
    `retry_factor`: reintentos por enlaces flojos.
    """
    frame_b = [ZB_OVERHEAD_B + ZB_REQ_PAYLOAD_B, ZB_OVERHEAD_B + ZB_RESP_PAYLOAD_B]
    per_poll_b = sum(frame_b) * hops * retry_factor
    frames_poll = 2 * hops * retry_factor
    airtime_s = (per_poll_b * 8 / ZB_RATE_BPS) + frames_poll * ZB_FRAME_FIXED_S
    polls_day = 86400.0 / cycle_s
    return {
        "tcus": n_tcu,
        "cycle_s": cycle_s,
        "hops": hops,
        "bytes_poll": round(per_poll_b, 1),
        "mb_day": n_tcu * per_poll_b * polls_day / 1e6,
        "airtime_cycle_s": round(n_tcu * airtime_s, 2),
        "airtime_pct": 100.0 * n_tcu * airtime_s / cycle_s,
    }
