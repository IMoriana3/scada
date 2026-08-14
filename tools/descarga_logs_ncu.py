#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Descarga nocturna de los logs diarios de las NCU (webserver Sunner).

API descubierta en El Burgo/Ayora (13-08-2026, capturada con DevTools):
  GET http://<ip>/private_api/csv/<AAAA-MM-DD>            -> índice del día (JSON)
  GET http://<ip>/private_api/csv/<AAAA-MM-DD>/download   -> ZIP con TODOS los CSV del día
  Autenticación: cookie de sesión  sunner_auth=<token>  (la da el login del panel).

LOGIN AUTOMÁTICO: usuario admin, contraseña NCU<nn> (el número de la NCU,
p.ej. NCU05) — el esquema lo dio Ignacio el 14-08 (en el panel "ADMINISTRATOR"
es el rol, no el usuario). La ruta exacta del POST
no está capturada, así que se prueban las candidatas habituales y la buena se
reconoce por la señal inequívoca: la respuesta trae Set-Cookie sunner_auth.
Si el panel usara otra ruta, pasa el token a mano con --cookie / SUNNER_AUTH
(y captura el cURL del login para añadir la ruta a CANDIDATOS).

Uso:
  python3 descarga_logs_ncu.py --ncus ncus.json                           # ayer, login solo
  python3 descarga_logs_ncu.py --ncus ncus.json --fecha 2026-08-13
  python3 descarga_logs_ncu.py --ncus ncus.json --desde 2026-08-01 --hasta 2026-08-13
  python3 descarga_logs_ncu.py --ip 192.168.4.45 --ncu 05 --fecha 2026-08-13
  python3 descarga_logs_ncu.py --ncus ncus.json --cookie <token>          # sesión a mano

ncus.json:  [{"ncu":"05","ip":"192.168.4.45"}, {"ncu":"06","ip":"192.168.4.46"}]
            (admite "usuario" y "pass" por NCU si alguna no sigue el esquema)

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
import argparse, datetime as dt, io, json, os, re, sys, time, urllib.parse, urllib.request, urllib.error, zipfile

# rutas de login candidatas: la buena se reconoce porque responde con la cookie
CANDIDATOS=[("/private_api/login","json"),("/private_api/auth","json"),
            ("/api/login","json"),("/login","form")]
CLAVES=[("username","password"),("user","password")]

def login(ip, usuario, clave, log):
    for ruta,forma in CANDIDATOS:
        for ku,kp in CLAVES:
            try:
                if forma=="json":
                    datos=json.dumps({ku:usuario,kp:clave}).encode();ct="application/json"
                else:
                    datos=urllib.parse.urlencode({ku:usuario,kp:clave}).encode();ct="application/x-www-form-urlencoded"
                req=urllib.request.Request("http://%s%s"%(ip,ruta),data=datos,
                    headers={"Content-Type":ct,"Accept":"application/json, */*",
                             "User-Agent":"factiun-descarga-logs/1.0"})
                with urllib.request.urlopen(req,timeout=15) as r:
                    for sc in (r.headers.get_all("Set-Cookie") or []):
                        m=re.search(r"sunner_auth=([^;]+)",sc)
                        if m:
                            log("login OK en %s (%s como %s)"%(ip,ruta,usuario))
                            return m.group(1)
            except Exception:
                continue
    log("FALLO login en %s como %s: ninguna ruta candidata devolvió sunner_auth — "
        "captura el cURL del login del panel (o pasa --cookie)"%(ip,usuario))
    return None

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
                # sesión rechazada: que el llamante haga login y reintente una vez
                return "auth"
            if e.code == 404:
                # la retención de la NCU tiene huecos (visto en el panel: días que ya no
                # están); un 404 en backfill es "ese día ya no existe", no un error a reintentar
                log("NO ESTÁ %s: la NCU ya no guarda ese día (404) — lo que no se baja a tiempo, se pierde"
                    % etiqueta)
                return False
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
                   help="token sunner_auth a mano (si no, el script hace login solo)")
    p.add_argument("--usuario", default="admin")
    p.add_argument("--password", help="contraseña común (por defecto NCU<nn> por cada NCU)")
    p.add_argument("--destino", default="logs-ncu")
    a = p.parse_args()

    ncus = json.load(open(a.ncus, encoding="utf-8")) if a.ncus else \
           [{"ncu": a.ncu or "?", "ip": a.ip}] if a.ip else \
           sys.exit("Di las NCUs: --ncus fichero.json  o  --ip ... --ncu ...")
    def usuarioDe(n): return n.get("usuario") or a.usuario
    def claveDe(n):   return n.get("pass") or a.password or ("NCU"+str(n.get("ncu","")).zfill(2))

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

    galletas = {}                         # sesión por IP, para no re-loguear en cada día
    def sesion(n, forzar=False):
        ip = n["ip"]
        if forzar or ip not in galletas:
            galletas[ip] = a.cookie or login(ip, usuarioDe(n), claveDe(n), log)
            if forzar and a.cookie:       # la cookie a mano caducó: probar el login igualmente
                galletas[ip] = login(ip, usuarioDe(n), claveDe(n), log)
        return galletas[ip]

    bien = mal = 0
    for fecha in fechas:
        for n in ncus:
            tok = sesion(n)
            res = tok and descarga_dia(n["ip"], str(n["ncu"]), fecha, tok, a.destino, log)
            if res == "auth":             # sesión caducada a mitad: re-login y un reintento
                tok = sesion(n, forzar=True)
                res = tok and descarga_dia(n["ip"], str(n["ncu"]), fecha, tok, a.destino, log)
                if res == "auth":
                    log("FALLO NCU%s_%s: la NCU rechaza la sesión incluso recién logueada" % (n["ncu"], fecha))
                    res = False
            bien, mal = bien + (res is True), mal + (res is not True)
    log("fin: %d bien, %d mal" % (bien, mal))
    sys.exit(1 if mal else 0)

if __name__ == "__main__":
    main()
