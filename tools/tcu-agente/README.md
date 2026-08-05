# TCU Agente — la Toolbox en remoto (piloto Ayora)

> Servicio pequeño que corre en el **PC de planta** y expone por HTTP las operaciones de la toolbox para la página **Toolbox web** de la plataforma: lecturas vía NCU (diagnóstico, comisionado, HSUs), **vigilante de alarmas** que avisa a la plataforma, **sincronización bajo demanda** y — solo si se habilita expresamente — **comandos de escritura** con doble confirmación y auditoría.

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

Lectura (GET, siempre disponibles):

| Ruta | Qué devuelve |
|---|---|
| `/ping` | planta, versiones, hora del PC, lista de NCUs con sus rangos y si la escritura está habilitada |
| `/diagnostico` | diagnóstico de la planta completa vía NCU, **mismo formato que el JSON de la toolbox** — subible al Histórico tal cual |
| `/comisionado` | estado de comisionado (bits 4:3 del bloque compacto) por TCU |
| `/hsus` | HSUs de cada NCU con salud y viento/nieve |
| `/sincronizar` | lee toda la planta y **sube él mismo el diagnóstico al Histórico** (requiere credenciales Supabase en la config) |

Escritura (POST, solo con `"permitir_escritura": true`; el cuerpo debe llevar `"confirmar": true`, `ncu` y `tcus`):

| Ruta | Qué hace |
|---|---|
| `/modo` | aplicar OFF/MANUAL/AUTO (verificado por efecto en 30001) |
| `/limpiar-alarmas` | desenclavar alarmas (40007 bit 13) |
| `/stow` · `/unstow` | activar/quitar safe position (42000, verificado) |
| `/comisionado` | fijar estado de comisionado (40000 bits 7:5, verificado) |
| `/reloj` | sincronizar el reloj de las TCUs con el PC de planta |
| `/nvm` | guardar en NVM (40007 bit 15) |
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
