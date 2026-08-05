# TCU Agente — API de solo lectura para la Toolbox web (piloto)

> Servicio pequeño que corre en el **PC de planta** y expone por HTTP el diagnóstico vía NCU, el comisionado y las HSUs de la planta, para consultarlos desde la página **Toolbox web** de la plataforma. **Solo lectura**: no existe ningún endpoint de escritura — escribir se sigue haciendo con la TCU Toolbox en local.

## Cómo funciona

- PowerShell puro (`TCU_Agente.ps1` + `TCU_Agente.bat`), sin instalar nada — igual que la toolbox.
- **Reutiliza la lógica de `TCU_Toolbox.ps1`** (cliente Modbus, mapas, bloque compacto de la NCU): un único origen de verdad. Debe estar la carpeta `tcu-toolbox` al lado (o apuntar `toolbox` en la config a su ruta), con los JSON de la planta en `plantas/`.
- Lecturas **vía NCU** (puerto 502, bloque compacto): diagnóstico de la planta completa en segundos, sin Zigbee.
- Escucha en `http://localhost:8585` y exige el **token** en la cabecera `X-Token` en todas las rutas.

## Puesta en marcha (piloto Ayora)

1. Copia las carpetas `tcu-toolbox` y `tcu-agente` al PC de planta (las de la release).
2. En `tcu-agente`, copia `agente_config.ejemplo.json` → `agente_config.json` y rellena: `planta` ("Ayora"), y un `token` largo aleatorio (es la llave: trátalo como una contraseña).
3. Primera vez en ese PC (una sola vez, como administrador): `netsh http add urlacl url=http://localhost:8585/ user=Todos`
4. Doble clic en `TCU_Agente.bat` — debe decir "TCU Agente v1.0 - planta 'Ayora'".
5. Túnel: instala [cloudflared](https://github.com/cloudflare/cloudflared/releases/latest) (un solo .exe) y en otra ventana:
   `cloudflared tunnel --url http://localhost:8585`
   Te dará una URL `https://xxxx.trycloudflare.com` (cambia en cada arranque; para URL fija hace falta un túnel con nombre y un dominio en Cloudflare — fase 2).
6. En la plataforma → **Toolbox web**: pega la URL del túnel y el token, PING, y a diagnosticar. El botón "Guardar en Histórico" mete el diagnóstico en la misma tabla que los JSON subidos a mano (plano + diff incluidos).

## Endpoints

| Ruta | Qué devuelve |
|---|---|
| `GET /ping` | planta, versión del agente/toolbox/mapa y hora del PC |
| `GET /diagnostico` | diagnóstico de la planta completa vía NCU, **mismo formato que el JSON de la toolbox** (`tipo: diagnostico_tcu`) — subible al Histórico tal cual |
| `GET /comisionado` | estado de comisionado (bits 4:3 del bloque compacto) por TCU |
| `GET /hsus` | HSUs de cada NCU con salud y viento/nieve |

## Seguridad

- **Solo GET y solo lecturas** (FC03): el código no contiene ninguna escritura Modbus.
- Token obligatorio (401 sin él); el agente escucha solo en localhost y sale al mundo únicamente por el túnel.
- `agente_config.json` (con el token) **no se sube al repo** (gitignore) — solo el ejemplo.
- Config extra para pruebas: `puerto_ncu` (simulador), `dir_datos` (carpeta plantas alternativa), `timeout_ms`.
