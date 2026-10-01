#!/usr/bin/env python3
"""Maqueta de la API privada del panel web de la NCU, para probar el transporte.

El lector del panel se apoya en una cosa que no se puede comprobar leyendo el
codigo: que la cookie de sesion del login viaje de verdad en la segunda llamada.
Esto lo comprueba. Imita lo justo:

  POST /private_api/auth          -> 200 + Set-Cookie: sunner_auth=...   (o 401)
  GET  /private_api/initial_data  -> 200 + el volcado, SOLO con la cookie buena
                                     (401 sin ella)

Y ademas responde 405 a cualquier metodo de escritura: si alguien mete un PUT
contra el panel, la prueba lo ve.

    python3 api_server.py [puerto]      (por omision 15080)
"""
import json, os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PUERTO = int(sys.argv[1]) if len(sys.argv) > 1 else 15080
# Credenciales de la MAQUETA, inventadas a proposito: nada de esto se parece a
# una credencial de una NCU de verdad, que no entra en un repo ni en una prueba.
# Credenciales de la MAQUETA, inventadas a proposito y dichas en voz alta: no se
# parecen a las de ninguna NCU de verdad, que no entran en un repo ni en una
# prueba ni en un log.
USUARIO, CLAVE, GALLETA = 'usuario-de-maqueta', 'clave-de-maqueta', 'galleta-de-maqueta'
VOLCADO = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fixture_panel_ncu.json')


class Mano(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def _cuerpo(self, codigo, datos, galleta=None):
        b = json.dumps(datos).encode('utf-8')
        self.send_response(codigo)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b)))
        if galleta:
            self.send_header('Set-Cookie', 'sunner_auth=%s; Path=/' % galleta)
        self.end_headers()
        self.wfile.write(b)

    def _autenticado(self):
        return GALLETA in self.headers.get('Cookie', '')

    def do_POST(self):
        if self.path != '/private_api/auth':
            return self._cuerpo(404, {'error': 'no existe'})
        n = int(self.headers.get('Content-Length', 0))
        try:
            p = json.loads(self.rfile.read(n).decode('utf-8'))
        except Exception:
            return self._cuerpo(400, {'error': 'json malo'})
        if p.get('username') != USUARIO or p.get('password') != CLAVE:
            return self._cuerpo(401, {'error': 'no autorizado'})
        self._cuerpo(200, {'ok': True}, galleta=GALLETA)

    def do_GET(self):
        if self.path != '/private_api/initial_data':
            return self._cuerpo(404, {'error': 'no existe'})
        if not self._autenticado():
            return self._cuerpo(401, {'error': 'sin sesion'})
        with open(VOLCADO, encoding='utf-8') as f:
            self._cuerpo(200, json.load(f))

    # escribir no es cosa del lector: si aparece un PUT, que se vea
    def do_PUT(self):
        self._cuerpo(405, {'error': 'esta maqueta no escribe'})

    do_PATCH = do_PUT
    do_DELETE = do_PUT


if __name__ == '__main__':
    s = ThreadingHTTPServer(('127.0.0.1', PUERTO), Mano)
    print('maqueta de la API del panel NCU en 127.0.0.1:%d' % PUERTO, flush=True)
    s.serve_forever()
