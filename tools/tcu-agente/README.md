# TCU Agente — la Toolbox en remoto (piloto Ayora)

> Servicio pequeño que corre en el **PC de planta** y expone por HTTP las operaciones de la toolbox para la página **Toolbox web** de la plataforma: lecturas vía NCU (diagnóstico, comisionado, HSUs), **vigilante de alarmas** que avisa a la plataforma, **sincronización bajo demanda** y — solo si se habilita expresamente — **comandos de escritura** con doble confirmación y auditoría.

## Cómo funciona

- PowerShell puro (`TCU_Agente.ps1` + `TCU_Agente.bat`), sin instalar nada — igual que la toolbox.
- **Reutiliza la lógica de `TCU_Toolbox.ps1`** (cliente Modbus, mapas, bloque compacto de la NCU): un único origen de verdad. Debe estar la carpeta `tcu-toolbox` al lado (o apuntar `toolbox` en la config a su ruta), con los JSON de la planta en `plantas/`.
- Mientras el SAT registra, cada pase ocupa unos segundos y en ese rato el agente **no atiende peticiones** — igual que la toolbox no deja hacer otra cosa mientras registra.
- ⚠️ **Las dos carpetas van juntas.** El agente no copia la lógica: la extrae del `.ps1` de la toolbox buscando nombres de función. Si mezclas un agente viejo con una toolbox nueva (o al revés), no arranca — y te dirá exactamente qué le falta. Copia siempre las dos de la **misma release**. La suite de la toolbox comprueba en cada cambio que esas marcas siguen existiendo, así que el desajuste se detecta antes de publicar (pasó una vez: la v11.8 eliminó `Rango-Tcus` y el agente v2.0 dejó de arrancar).
- Lecturas **vía NCU** (puerto 502, bloque compacto): diagnóstico de la planta completa en segundos, sin Zigbee.
- Escucha en `http://localhost:8585` y exige el **token** en la cabecera `X-Token` en todas las rutas.

## Cómo se prueba

Sin planta, en cualquier PC (es lo que corre en cada cambio):

```bash
cd ../tcu-toolbox/tests
python3 mb_server.py &                      # NCU simulada en 127.0.0.1:15020
pwsh -NoProfile -File test_agente.ps1       # 33 comprobaciones
```

Monta una instalación de campo en miniatura en una carpeta temporal, **arranca
este agente de verdad** y le pide todas las rutas: lecturas, auditoría con
preset, las tres escrituras y el SAT completo —comprobando que graba los tres
CSV del anexo con su cabecera—. Al terminar lo para y borra la carpeta.

En planta, antes de dar la URL a nadie: **PING** desde la web debe decir la
planta, la versión del agente y la de la toolbox, y las dos tienen que ser de la
**misma release**.

## Puesta en marcha (piloto Ayora)

1. Copia las carpetas `tcu-toolbox` y `tcu-agente` al PC de planta (las de la release).
2. En `tcu-agente`, copia `agente_config.ejemplo.json` → `agente_config.json` y rellena: `planta` ("Ayora"), y un `token` largo aleatorio (es la llave: trátalo como una contraseña).
3. Primera vez en ese PC (una sola vez, como administrador): `netsh http add urlacl url=http://localhost:8585/ user=Todos`
4. Doble clic en `TCU_Agente.bat` — debe decir "TCU Agente v2.6 - planta 'Ayora'".
5. Túnel: instala [cloudflared](https://github.com/cloudflare/cloudflared/releases/latest) (un solo .exe) y en otra ventana:
   `cloudflared tunnel --url http://localhost:8585`
   Te dará una URL `https://xxxx.trycloudflare.com` (cambia en cada arranque; para URL fija hace falta un túnel con nombre y un dominio en Cloudflare — fase 2).
6. En la plataforma → **Toolbox web**: pega la URL del túnel y el token, PING, y a diagnosticar. El botón "Guardar en Histórico" mete el diagnóstico en la misma tabla que los JSON subidos a mano (plano + diff incluidos).

## Endpoints

**Selección (v2.7): `?ncus=`, `?tcus=` y `?gw=` valen en *todas* las rutas que
recorren la planta**, no solo en `/leer` y `/inventario`. Se aplican en el punto
por donde pasan todas — la lista de NCUs y la de TCUs de cada una — así que
ninguna ruta se los salta:

| Parámetro | Ejemplo | Qué acota |
|---|---|---|
| `ncus` | `1,3-5` | sobre qué NCUs se trabaja. Vacío = todas. Una NCU que no existe da error, no "todas" |
| `tcus` | `10,22,30-40` · `12/10, 15/5-12` | qué TCUs de cada NCU. Con prefijo, cada tramo lleva la suya |
| `gw`   | `504` | solo las TCUs de ese gateway |

El filtro dura **lo que dura la petición**: el vigilante de alarmas y el
registro SAT corren entre peticiones y siguen viendo la planta entera.

Lectura (GET, siempre disponibles):

| Ruta | Qué devuelve |
|---|---|
| `/ping` | planta, versiones, hora del PC, lista de NCUs con sus rangos, **los gateways que existen** (para ofrecerlos en un desplegable) y si la escritura está habilitada |
| `/diagnostico` | diagnóstico de la planta completa vía NCU, **mismo formato que el JSON de la toolbox** — subible al Histórico tal cual. Columnas **NCU · GW · TCU** |
| `/comisionado` | estado de comisionado (bits 4:3 del bloque compacto) por TCU |
| `/hsus` | HSUs de cada NCU con salud y viento/nieve |
| `/sincronizar` | lee toda la planta y **sube él mismo el diagnóstico al Histórico** (requiere credenciales Supabase en la config) |
| `/baterias` | SoC, SoH, tensiones, corrientes y temperaturas de toda la planta, con la auditoría — **del diagnóstico, sin lecturas extra** |
| `/inventario?tcus=&gw=` | FW, nº de serie, MAC, HW y fecha de fabricación. ⚠️ **Lenta**: va TCU a TCU por Zigbee, minutos en una planta entera. Acotarla con `tcus` o `gw` la hace usable |
| `/plan-firmware?objetivo=v1.6.0` | el plan por ventanas del updater (qué abrir, qué pegar, cuánto tarda) — hace el inventario primero, así que hereda su lentitud |
| `/leer?vars=41010,41111&tcus=1-20&gw=504` | leer variables, como la pestaña *Leer variable*. `vars` admite el prefijo (`41010`); `tcus` admite `12/10, 15/5-12`; `gw` filtra por gateway |
| `/cierre` | las TCUs actualizadas que aún no están cerradas, leído del disco de **este** PC |
| `/trabajos` | los trabajos guardados en `trabajos/` de este PC |
| `/sat` | estado del ensayo SAT: si está registrando, hasta cuándo, cuántos pases lleva y los ficheros de la carpeta |
| `/sat/descargar?f=` | un fichero del ensayo, tal cual (solo nombres de esa carpeta: no admite rutas) |

**Auditoría (POST, no depende de `permitir_escritura`)**: `/auditoria`. Va en POST solo porque **el preset viaja en el cuerpo**; no escribe nada. Cuerpo: `{"preset":[{"variable":"41010 longitud [deg]","valor":"-1.685"}],"ncu":1,"tcus":"1-20"}`. Devuelve **solo las desviaciones**, con el valor esperado, el leído y si además es un valor imposible para esa variable.

**SAT (POST, no depende de `permitir_escritura`)**: `/sat/iniciar` y `/sat/parar`. No tocan los seguidores — arrancan y paran un registro que se graba **en este PC**.

| | |
|---|---|
| Por qué aquí y no en la nube | El ensayo son **días** de muestreo continuo. Si se cae el túnel o se cierra el navegador, el registro sigue. Escribe a disco en cada pase y en ficheros diarios: si el PC se reinicia al cuarto día, lo registrado sigue ahí y el agente **reanuda solo** el ensayo al volver a arrancar. |
| Dónde | `informes/sat_<planta>/` de la carpeta de la toolbox — la **misma** que usa el botón INICIAR REGISTRO de la pestaña SAT, con el mismo formato de CSV. |
| El veredicto | Se emite con **ANALIZAR Y EMITIR** en la toolbox de este PC, sobre esos mismos ficheros. Desde la web se pueden descargar, pero el análisis (D.1.1, D.3.4, D.4) no está en remoto. |
| Cuerpo de `/sat/iniciar` | `{"duracion":7,"unidad":"dias","int_tcu":60,"int_comms":15}` — `unidad` admite `dias`, `horas` o `minutos`. |

Escritura (POST, solo con `"permitir_escritura": true`; el cuerpo debe llevar `"confirmar": true` y `tcus`):

`tcus` admite **la misma gramática que la toolbox**: `1-75`, `10,22,30-40` o `12/10, 15/5-12` — con la NCU delante de cada tramo, y entonces el campo `ncu` sobra porque lo dice la propia selección. Cada fila de la respuesta lleva su `ncu`.

| Ruta | Qué hace |
|---|---|
| `/modo` | aplicar OFF/MANUAL/AUTO (verificado por efecto en 30001) |
| `/limpiar-alarmas` | desenclavar alarmas (40007 bit 13) |
| `/stow` · `/unstow` | activar/quitar safe position (42000, verificado) |
| `/comisionado` | fijar estado de comisionado (40000 bits 7:5, verificado) |
| `/reloj` | sincronizar el reloj de las TCUs con el PC de planta |
| `/nvm` | guardar en NVM (40007 bit 15) |
| `/escribir-lote` | varias variables de una pasada (`"valores":[{"variable":"41010","valor":"-1.685"},…]`). **Bloquea la identidad de red** (esclavo, PAN ID, clave): dos TCUs con el mismo esclavo hacen desaparecer a una de las dos de la Zigbee |
| `/escribir-csv` | `"csv":"NCU;TCU;variable;valor\n8;29;41010;-1.685\n15;3;41111;55"` — cada TCU con lo suyo, y puede cruzar NCUs |
| `/escribir` | escribir una variable del mapa (verificada, con "antes → después"; **los registros de comando están bloqueados** aquí — solo por los endpoints dedicados) |

El **TEST DE MOTOR no existe en remoto** a propósito: mover motores requiere a alguien mirando el seguidor — se hace con la toolbox en local.

## Vigilante de alarmas

Cada `intervalo_vigilancia_min` (default 5, 0 = apagado) el agente lee la planta y, cuando una TCU/NCU/HSU **entra en ALARMA** (o se recupera), inserta un aviso en la tabla `alertas` de Supabase — visible en el panel "🔔 Alertas" del Histórico. En el primer barrido tras arrancar avisa de las alarmas ya activas.

## Supabase (alertas, acciones y sincronización)

Crea un usuario dedicado en Supabase Auth (p. ej. `agente@factiun.com`) y pon sus credenciales en la config (`supabase_email`/`supabase_pass`). Y una vez, en el SQL Editor:

```sql
create table if not exists alertas (
  id uuid primary key default gen_random_uuid(),
  planta text not null, fecha timestamptz not null default now(),
  ncu text, tcu text, salud text, texto text
);
alter table alertas enable row level security;
create policy "alertas leer"   on alertas for select to authenticated using (true);
create policy "alertas crear"  on alertas for insert to authenticated with check (true);
create policy "alertas borrar" on alertas for delete to authenticated using (true);

create table if not exists acciones (
  id uuid primary key default gen_random_uuid(),
  fecha timestamptz not null default now(),
  planta text, usuario text, operacion text, parametros text, resultado text
);
alter table acciones enable row level security;
create policy "acciones leer"  on acciones for select to authenticated using (true);
create policy "acciones crear" on acciones for insert to authenticated with check (true);
```

## Seguridad

- Escritura **apagada por defecto** (`permitir_escritura: false` → 403): habilítala solo cuando quieras operar en remoto.
- Cada comando exige `confirmar: true`, y la web pide **doble confirmación** y manda el usuario (`X-Usuario`).
- **Auditoría**: cada escritura queda en `auditoria_agente.log` (local) y en la tabla `acciones` (visible en el Histórico).
- Token obligatorio (401 sin él); el agente escucha solo en localhost y sale al mundo únicamente por el túnel.
- `agente_config.json` (token y credenciales) **no se sube al repo** (gitignore) — solo el ejemplo.
- Config extra para pruebas: `puerto_ncu` (simulador), `dir_datos` (carpeta plantas alternativa), `timeout_ms`.
