#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Descarga nocturna de los logs diarios de las NCU (webserver Sunner).

API descubierta en El Burgo/Ayora (13-08-2026, capturada con DevTools):
  GET http://<ip>/private_api/csv/<AAAA-MM-DD>            -> índice del día (JSON)
  GET http://<ip>/private_api/csv/<AAAA-MM-DD>/download   -> ZIP con TODOS los CSV del día
  Autenticación: cookie de sesión  sunner_auth=<token>  (la da el login del panel).

El login automático está PENDIENTE de capturar (cierra sesión y vuelve a entrar
con la pestaña Red abierta y copia el cURL del POST). Hasta entonces, el token
se pasa con --cookie o con la variable de entorno SUNNER_AUTH.

Uso:
  python3 descarga_logs_ncu.py --ncus ncus.json --cookie <token>          # ayer
  python3 descarga_logs_ncu.py --ncus ncus.json --fecha 2026-08-13
  python3 descarga_logs_ncu.py --ncus ncus.json --desde 2026-08-01 --hasta 2026-08-13
  python3 descarga_logs_ncu.py --ip 192.168.4.45 --ncu 05 --fecha 2026-08-13

ncus.json:  [{"ncu":"05","ip":"192.168.4.45"}, {"ncu":"06","ip":"192.168.4.46"}]

Salida (en --destino, por defecto ./logs-ncu):
  NCU05_2026-08-13.zip          el ZIP tal cual lo sirve la NCU (sin tocar: el hash
                                de cada CSV lo calculará el importador/agente)
  NCU05_2026-08-13.indice.json  el índice del día, verbatim, como manifiesto
  descargas.log                 una línea por intento, con resultado y tamaño

El ZIP se arrastra tal cual a factiun-cartera/importar-logs.html (acepta los
nombres sin prefijo NCU<n>_). Cuando el agente del PC de planta tenga la subida
nocturna (CONTRATO), este script es su pieza de descarga.

Solo librería estándar: corre en el PC de planta, en un portátil o en el collector.
"""
import argparse, datetime as dt, io, json, os, sys, time, urllib.request, urllib.error, zipfile

def peticion(url, cookie, timeout=120):
    req = urllib.request.Request(url, headers={
        "Accept": "application/json, application/zip, text/plain, */*",
        "Cookie": "sunner_auth=" + cookie,
        "User-Agent": "factiun-descarga-logs/1.0",
    })
    return urllib.request.urlopen(req, timeout=timeout)

def descarga_dia(ip, ncu, fecha, cookie, destino, log):
    base = "http://%s/private_api/csv/%s" % (ip, fecha)
    etiqueta = "NCU%s_%s" % (ncu, fecha)
    zpath = os.path.join(destino, etiqueta + ".zip")
    if os.path.exists(zpath) and os.path.getsize(zpath) > 0:
        log("YA %s (existe, %d bytes) — no se re-descarga" % (etiqueta, os.path.getsize(zpath)))
        return True

    # 1) índice del día (manifiesto): si falla no es fatal, el ZIP manda
    indice, n_indice = None, None
    try:
        with peticion(base, cookie, timeout=30) as r:
            indice = r.read()
        try:
            j = json.loads(indice)
            # forma desconocida a propósito: se cuenta lo que parezca lista de ficheros
            n_indice = len(j) if isinstance(j, list) else \
                       len(j.get("files", j.get("csv", []))) if isinstance(j, dict) else None
        except Exception:
            pass
    except Exception as e:
        log("AVISO %s: índice no disponible (%s)" % (etiqueta, e))

    # 2) el ZIP del día entero, con reintentos
    for intento in range(1, 4):
        try:
            t0 = time.time()
            with peticion(base + "/download", cookie, timeout=600) as r:
                datos = r.read()
            # ¿es un ZIP de verdad y se puede leer entero?
            with zipfile.ZipFile(io.BytesIO(datos)) as z:
                nombres = z.namelist()
                if z.testzip() is not None:
                    raise ValueError("ZIP corrupto (testzip)")
            if not nombres:
                raise ValueError("ZIP vacío")
            tmp = zpath + ".parte"
            with open(tmp, "wb") as f:
                f.write(datos)
            os.replace(tmp, zpath)              # escritura atómica: nunca un ZIP a medias
            if indice:
                with open(os.path.join(destino, etiqueta + ".indice.json"), "wb") as f:
                    f.write(indice)
            aviso = "" if n_indice in (None, len(nombres)) else \
                    " · OJO: el índice decía %s ficheros" % n_indice
            log("OK %s: %d ficheros, %.1f MB en %.1f s%s"
                % (etiqueta, len(nombres), len(datos) / 1048576.0, time.time() - t0, aviso))
            return True
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                log("FALLO %s: sesión rechazada (%s) — la cookie sunner_auth ha caducado; "
                    "renueva con --cookie (login automático pendiente de capturar)" % (etiqueta, e.code))
                return False                     # sin sesión no hay reintento que valga
            log("intento %d/3 %s: HTTP %s" % (intento, etiqueta, e.code))
        except Exception as e:
            log("intento %d/3 %s: %s" % (intento, etiqueta, e))
        time.sleep(5 * intento)
    log("FALLO %s tras 3 intentos" % etiqueta)
    return False

def main():
    p = argparse.ArgumentParser(description="Descarga los logs diarios de las NCU (ZIP por NCU y día)")
    p.add_argument("--ncus", help="JSON con [{'ncu':'05','ip':'192.168.4.45'},...]")
    p.add_argument("--ip"), p.add_argument("--ncu")
    p.add_argument("--fecha", help="AAAA-MM-DD (por defecto: ayer)")
    p.add_argument("--desde"), p.add_argument("--hasta", help="rango para backfill")
    p.add_argument("--cookie", default=os.environ.get("SUNNER_AUTH", ""),
                   help="token sunner_auth (o variable de entorno SUNNER_AUTH)")
    p.add_argument("--destino", default="logs-ncu")
    a = p.parse_args()

    if not a.cookie:
        sys.exit("Falta la sesión: --cookie <token> o SUNNER_AUTH (es la cookie sunner_auth del panel)")
    ncus = json.load(open(a.ncus, encoding="utf-8")) if a.ncus else \
           [{"ncu": a.ncu or "?", "ip": a.ip}] if a.ip else \
           sys.exit("Di las NCUs: --ncus fichero.json  o  --ip ... --ncu ...")

    if a.desde or a.hasta:
        d0 = dt.date.fromisoformat(a.desde or a.hasta)
        d1 = dt.date.fromisoformat(a.hasta or a.desde)
        fechas = [(d0 + dt.timedelta(n)).isoformat() for n in range((d1 - d0).days + 1)]
    else:
        fechas = [a.fecha or (dt.date.today() - dt.timedelta(1)).isoformat()]

    os.makedirs(a.destino, exist_ok=True)
    flog = open(os.path.join(a.destino, "descargas.log"), "a", encoding="utf-8")
    def log(msg):
        linea = "%s %s" % (dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg)
        print(linea); flog.write(linea + "\n"); flog.flush()

    bien = mal = 0
    for fecha in fechas:
        for n in ncus:
            ok = descarga_dia(n["ip"], str(n["ncu"]), fecha, a.cookie, a.destino, log)
            bien, mal = bien + ok, mal + (not ok)
    log("fin: %d bien, %d mal" % (bien, mal))
    sys.exit(1 if mal else 0)

if __name__ == "__main__":
    main()
