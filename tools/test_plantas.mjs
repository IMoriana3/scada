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
import { statSync } from 'node:fs';
import { extname, join, normalize } from 'node:path';

const SCADA = new URL('..', import.meta.url).pathname.replace(/\/$/, '');
/* Los repos vecinos se BUSCAN entre varias mayusculas en vez de fijarse a una:
   estaban escritos `/home/user/Siting` y `/home/user/Cobertura-Zigbee`, y en un
   clon en minusculas -- que es como los deja el checkout aqui -- el arnes ni
   arrancaba. Un banco que no corre en la maquina que lo tiene que correr no es
   un banco; y esto es fontaneria, no criterio, asi que se resuelve buscando. */
const existe = p => { try { statSync(p); return true; } catch { return false; } };
const primero = (cands, que) => cands.find(existe) || (() => { throw new Error(`no encuentro ${que}: probado ${cands.join(' ')}`); })();
const SITING = primero(['/home/user/siting', '/home/user/Siting'], 'el repo del siting');
const PW = primero(['/home/user/cobertura-zigbee/node_modules/playwright-core/index.mjs',
                    '/home/user/Cobertura-Zigbee/node_modules/playwright-core/index.mjs'], 'playwright-core');
const EXE = primero(['/opt/pw-browsers/chromium_headless_shell-1194/chrome-linux/headless_shell',
                     '/opt/pw-browsers/chromium/chrome'], 'el navegador');
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

/* ============ El ancla de la ficha sobrevive a un reorden del plano ============
 *
 * El deep-link de la ficha lleva `ncu + gw + tn` y NO `scadaIdx`, porque
 * `scadaIdx` lo numera `buildScadaIndex()` de 1..n sobre los motores de la NCU
 * y es un indice DERIVADO: si el plano cambia, se corre, y un enlace guardado
 * en un correo de postventa aterriza en otro tracker con cara de correcto.
 *
 * MEDIDO ANTES DE ESCRIBIR ESTO: hoy `scadaIdx === tn` en los 215 motores de El
 * Burgo y en los 754 de Ayora -- cero diferencias. O sea que un test sobre el
 * plano TAL Y COMO ESTA no distinguiria las dos anclas y daria verde con
 * cualquiera de las dos: seria un invariante verificado donde no puede
 * romperse. Coinciden porque hoy los `tn` de cada NCU son 1..n contiguos.
 *
 * El regimen de riesgo es el HUECO, y no es hipotetico: es exactamente la
 * conciliacion 219-vs-215 que esta pendiente, con la TCU 109 en "confirmar en
 * campo". El dia que un numero fisico no exista, los `tn` dejan de ser
 * contiguos, `scadaIdx` los compacta y las dos anclas se separan. Asi que la
 * fixture INYECTA ese hueco, que es la unica forma de que el test mida.
 *
 * Su mutante esta abajo y va comprobado: anclar por `scadaIdx` lo pone rojo.
 */
console.log('\n=== el enlace de la ficha sobrevive al reorden del plano ===');
{
  const sC = await sirve(SCADA, 8533);
  const b2 = await chromium.launch({ executablePath: EXE, args: ['--no-sandbox', '--disable-dev-shm-usage'] });
  const p = await b2.newPage({ viewport: { width: 1400, height: 900 } });
  await p.goto('http://127.0.0.1:8533/index.html', { waitUntil: 'networkidle' });
  await p.click('#scn button[data-sc="burgo"]');
  await p.waitForTimeout(150);

  const r = await p.evaluate(() => {
    buildScadaIndex();
    const deNcu = S.motors.filter(m => m.ncu === 'NCU-01' && m.tn != null).sort((a, b) => a.tn - b.tn);
    const bajaTn = deNcu[Math.floor(deNcu.length / 3)].tn;      // el que "no existe" (papel de la TCU 109)
    const obj = deNcu.find(m => m.tn > bajaTn);                  // uno POSTERIOR: es al que se le corre el indice
    const antes = { hash: fiHash(obj), tn: obj.tn, idx: obj.scadaIdx, x: obj.x, y: obj.y, gw: obj.gw };

    // El plano se toca: ese numero fisico resulta no existir.
    S.motors = S.motors.filter(m => !(m.ncu === 'NCU-01' && m.tn === bajaTn));
    buildScadaIndex();

    const res = fiResolve(antes.hash);
    const porIdx = S.motors.find(m => m.ncu === 'NCU-01' && m.scadaIdx === antes.idx);  // lo que habria hecho el ancla mala
    return {
      bajaTn, antes,
      seSeparan: obj.scadaIdx !== antes.idx,
      cae: res && res.m ? { tn: res.m.tn, x: res.m.x, y: res.m.y } : null,
      stale: !!(res && res.stale),
      porIdx: porIdx ? { tn: porIdx.tn, x: porIdx.x, y: porIdx.y } : null,
    };
  });

  const mismo = r.cae && r.cae.x === r.antes.x && r.cae.y === r.antes.y && r.cae.tn === r.antes.tn;
  ok(r.seSeparan, `tras quitar la TCU ${r.bajaTn}, el indice derivado del objetivo se corre (${r.antes.idx} → ${r.antes.idx - 1}): las dos anclas se separan y el test puede medir`);
  ok(mismo, `el mismo enlace (${r.antes.hash}) sigue cayendo en el MISMO tracker fisico (tn ${r.antes.tn}, misma posicion)`);
  ok(r.porIdx && r.porIdx.tn !== r.antes.tn,
     `y el mutante: anclado por indice derivado, ese enlace habria caido en el tracker tn ${r.porIdx ? r.porIdx.tn : '?'} — otro hierro, con cara de correcto`);

  /* El cable-trampa del `gw`. Es redundante para identificar -- `tn` ya es unico
     por NCU -- y viaja para que un enlace de un reparto de gateway anterior se
     DIGA en vez de resolverse callado por el lado que cuadra. */
  const g = await p.evaluate(() => {
    const m = S.motors.find(o => o.ncu === 'NCU-01' && o.tn != null && (o.gw || 1) === 1);
    const malo = `#tcu/NCU-01/2/${m.tn}`;                  // el mismo TCU, con el gateway de antes
    const res = fiResolve(malo);
    return { bueno: fiResolve(fiHash(m)).stale, malo: res.stale, cae: res.m ? res.m.tn : null, esperado: m.tn };
  });
  ok(g.bueno === false, 'un enlace al dia no levanta el aviso');
  ok(g.malo === true, 'un enlace con el gateway de un plano anterior SI lo levanta ("enlace de un plano anterior")');
  ok(g.cae === g.esperado, 'y aun asi resuelve al tracker cuyo numero fisico manda, en vez de no abrir nada');

  /* El estandarte pre-R7. Contrato del #205: un campo que el firmware no expone
     llega como `null`, NO omitido. La fixture separa los tres casos que un
     tecnico NO puede distinguir de otro modo. */
  const e = await p.evaluate(() => {
    const m = S.motors.find(o => o.ncu === 'NCU-01' && o.tn != null);
    const R7 = ['battery_current', 'motor_current', 'soh', 'temp_pcb', 'panel_voltage', 'alarms1', 'alarms2'];
    const base = { ncu: m.ncu, tcu: m.scadaIdx, health: 'ok', alarms: '', tilt_angle: -12, target_angle: -12, soc: 90 };
    const pinta = d => { S.scada.on = true; S.scada.data = { [m.ncu + '|' + m.scadaIdx]: d }; return fiRender({ m, stale: false }); };
    const r7 = pinta({ ...base, ...Object.fromEntries(R7.map(k => [k, 1])) });
    const viejo = pinta({ ...base, ...Object.fromEntries(R7.map(k => [k, null])) });
    const apiVieja = pinta({ ...base });                       // ni siquiera trae las claves
    S.scada.on = false; S.scada.data = {};
    return { r7: /anterior a R7/.test(r7), viejo: /anterior a R7/.test(viejo),
             apiVieja: /no sirve el bloque ampliado/.test(apiVieja), viejoApi: /no sirve el bloque ampliado/.test(viejo) };
  });
  ok(e.r7 === false, 'con firmware R7 no se levanta el estandarte');
  ok(e.viejo === true, 'con el bloque entero en null SI: "firmware anterior a R7", el equipo no lo expone');
  ok(e.apiVieja === true, 'y si las claves ni vienen, el que se ha quedado atras es el otro lado: "la API no sirve el bloque ampliado"');
  ok(e.viejoApi === false, 'los dos avisos no se confunden entre si');

  await b2.close(); sC.close();
}

console.log(mal ? `\n✗ ${mal} FALLOS` : '\n✓ el SCADA carga las 7 plantas, las carga igual que el siting, y el enlace de la ficha aguanta el reorden');
process.exit(mal ? 1 : 0);
