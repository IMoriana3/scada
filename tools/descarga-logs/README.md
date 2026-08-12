# Descarga de logs de NCU

> Baja cada noche los CSV diarios que graban las NCUs y los deja listos para importar al SCADA.

## Por qué

Las NCUs graban en su disco un CSV por equipo y día (la TCU cada ~10 s, las estaciones cada ~5 s, la propia NCU **cada segundo**). Hoy se descargan **a mano** desde el webserver de cada NCU, y eso tiene dos consecuencias que solo se ven el día malo:

- **La prueba de un siniestro depende de que alguien se acordara de bajarla.** No sabemos cuántos días guarda la NCU antes de reciclar; si el temporal fue el día 3 y se descarga el día 20, puede que ya no exista.
- **No escala**: una planta de 750 seguidores son 750 ficheros al día.

Este script lo resuelve sin esperar a nadie: se programa una vez y deja una carpeta por día que se arrastra entera a `importar-logs.html`.

## Uso

```powershell
# 1) Una sola vez por planta: descubrir cómo sirve los logs el webserver
.\Descarga-Logs-NCU.ps1 -Topologia .\plantas\23003-el-burgo.json -Descubrir -Ncu 2

# 2) Descarga normal (ayer y hoy)
.\Descarga-Logs-NCU.ps1 -Topologia .\plantas\23003-el-burgo.json -Dias 2

# 3) El día concreto de un siniestro
.\Descarga-Logs-NCU.ps1 -Topologia .\plantas\23003-el-burgo.json -Fecha 2026-08-12

# 4) Dejarlo programado todas las noches a las 02:00
.\Descarga-Logs-NCU.ps1 -Topologia C:\factiun\23003-el-burgo.json -Programar
```

La **topología** es el mismo JSON (o CSV) que exporta la página de IPs para la TCU Toolbox: de ahí salen la IP de cada NCU y el rango de esclavos, que es lo que dice qué ficheros pedir.

## El descubrimiento de la URL

No sabemos el patrón exacto con el que el webserver de la NCU sirve un fichero, así que `-Descubrir` prueba once candidatos contra una NCU real y se queda con el que devuelve algo que **empieza por `datetime;`** — la cabecera de estos logs. Lo encontrado se guarda en `descarga.config.json` y no se vuelve a probar.

Si ninguno funciona, el script lo dice y pide lo único que hace falta: abrir el webserver en el navegador, clic derecho sobre el enlace de un CSV → *Copiar dirección*, y añadir ese patrón a la lista `$Patrones`. Un minuto, y queda resuelto para todas las plantas.

## Lo que deja

```
logs-ncu\El_Burgo_I\20260812\NCU2_TCU_001_20260812.csv
                              NCU2_HSU_230_20260812.csv
                              ...
                              manifiesto.json
```

El **manifiesto** lleva, por fichero: NCU de origen, IP, tamaño, hora de descarga, URL exacta y **SHA-256**. Ese hash es el mismo que calcula el importador y el que enseña el SCADA en la ficha de cada equipo: si coinciden, el análisis se hizo sobre el fichero que grabó el equipo y nadie lo tocó por el camino. Es lo que sostiene un expediente ante un perito.

## Notas

- Un fichero que ya está descargado **no se vuelve a pedir**: el script se puede lanzar tantas veces como se quiera.
- Que falten TCUs es normal — el rango de la topología incluye posiciones que no existen.
- Reintentos con espera creciente (2 s, 4 s, 8 s) por si la NCU está ocupada.
- No necesita credenciales de Supabase: solo baja y sella. La subida la hace una persona desde `importar-logs.html`, que es donde se decide el paso de submuestreo.
