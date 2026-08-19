"""Driver base (interfaz) y driver Modbus TCP contra la NCU real.

La NCU expone TODOS sus TCUs en su propio espacio Modbus (bloque compat
30500 + 22*i), así que basta UNA conexión TCP por NCU.

SOLO LECTURA: este driver no implementa escrituras. El rango 40000+
(safe positions, modos, target angle) queda fuera a propósito.
"""
import time
from abc import ABC, abstractmethod

from decode import decode_tcu_block, decode_alarms, regs_to_u32


class NCUDriver(ABC):
    """Interfaz común: el collector no sabe si habla con hierro o simulación."""

    def __init__(self, ncu_cfg: dict, mmap: dict, word_order: str = "big", meter=None):
        self.cfg = ncu_cfg
        self.mmap = mmap
        self.word_order = word_order
        self.meter = meter          # TrafficMeter opcional (medidor de tráfico)

    # --- contabilidad de tráfico (no cuesta nada si no hay medidor) ---
    def _count_read(self, n_regs: int):
        if self.meter:
            self.meter.read(n_regs)

    def _count_connection(self):
        if self.meter:
            self.meter.connection()

    @abstractmethod
    async def connect(self): ...

    @abstractmethod
    async def close(self): ...

    @abstractmethod
    async def read_trackers(self) -> list[dict]:
        """Lista de dicts: {tcu, fields, alarms, last_comm, comms_age_s}"""

    @abstractmethod
    async def read_ncu(self) -> dict: ...

    @abstractmethod
    async def read_meteo(self) -> list[dict]: ...


class ModbusNCUDriver(NCUDriver):
    def __init__(self, ncu_cfg, mmap, word_order="big", timeout=3, max_regs=110, meter=None):
        super().__init__(ncu_cfg, mmap, word_order, meter)
        self.timeout = timeout
        self.max_regs = max_regs
        self.client = None

    async def connect(self):
        from pymodbus.client import AsyncModbusTcpClient
        self.client = AsyncModbusTcpClient(
            self.cfg["host"], port=self.cfg.get("port", 502), timeout=self.timeout
        )
        await self.client.connect()
        self._count_connection()

    async def close(self):
        if self.client:
            self.client.close()

    # pymodbus renombró el argumento de la unidad en la 3.9: `slave` pasó a `device_id`.
    # requirements pide >=3.6 sin tope, así que una instalación de hoy trae la 3.14 y la llamada
    # revienta con TypeError en la primera lectura. Se mira UNA vez la firma real y se usa la que
    # haya, que es mejor que congelar la versión.
    def _kw_unidad(self) -> str:
        if getattr(self, "_kwu", None) is None:
            import inspect
            params = inspect.signature(self.client.read_holding_registers).parameters
            self._kwu = "device_id" if "device_id" in params else "slave"
        return self._kwu

    async def _read(self, addr: int, count: int) -> list[int]:
        kw = {"count": count, self._kw_unidad(): self.cfg.get("unit_id", 1)}
        rr = await self.client.read_holding_registers(addr, **kw)
        # Se contabiliza la transacción tanto si responde como si da excepción:
        # una respuesta de error también viaja por la LAN (y por el 4G).
        self._count_read(count)
        if rr.isError():
            raise IOError(f"Modbus error @{addr} x{count}: {rr}")
        return rr.registers

    async def _read_span(self, addr: int, count: int) -> list[int]:
        """Lectura troceada respetando max_regs por transacción."""
        regs = []
        remaining, a = count, addr
        while remaining > 0:
            n = min(self.max_regs, remaining)
            regs += await self._read(a, n)
            a += n
            remaining -= n
        return regs

    async def read_trackers(self) -> list[dict]:
        tc = self.mmap["tcu_compat"]
        n = self.cfg["tcu_count"]
        stride = tc["stride"]
        # bloque de datos contiguo: n TCUs x 22 regs
        data = await self._read_span(tc["base"], n * stride)
        # timestamps lastComm: n x U32
        lc_cfg = self.mmap["tcu_lastcomm"]
        lc = await self._read_span(lc_cfg["base"], n * 2)
        now = time.time()
        out = []
        for i in range(n):
            regs = data[i * stride:(i + 1) * stride]
            fields = decode_tcu_block(regs, tc["fields"], self.word_order)
            alarms = decode_alarms(fields.get("alarms1", 0), fields.get("alarms2", 0),
                                   self.mmap["alarm_bits"])
            last_comm = regs_to_u32(lc[i * 2], lc[i * 2 + 1], self.word_order)
            out.append({
                "tcu": i + 1,
                "fields": fields,
                "alarms": alarms,
                "last_comm": last_comm,
                "comms_age_s": round(now - last_comm, 1) if last_comm > 0 else None,
            })
        return out

    async def read_ncu(self) -> dict:
        regs_cfg = self.mmap["ncu"]["registers"]
        out = {}
        # 30002 y 30100..30105: dos lecturas pequeñas
        hsu_g = (await self._read(regs_cfg["hsu_global"]["addr"], 1))[0]
        blk = await self._read(30100, 6)
        from decode import extract_bits
        for key, spec in regs_cfg.items():
            if spec["type"] == "u32":
                v = regs_to_u32(blk[spec["addr"] - 30100], blk[spec["addr"] - 30100 + 1],
                                self.word_order)
                out[key] = v
                continue
            raw = hsu_g if spec["addr"] == 30002 else blk[spec["addr"] - 30100]
            for bit_name, (lsb, msb) in spec.get("bits", {}).items():
                out[bit_name] = extract_bits(raw, lsb, msb)
        return out

    async def read_meteo(self) -> list[dict]:
        h = self.mmap["hsu_ext"] if self.cfg.get("hsu_extended") else self.mmap["hsu"]
        n = self.cfg.get("hsu_count", 0)
        if n == 0:
            return []
        out = []
        for i in range(n):
            base = h["base"] + i * h["stride"]
            regs = await self._read(base, min(h["stride"], 30))
            fields = decode_tcu_block(regs, h["fields"], self.word_order)
            out.append({"hsu": i + 1, "fields": fields})
        return out
