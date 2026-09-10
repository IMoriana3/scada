# Descarga de logs de NCU

> Baja de cada NCU el **ZIP con todos los CSV del día** que graba en su disco (la TCU cada ~10 s, las estaciones cada ~5 s, la propia NCU cada segundo) y lo deja listo para arrastrar a `importar-logs.html`. Sin Python: PowerShell puro, el de Windows.

Es el script con el que **ya está automatizada Ayora**, sacado del webserver Sunner **real** (capturado con DevTools, 13/14‑08‑2026) — no de suposiciones:

```
GET  http://<ip>/private_api/csv/<AAAA-MM-DD>            -> índice del día (JSON)
GET  http://<ip>/private_api/csv/<AAAA-MM-DD>/download   -> ZIP con TODOS los CSV del día
```
El login es un POST a la API (se prueban las rutas candidatas) y la señal de éxito es la cookie `sunner_auth`, que se usa como sesión por NCU.

## Uso: doble clic y menú

`Descarga-Logs.bat` abre el menú:

```
1) Descargar AYER - todas las NCU de la planta
2) Backfill: un rango de fechas
3) Un día concreto
4) Una sola NCU, a mano (IP + número)
5) Programar la descarga de cada noche (00:30, automática)
6) Quitar la programación nocturna
7) Editar la lista de NCUs (ncus.json)
8) Generar ncus.json desde una topología de la toolbox (carpeta plantas\)
```

**La primera vez en una planta: opción 8.** Elige su `plantas\<planta>.json` (el zip de la toolbox lo deja ahí) y sale el `ncus.json` con **una línea por NCU** — número e IP — sin teclear nada: las 21 de San José, las 16 de Ayora. Los dos gateways de una NCU comparten IP, así que sale una NCU, no dos.

Con argumentos (para la tarea programada o scripts):
```powershell
.\descarga_logs_ncu.ps1 -Ncus ncus.json                              # ayer, todas las NCU
.\descarga_logs_ncu.ps1 -Ncus ncus.json -Fecha 2026-09-08
.\descarga_logs_ncu.ps1 -Topologia .\plantas\24019-san-jose.json     # sin ncus.json: la lista sale de la topología
.\descarga_logs_ncu.ps1 -Ip 10.21.236.1 -Ncu 01 -Desde 2026-09-01 -Hasta 2026-09-08
```

## Credenciales

Por defecto vale el **esquema de Sunner**: usuario `admin`, contraseña `NCU<nn>` (el número de la NCU). Ayora lo sigue: no pregunta nada.

Si una planta **no** lo sigue, la primera descarga te pide usuario y contraseña con entrada enmascarada y los guarda en `credenciales.<subred>.xml` junto al script, **cifrados con DPAPI para tu usuario de Windows**: copiados a otro PC o abiertos por otro usuario no valen nada. La planta se reconoce por la subred de sus NCU (`10.21.236` = San José), así que no hay nada que configurar; la tarea nocturna, que corre con tu mismo usuario, los lee sola. Para cambiarlos, borra ese `.xml` y vuelve a lanzar.

Si prefieres, `ncus.json` admite `"usuario"` y `"pass"` por NCU, y hay `-Usuario`/`-Password`/`-Cookie`; **pero eso va en claro**: mejor el `.xml` cifrado. Nada de esto va nunca al repo (`.gitignore`).

## Lo que deja

```
logs-ncu\NCU01\NCU01_2026-09-08.zip          <- el ZIP tal cual lo sirve la NCU
              NCU01_2026-09-08.indice.json   <- el índice del día
logs-ncu\descargas.log                       <- qué se bajó, qué no y por qué
```
Organizado por NCU; el nombre conserva el prefijo `NCU<nn>`, que es de donde el importador saca la etiqueta. **Los ZIP se arrastran tal cual a `importar-logs.html`.**

## Notas de campo (medidas, no supuestas)

- Los días que la NCU **ya no guarda** responden **500** (no 404): se anotan como «NO ESTA» y no se reintentan. Lo que no se baja a tiempo, se pierde: por eso la tarea nocturna.
- Un ZIP ya bajado (y no vacío) **no se vuelve a pedir**; se puede relanzar las veces que haga falta. Lo bajado antes «en plano» se recoloca solo en su carpeta de NCU.
- Un 401/403 relanza el login una vez; si aun así rechaza, lo dice.
- La descarga va con `$ProgressPreference = SilentlyContinue`: en PowerShell 5.1 la barra de progreso hacía las descargas ×10 más lentas.
- La tarea nocturna (00:30) corre con tu usuario: el PC tiene que estar encendido y con sesión iniciada (bloqueado vale). Si la programaste desde otra carpeta, vuelve a programarla desde esta para que use este script.
