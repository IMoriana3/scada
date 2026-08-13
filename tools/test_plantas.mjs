/* Banco: comprueba que las 7 plantas reales cargan en el SCADA y cargan IGUAL que en el siting.
 *
 * Mide lo que la página entiende, no lo que el fichero dice: motores, NCU, HSU, repetidores,
 * bloques de potencia, cuántos seguidores traen cotas de mesa y cuántos van girados. Si el SCADA y
 * el siting dejan de coincidir en cualquiera de esas cifras, esto lo dice.
 *
 * Vigila además dos cosas que ya han pasado y no se ven a simple vista:
 *   · el bloque fantasma "PS null" (Ayora entera pintada como UN power block en vez de 16),
 *   · que XLSX esté cargado de verdad (venía de cdnjs y en la LAN de planta no hay internet).
 *
 * Levanta él mismo los dos servidores estáticos y los apaga al terminar.
 *
 *   node tools/test_plantas.mjs
 *
 * Necesita playwright-core. Este repo no lo trae; se resuelve al de cobertura-zigbee, que sí, igual
 * que gen_siting.mjs resuelve allí los layouts. Si mueves los repos, cambia PW.
 */
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';

const SCADA = new URL('..', import.meta.url).pathname.replace(/\/$/, '');
const SITING = '/home/user/Siting';
const PW = '/home/user/Cobertura-Zigbee/node_modules/playwright-core/index.mjs';
const EXE = '/opt/pw-browsers/chromium_headless_shell-1194/chrome-linux/headless_shell';
const PLANTAS = ['ayora', 'paramo', 'sanjose', 'burgo', 'fayon', 'bagnarelli', 'tunez'];

const { chromium } = await import('playwright-core').catch(() => import(PW));

const TIPO = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
               '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png' };
function sirve(raiz, puerto) {
  const s = createServer(async (q, r) => {
    const ruta = join(raiz, normalize(decodeURIComponent(q.url.split('?')[0])).replace(/^(\.\.[/\\])+/, ''));
    try { const b = await readFile(ruta); r.writeHead(200, { 'content-type': TIPO[extname(ruta)] || 'application/octet-stream' }); r.end(b); }
    catch { r.writeHead(404); r.end('no'); }
  });
  return new Promise(ok => s.listen(puerto, '127.0.0.1', () => ok(s)));
}

const sA = await sirve(SCADA, 8531), sB = await sirve(SITING, 8532);
const b = await chromium.launch({ executablePath: EXE, args: ['--use-angle=swiftshader', '--no-sandbox', '--disable-dev-shm-usage'] });

async function mide(url) {
  const p = await b.newPage({ viewport: { width: 1400, height: 900 } });
  const errs = [], fallos = [];
  /* Las fuentes de Google no cuentan: si no cargan, el CSS cae a las del sistema, y en el banco no
     hay salida a internet. Cualquier OTRA petición que falle sí cuenta, que es como se vio que la
     librería de Excel venía de cdnjs y en la LAN de una planta no iba a cargar nunca. */
  const deFuentes = u => /fonts\.(googleapis|gstatic)\.com/.test(u || '');
  p.on('pageerror', e => errs.push(String(e)));
  p.on('console', m => { if (m.type() === 'error' && !deFuentes(m.location() && m.location().url)) errs.push(m.text()); });
  p.on('requestfailed', r => { if (!deFuentes(r.url())) fallos.push(r.url().slice(0, 100)); });
  await p.goto(url, { waitUntil: 'networkidle' });
  const xlsx = await p.evaluate(() => typeof XLSX);
  const out = {};
  for (const sc of PLANTAS) {
    if (!await p.evaluate(s => !!document.querySelector(`#scn button[data-sc="${s}"]`), sc)) { out[sc] = null; continue; }
    await p.click(`#scn button[data-sc="${sc}"]`);
    await p.waitForTimeout(120);
    out[sc] = await p.evaluate(() => ({
      motores: S.motors.length, ncus: S.ncus.length, hsus: S.rsus.length, reps: S.reps.length,
      bloques: new Set(S.motors.map(m => m.pb)).size,
      pbNull: S.motors.filter(m => m.pb === 'PS null').length,
      cotas: S.motors.filter(m => m.len != null).length,
      largos: [...new Set(S.motors.map(m => m.len))].filter(v => v != null).sort((a, c) => c - a),
      girados: S.motors.filter(m => m.az).length,
      ox: S.projOX, oy: S.projOY,
    }));
  }
  await p.close();
  return { out, errs, fallos, xlsx };
}

const A = await mide('http://127.0.0.1:8531/index.html');
const B = await mide('http://127.0.0.1:8532/index.html');
await b.close(); sA.close(); sB.close();

let mal = 0;
const ok = (c, m) => { console.log((c ? '  ok   ' : '  FALLO') + ' ' + m); if (!c) mal++; };

console.log('\n=== las 7 plantas, en el SCADA ===');
console.log('  ' + ['planta', 'motores', 'NCU', 'HSU', 'rep', 'bloques', 'cotas', 'girados'].map((c, i) => c.padEnd(i ? 9 : 12)).join(''));
for (const sc of PLANTAS) {
  const a = A.out[sc];
  if (!a) { console.log('  FALLO ' + sc + ': no está'); mal++; continue; }
  console.log('  ' + [sc, a.motores, a.ncus, a.hsus, a.reps, a.bloques, a.cotas, a.girados].map((v, i) => String(v).padEnd(i ? 9 : 12)).join(''));
}

console.log('\n=== ¿el mismo plano que el siting? ===');
for (const sc of PLANTAS) {
  const a = A.out[sc], c = B.out[sc];
  if (!a || !c) { ok(false, `${sc}: falta en ${!a ? 'el SCADA' : 'el siting'}`); continue; }
  const dif = [];
  for (const k of ['motores', 'ncus', 'hsus', 'reps', 'bloques', 'cotas', 'girados', 'ox', 'oy'])
    if (a[k] !== c[k]) dif.push(`${k} ${a[k]} vs ${c[k]}`);
  if (JSON.stringify(a.largos) !== JSON.stringify(c.largos)) dif.push(`largos ${JSON.stringify(a.largos)} vs ${JSON.stringify(c.largos)}`);
  ok(dif.length === 0, `${sc}: ${a.motores} TCU · ${a.ncus} NCU · ${a.bloques} bloques` + (dif.length ? ' → ' + dif.join(' · ') : ''));
}

console.log('\n=== trampas conocidas ===');
const conNull = PLANTAS.filter(sc => A.out[sc] && A.out[sc].pbNull);
ok(conNull.length === 0, 'ninguna planta cae en el bloque fantasma "PS null"' + (conNull.length ? ': ' + conNull.join(' ') : ''));
ok(A.xlsx === 'object', `XLSX cargado desde el propio repo (typeof = ${A.xlsx}); sin internet la carga de Excel tiene que seguir funcionando`);
ok(A.fallos.length === 0, 'ninguna petición externa falla' + (A.fallos.length ? ': ' + A.fallos.slice(0, 3).join(' ') : ''));
ok(A.errs.length === 0, 'sin errores de consola' + (A.errs.length ? ': ' + A.errs.slice(0, 2).join(' | ').slice(0, 160) : ''));

console.log(mal ? `\n✗ ${mal} FALLOS` : '\n✓ el SCADA carga las 7 plantas y las carga igual que el siting');
process.exit(mal ? 1 : 0);
