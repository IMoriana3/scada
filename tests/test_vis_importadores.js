// VIS-01 — la falta de dato se convertía en dato. Banco sin navegador.
//
// Los dos importadores (CSV y XLSX) hacían cuatro cosas que se parecen mucho a
// funcionar: rellenaban huecos con ceros, dejaban pasar el texto "NaN" hasta la
// exportación, tiraban filas sin decirlo y elegían entre columnas ambiguas por
// el orden de una lista interna. Ninguna daba error.
//
//   node tests/test_vis_importadores.js
'use strict';
const fs = require('fs'), path = require('path'), vm = require('vm');
const RAIZ = path.join(__dirname, '..');
let ok = 0, ko = 0;
const check = (n, cond, extra) => {
  if (cond) { ok++; console.log('OK   ' + n); }
  else { ko++; console.log('FAIL ' + n + (extra ? ' -> ' + extra : '')); }
};

// ── extraer los importadores del index.html de verdad ──
const html = fs.readFileSync(path.join(RAIZ, 'index.html'), 'utf8');
// La extracción admite las DOS formas —con las ayudas VIS y sin ellas— a
// propósito: si solo aceptara la nueva, el banco no arrancaría contra el código
// anterior y no se podría comprobar que se pone rojo por los motivos correctos.
// Un banco que solo sabe fallar con "no encuentro el bloque" no demuestra nada.
const bCSV = html.match(/const VIS_AUSENTES[\s\S]*?\n\}\n(?=function downloadTpl)/)
          || html.match(/function parseCSV\(text\)\{[\s\S]*?\n\}\n(?=function downloadTpl)/);
// El comentario que sigue al importador no es el mismo en los dos ficheros,
// así que se corta por el cierre de la función y no por lo que venga detrás.
const bXLS = html.match(/function parseProjectXLSX\(wb, fname\)\{[\s\S]*?\n\}\n(?=\/\*)/);
check('el bloque CSV se localiza en index.html', !!bCSV);
check('el bloque XLSX se localiza en index.html', !!bXLS);
if (!bCSV || !bXLS) { console.log('\nFALLOS: ' + ko); process.exit(1); }

const avisos = [];
// XLSX de mentira: devuelve las filas que le demos. Se prueba el PARSEO nuestro,
// no SheetJS, que no es cosa de este repo.
const ctx = { console, alert: m => avisos.push(m),
  XLSX: { utils: { sheet_to_json: ws => ws.__rows } } };
vm.createContext(ctx);
try { vm.runInContext(bCSV[0] + '\n' + bXLS[0], ctx); }
catch (e) { check('los importadores compilan', false, e.message); }
check('los importadores compilan y exponen parseCSV/parseProjectXLSX',
  typeof ctx.parseCSV === 'function' && typeof ctx.parseProjectXLSX === 'function');
const libro = rows => ({ SheetNames: ['H1'], Sheets: { H1: { __rows: rows } } });

// ── 1) NULLS: la ausencia se declara, no se rellena ────────────────────────
// Medido sobre el código anterior:
//   celda VACÍA   -> 0    (`+""` es 0: un ancho de cero metros, un azimut
//                          norte-sur que nadie escribió)
//   celda BASURA  -> NaN  (y viaja hasta la exportación)
//   texto "nan"   -> NaN  (es lo que deja un export de pandas)
{
  const p = ctx.parseCSV(['x,y,id,largo,ancho,azimut',
    '0,0,vacias,,,', '1,1,basura,q,w,e', '2,2,textonan,nan,NaN,#N/A',
    '3,3,buenas,64,12,23.7'].join('\n'));
  check('las cuatro filas entran (ninguna se cae por tener huecos)', p.length === 4, p.length);
  ['vacias', 'basura', 'textonan'].forEach(quien => {
    const r = p.find(z => z.id === quien);
    check(`fila «${quien}»: largo/ancho/azimut son null, ni 0 ni NaN`,
      r.len === null && r.wid === null && r.az === null,
      // String() y no JSON.stringify(): `JSON.stringify(NaN)` es "null", así que
      // el mensaje de fallo diría "null" justo cuando el valor es NaN — y quien
      // lo leyera pensaría que la prueba está mal escrita.
      'len=' + String(r.len) + ' wid=' + String(r.wid) + ' az=' + String(r.az));
  });
  const b = p.find(z => z.id === 'buenas');
  check('y la fila con datos buenos los conserva tal cual',
    b.len === 64 && b.wid === 12 && b.az === 23.7, JSON.stringify(b));
}

// Por qué null y no 0, dicho como consecuencia y no como preferencia: el resto
// del fichero decide con `(m.wid!=null?m.wid:S.p.twid)`. Con 0 se dibujaba y se
// calculaba una mesa de cero metros de ancho; con null cae al valor de proyecto.
{
  const p = ctx.parseCSV(['x,y,ancho', '0,0,', '1,1,12'].join('\n'));
  const anchoEnUso = m => (m.wid != null ? m.wid : 9.9);
  check('un ancho ausente cae al valor de proyecto, no a cero metros',
    anchoEnUso(p[0]) === 9.9 && anchoEnUso(p[1]) === 12,
    anchoEnUso(p[0]) + ' / ' + anchoEnUso(p[1]));
}

// Centinelas UNIDOS. La #29 —otra sesión, mismo síntoma— cubría `nat`,
// `undefined` y los números no finitos; esta rama cubría `na`, `none` y los
// guiones. Cada centinela que falte vuelve a ser una etiqueta de cliente con un
// nombre que nadie escribió, así que se comprueban los de las dos.
[['', 'vacío'], ['nan', 'NaN de texto'], ['NaT', 'NaT de pandas'],
 ['n/a', 'n/a'], ['#N/A', 'error de Excel'], ['null', 'null de texto'],
 ['none', 'None de Python'], ['undefined', 'undefined'], ['-', 'guión'],
 ['--', 'doble guión'], [NaN, 'NaN de verdad'], [Infinity, 'Infinity']
].forEach(([v, nombre]) => {
  // Con guarda: contra el código anterior `visTxt` no existe y esto reventaba a
  // mitad del banco, ocultando el resto. Un retroceso tiene que verse ENTERO.
  const hay = typeof ctx.visTxt === 'function';
  check(`«${nombre}» se lee como ausencia, no como nombre`,
    hay && ctx.visTxt(v) === null,
    hay ? 'devuelve ' + JSON.stringify(ctx.visTxt(v)) : 'no existe visTxt');
});
check('y un nombre de verdad sobrevive intacto',
  typeof ctx.visTxt === 'function' && ctx.visTxt('  A-01 ') === 'A-01',
  typeof ctx.visTxt === 'function' ? JSON.stringify(ctx.visTxt('  A-01 ')) : 'no existe visTxt');

// ── 2) CONTEOS: lo que no entra, se manifiesta ─────────────────────────────
{
  const p = ctx.parseCSV(['x,y,id', '10,20,M1', 'abc,20,M2', '30,,M3', '40,50,M4'].join('\n'));
  check('de 4 filas entran 2', p.length === 2, p.length);
  // Con guarda: en la versión anterior `excluidas` no existe y esto reventaba a
  // mitad del banco, ocultando el resto. Un retroceso tiene que verse ENTERO.
  const ex = p.excluidas || null;
  check('y las otras 2 quedan anotadas con su número de fila',
    !!ex && ex.length === 2 && ex[0].fila === 3 && ex[1].fila === 4,
    ex ? JSON.stringify(ex) : 'parseCSV no manifiesta las exclusiones');
  check('con un motivo, no solo un número',
    !!ex && ex.every(e => typeof e.motivo === 'string' && e.motivo.length > 3),
    ex ? JSON.stringify(ex) : 'sin manifiesto');
  const txt = (ex && typeof ctx.visResumenExclusiones === 'function')
    ? ctx.visResumenExclusiones(ex, p.length) : null;
  check('hay un resumen legible que dice cuántas entran y cuántas no',
    !!txt && txt.indexOf('2') >= 0 && /descartad/i.test(txt),
    txt ? txt.replace(/\n/g, ' | ') : 'no existe visResumenExclusiones');
}

// El tope de 6.000 era otra exclusión muda: recortaba y seguía como si nada.
{
  const L = ['x,y']; for (let i = 0; i < 6100; i++) L.push(i + ',0');
  const p = ctx.parseCSV(L.join('\n'));
  check('el tope de 6.000 recorta pero ya no en silencio',
    p.length === 6000 && p.excluidas && p.excluidas.length === 100,
    p.length + ' filas, ' + (p.excluidas ? p.excluidas.length + ' avisadas' : 'ninguna avisada'));
}

// ── 3) COINCIDENCIA ÚNICA ──────────────────────────────────────────────────
// Antes: `H.findIndex(h => names.includes(h))` cogía la PRIMERA columna de la
// hoja que estuviera en la lista de candidatos. Con "coordenada x" y "x" en la
// misma hoja se elegía una de las dos y cuál dependía del orden. En silencio.
{
  const p = ctx.parseCSV(['coordenada x,x,y,id', '111,10,20,M1'].join('\n'));
  check('con DOS columnas de coordenada X no se elige: se declara ambigua',
    p && p.ambiguas && p.ambiguas.length === 1, JSON.stringify(p && p.ambiguas));
  check('y no se devuelven filas a medio adivinar', p.length === 0, p.length);
  const q = ctx.parseCSV(['x,y,id', '10,20,M1'].join('\n'));
  check('con una sola columna de cada, ninguna ambigüedad',
    !!q && (!q.ambiguas || q.ambiguas.length === 0) && q.length === 1,
    q ? q.length + ' filas' : 'null');
}

// ── 4) EXPORTACIÓN Y REGENERACIÓN ──────────────────────────────────────────
// La cabecera es la EXACTA que escribe csvAssign(). Medido antes: parseCSV
// devolvía null — la herramienta no sabía leer lo que ella misma exporta.
{
  const exportado = ['tcu,tracker_id,ncu,ncu_cliente,power_block,gw,n_en_gw,x_m,y_m',
    'T1,M1,1,A-01,PB-A,GW1,3,10.00,20.00',
    'T2,M2,1,A-02,PB-B,GW1,4,30.00,40.00'].join('\n');
  const p = ctx.parseCSV(exportado);
  check('lo que exporta csvAssign() se puede volver a importar',
    !!p && p.length === 2, p === null ? 'devolvió null' : (p && p.length));
  check('y vuelve con las mismas coordenadas, id y power block',
    p && p[0].x === 10 && p[0].y === 20 && p[0].id === 'M1' && p[0].pb === 'PB-A' &&
    p[1].x === 30 && p[1].y === 40 && p[1].id === 'M2' && p[1].pb === 'PB-B',
    JSON.stringify(p && p[0]));
}

// ── 5) XLSX: el "NaN" que acababa siendo la etiqueta de una NCU ────────────
// `mode()` descartaba "" por ser falsy, pero NO descartaba "NaN". Con una sola
// celda que trajera ese texto, la etiqueta de cliente de la NCU salía "NaN" —
// y así se exportaba. Medido antes: cli de NCUs = ["NaN"].
{
  const rows = [
    ['Coordenada X', 'Coordenada Y', 'NCU', 'GW', 'PS', 'NCU ACCIONA', '', '', '', 'NCU 1 FO'],
    [0, 0, 1, 1, 'PS1', null, null, 0, 0, 'NCU 1 FO'],
    [10, 0, 1, 1, 'PS1', '', null, null, null, null],
    [20, 0, 1, 1, 'PS1', 'NaN', null, null, null, null],
    ['nada', 0, 1, 1, 'PS1', 'A-01', null, null, null, null]];
  const P = ctx.parseProjectXLSX(libro(rows), 'planta.xlsx');
  check('el XLSX se parsea', !!P);
  if (P) {
    check('entran 3 TCUs de 4 filas de datos', P.tcus.length === 3, P.tcus.length);
    check('la cuarta queda anotada, con hoja y fila',
      !!P.excluidas && P.excluidas.length === 1 && P.excluidas[0].hoja === 'H1' &&
      P.excluidas[0].fila === 5,
      P.excluidas ? JSON.stringify(P.excluidas) : 'el XLSX no manifiesta las exclusiones');
    const etiquetas = P.ncus.map(n => n[1]);
    check('NINGUNA etiqueta de NCU es la cadena "NaN"',
      etiquetas.every(e => !/^(nan|null|n\/a)$/i.test(String(e))),
      JSON.stringify(etiquetas));
  }
}

// Y el control, que impide que todo esto sea "descarta más y ya":
// un XLSX limpio no pierde ni una fila ni una etiqueta.
{
  const rows = [
    ['Coordenada X', 'Coordenada Y', 'NCU', 'GW', 'PS', 'NCU ACCIONA', '', '', '', 'NCU 1 FO'],
    [0, 0, 1, 1, 'PS1', 'A-01', null, 0, 0, 'NCU 1 FO'],
    [10, 0, 1, 1, 'PS1', 'A-01', null, null, null, null],
    [20, 0, 1, 1, 'PS1', 'A-01', null, null, null, null]];
  const P = ctx.parseProjectXLSX(libro(rows), 'planta.xlsx');
  check('un XLSX limpio entra entero y sin exclusiones',
    !!P && P.tcus.length === 3 && !!P.excluidas && P.excluidas.length === 0,
    P ? (P.tcus.length + ' TCUs, ' + (P.excluidas ? P.excluidas.length + ' excluidas'
                                                  : 'sin manifiesto')) : 'null');
  check('y la etiqueta de cliente de la NCU es la de verdad',
    !!P && P.ncus[0][1] === 'A-01', P ? JSON.stringify(P.ncus[0]) : 'null');
}

// ── 6) ZOMBI: ¿cazarían estas pruebas la vuelta atrás? ─────────────────────
// Se reimplementa aquí la coerción ANTERIOR y se comprueba que producía justo
// lo que las pruebas de arriba prohíben. Sin esto, "es null" no se distingue de
// una función que devuelve null siempre.
{
  const viejoNum = v => +v;                    // lo que había
  const viejoTxt = v => (v != null ? String(v).trim() : '');
  check('ZOMBI: con la coerción vieja, una celda vacía daba 0 y no null',
    viejoNum('') === 0, 'da ' + viejoNum(''));
  check('ZOMBI: con la coerción vieja, basura y "nan" daban NaN',
    Number.isNaN(viejoNum('q')) && Number.isNaN(viejoNum('nan')));
  check('ZOMBI: con la coerción vieja, el texto "NaN" sobrevivía como etiqueta',
    viejoTxt('NaN') === 'NaN', 'da ' + JSON.stringify(viejoTxt('NaN')));
  // y el `mode` viejo lo elegía por encima de las vacías
  const modeViejo = arr => { const c = {}; arr.forEach(v => { if (v) c[v] = (c[v] || 0) + 1; });
    let b = '', n = 0; for (const k in c) if (c[k] > n) { n = c[k]; b = k; } return b; };
  check('ZOMBI: y `mode` lo prefería a "" — de ahí la NCU llamada "NaN"',
    modeViejo(['', 'NaN', '']) === 'NaN', modeViejo(['', 'NaN', '']));
}

console.log('\n' + (ko ? 'FALLOS: ' + ko + ' (de ' + (ok + ko) + ')'
  : 'OK — ' + ok + '/' + ok + ' comprobaciones'));
process.exit(ko ? 1 : 0);
