/* Trae al SCADA las plantas del siting, tal cual, sin reinterpretar nada.
 *
 * POR QUÉ EXISTE ESTO
 * El SCADA dibuja la planta con el MISMO motor que la herramienta de siting —lo dice su propio
 * README: «visualiza el estado de cada TCU sobre el mismo plano que usa la herramienta de siting»—
 * pero cada uno tenía los datos escritos aparte. Se separaron, y se separaron en silencio:
 *
 *   · Ayora y San José: en el siting cada seguidor trae su largo y su ancho reales; en el SCADA la
 *     fila se cortaba en el identificador, así que las 3.043 mesas salían con la cota nominal.
 *   · Páramo y El Burgo: `usePS:false` en el SCADA, `true` en el siting → sin zonas de color ni
 *     leyenda de bloque, fuera del formato de las demás.
 *   · Fayón, Bagnarelli y Túnez: sencillamente no existían en el SCADA.
 *   · El Burgo llegó a tener 219 seguidores en el SCADA y 215 en el siting: cuatro fantasma.
 *
 * QUÉ HACE
 * Copia LITERALMENTE los objetos de planta de Siting/index.html a SCADA/index.html. Copia, no
 * regeneración: el siting es la versión verificada y trae cosas que el layout del DWG no da (las
 * cotas de mesa de Ayora y San José, y las de Fayón, que están MEDIDAS sobre el plano P06 y no
 * derivadas). Regenerar aquí las perdería.
 *
 * De dónde sale cada cosa, para que no se pierda el rastro:
 *   layout del DWG  ──gen_siting.mjs──>  Siting/index.html  ──sync_plantas.mjs──>  SCADA/index.html
 * Cuando cambie un layout, `gen_siting.mjs <planta> --write --destino=ambos` escribe en los dos a
 * la vez y esto no hace falta; esto es para poner el SCADA al día de lo que el siting ya tiene.
 *
 *   node tools/sync_plantas.mjs            informe: qué falta y qué difiere
 *   node tools/sync_plantas.mjs --write    lo escribe
 */
import { readFileSync, writeFileSync } from 'node:fs';

const SITING = '/home/user/Siting/index.html';
const SCADA = new URL('../index.html', import.meta.url).pathname;
const WRITE = process.argv.includes('--write');

/* Las plantas reales, en el orden en que están en el siting. FUV1/FUV2 se quedan fuera a
   propósito: son nubes de puntos de estudio (`pts`), no plantas con NCU y TCU, y el SCADA no las
   pinta. */
const PLANTAS = ['AYORA', 'PARAMO', 'SANJOSE', 'BAGNARELLI', 'TUNEZ', 'BURGO', 'FAYON'];

function literales(txt) {
  const out = new Map();
  for (const m of txt.matchAll(/^const ([A-Z_]+)=(\{.*\});?$/gm)) {
    let o; try { o = JSON.parse(m[2]); } catch { continue; }
    if (!Array.isArray(o.tcus)) continue;                 // sin seguidores no es una planta
    out.set(m[1], { linea: m[0], obj: o });
  }
  return out;
}

const hSit = readFileSync(SITING, 'utf8'), hSca = readFileSync(SCADA, 'utf8');
const S = literales(hSit), C = literales(hSca);

console.log(`siting: ${[...S.keys()].join(' ')}`);
console.log(`scada:  ${[...C.keys()].join(' ')}\n`);

const falta = PLANTAS.filter(p => !S.has(p));
if (falta.length) { console.error('no están en el siting: ' + falta.join(' ')); process.exit(1); }

let cambia = 0;
for (const p of PLANTAS) {
  const s = S.get(p), c = C.get(p);
  if (!c) { console.log(`  + ${p}: no está en el SCADA (${s.obj.tcus.length} TCU)`); cambia++; continue; }
  if (s.linea === c.linea) { console.log(`  = ${p}: idéntico (${s.obj.tcus.length} TCU)`); continue; }
  cambia++;
  const dif = [];
  if (s.obj.tcus.length !== c.obj.tcus.length) dif.push(`${c.obj.tcus.length}→${s.obj.tcus.length} TCU`);
  const conCotas = o => o.tcus.filter(t => t[6] != null).length;
  if (conCotas(s.obj) !== conCotas(c.obj)) dif.push(`cotas de mesa en ${conCotas(c.obj)}→${conCotas(s.obj)} seguidores`);
  const conAz = o => o.tcus.filter(t => t[8] != null).length;
  if (conAz(s.obj) !== conAz(c.obj)) dif.push(`azimut en ${conAz(c.obj)}→${conAz(s.obj)}`);
  for (const k of ['ox', 'oy', 'usePS', 'showGZ', 'name', 'alt', 'tables']) {
    const a = JSON.stringify(c.obj[k]), b = JSON.stringify(s.obj[k]);
    if (a !== b) dif.push(`${k} ${a === undefined ? '(no está)' : a}→${b === undefined ? '(fuera)' : b}`);
  }
  if (JSON.stringify(c.obj.bifilo) !== JSON.stringify(s.obj.bifilo)) dif.push('bífilo ' + JSON.stringify(s.obj.bifilo));
  console.log(`  ~ ${p}: ${dif.join(' · ') || 'difiere en los datos'}`);
}

if (!cambia) { console.log('\nya estaban sincronizadas'); process.exit(0); }
if (!WRITE) { console.log(`\n(dry-run: ${cambia} plantas por sincronizar; pasa --write)`); process.exit(0); }

/* Se escribe en bloque, en el orden de PLANTAS, donde ya estaban: entre `const centroid=` y la
   primera función. Así el diff sale como lo que es —un bloque de datos— y no repartido. */
let h = hSca;
for (const p of PLANTAS) if (C.has(p)) h = h.replace(C.get(p).linea + '\n', '');
const bloque = [
  '/* PLANTAS. Copia literal de Siting/index.html (tools/sync_plantas.mjs). El origen de verdad es',
  '   el layout del DWG en cobertura-zigbee; el siting es quien lo tiene verificado y con las cotas',
  '   de mesa medidas. No editar aquí: se edita allí y se vuelve a sincronizar, o se regenera en los',
  '   dos a la vez con `gen_siting.mjs <planta> --write --destino=ambos`. */',
  ...PLANTAS.map(p => S.get(p).linea),
].join('\n') + '\n';
const ancla = 'function convexHull(points){';
if (!h.includes(ancla)) { console.error('no encuentro dónde poner el bloque'); process.exit(1); }
h = h.replace(ancla, bloque + ancla);
writeFileSync(SCADA, h);
console.log(`\nescritas ${PLANTAS.length} plantas en index.html`);
