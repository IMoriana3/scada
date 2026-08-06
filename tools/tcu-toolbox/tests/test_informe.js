// Filtros y orden del informe HTML, en un navegador de verdad.
// Antes:  pwsh -NoProfile -File gen_informe.ps1
// Luego:  node test_informe.js
const { chromium } = require('playwright');
(async () => {
  const exe = process.env.CHROMIUM_PATH;   // opcional: ruta a un Chromium ya instalado
  const b = await chromium.launch(exe ? { executablePath: exe } : {});
  const p = await b.newPage();
  let fallos = 0;
  const chk = (n, real, esp) => { const ok = String(real) === String(esp);
    console.log(`${ok ? 'OK  ' : 'FAIL'} ${n} = ${real}${ok ? '' : ` (esperado ${esp})`}`); if (!ok) fallos++; };
  const errores = [];
  p.on('pageerror', e => errores.push(e.message));
  await p.goto('file://' + require('path').join(__dirname, 'informe_muestra.html'));
  await p.waitForTimeout(300);
  chk('sin errores de JS', errores.length, 0);

  // cada tabla lleva su id (t-diag, t-lectura, t-bat): los filtros se prueban
  // sobre la de diagnostico, asi que todo va colgado de ella
  const tDiag = p.locator('#t-diag');
  const visibles = async () => tDiag.locator('tbody tr:visible').count();
  chk('filas iniciales', await visibles(), 40);

  // columna Salud = indice 2
  const botSalud = tDiag.locator('tr.filtros td').nth(2).locator('button.fmb');
  chk('boton multi presente', await botSalud.count(), 1);
  chk('rotulo inicial', (await botSalud.textContent()).trim(), '(todas)');

  await botSalud.click();
  const panel = tDiag.locator('tr.filtros td').nth(2).locator('div.fmp');
  chk('panel abierto', await panel.isVisible(), true);

  // marcar ALARMA y OFFLINE a la vez
  await panel.locator('label', { hasText: 'ALARMA' }).locator('input').check();
  await p.waitForTimeout(120);
  const soloAlarma = await visibles();
  await panel.locator('label', { hasText: 'OFFLINE' }).locator('input').check();
  await p.waitForTimeout(120);
  const dos = await visibles();
  chk('dos opciones suman', dos > soloAlarma, true);
  chk('rotulo con 2', (await botSalud.textContent()).trim(), '2 opciones');
  const saludes = await tDiag.locator('tbody tr:visible td:nth-child(3)').allTextContents();
  chk('solo ALARMA/OFFLINE', saludes.every(s => s === 'ALARMA' || s === 'OFFLINE'), true);

  // combinar con otro filtro multi: Modo
  await tDiag.locator('tr.filtros td').nth(3).locator('button.fmb').click();
  chk('el panel anterior se cierra', await panel.isVisible(), false);
  const panModo = tDiag.locator('tr.filtros td').nth(3).locator('div.fmp');
  await panModo.locator('label', { hasText: 'AUTO' }).locator('input').check();
  await p.waitForTimeout(120);
  const cruzado = await visibles();
  chk('cruce de dos columnas reduce', cruzado < dos && cruzado > 0, true);
  const modos = await tDiag.locator('tbody tr:visible td:nth-child(4)').allTextContents();
  chk('modo solo AUTO', modos.every(m => m === 'AUTO'), true);

  // "ninguna" vuelve a dejarlo todo
  await tDiag.locator('tr.filtros td').nth(2).locator('button.fmb').click();
  await panel.locator('a', { hasText: 'ninguna' }).click();
  await p.waitForTimeout(120);
  chk('ninguna = sin filtrar esa columna', (await visibles()) > cruzado, true);
  chk('rotulo vuelve a (todas)', (await botSalud.textContent()).trim(), '(todas)');

  // "todas" marca todo (equivale a no filtrar, pero con rotulo)
  await panel.locator('a', { hasText: 'todas' }).click();
  await p.waitForTimeout(120);
  chk('todas marcadas = 4 opciones', (await botSalud.textContent()).trim(), '4 opciones');

  // la caja de texto sigue funcionando (columna Tilt, indice 4)
  const cajaTilt = tDiag.locator('tr.filtros td').nth(4).locator('input');
  chk('caja de texto donde hay muchos valores', await cajaTilt.count(), 1);

  // ordenar sigue funcionando
  await tDiag.locator('thead tr:first-child th').nth(1).click();
  await p.waitForTimeout(120);
  chk('sigue ordenando', (await tDiag.locator('thead tr:first-child th').nth(1).textContent()).includes('▲'), true);

  // portada: los recuadros de estado de planta
  chk('portada presente', await p.locator('.portada .tile').count() > 0, 'true');
  const port = await p.locator('.portada').textContent();
  chk('portada habla de operativos', port.includes('operativos'), 'true');
  chk('portada colorea por gravedad', await p.locator('.portada .tile.mal').count() > 0, 'true');

  // el aviso de "sin JavaScript no hay filtros" tiene que haberse borrado solo
  chk('aviso de JS bloqueado retirado', await p.locator('#avisojs').count(), 0);
  // ...pero tiene que estar en el HTML, que es lo que ve quien no ejecuta JS
  const crudo = require('fs').readFileSync(require('path').join(__dirname, 'informe_muestra.html'), 'utf8');
  chk('el aviso esta en el fichero', crudo.includes('id="avisojs"'), true);
  chk('el aviso dice que hacer', crudo.includes('Permitir contenido bloqueado'), true);

  // valores imposibles de la lectura masiva (el east_pitch en radianes)
  const imp = p.locator('div.res', { hasText: 'Valores imposibles' });
  chk('bloque de valores imposibles', await imp.count(), 1);
  const txtImp = await imp.textContent();
  chk('cuenta las tres celdas malas', txtImp.includes('Valores imposibles (3)'), true);
  chk('nombra la TCU 4', txtImp.includes('NCU9 TCU 4'), true);
  chk('nombra la TCU 9', txtImp.includes('NCU9 TCU 9'), true);
  chk('explica que son radianes', txtImp.includes('-45'), true);
  chk('las TCUs buenas no salen', txtImp.includes('TCU 7'), false);
  chk('la tabla de lectura sigue estando', await p.locator('table.filtrable').count(), 3);

  // auditoria de baterias: la seccion, y que separe alarma de aviso
  chk('seccion de baterias', await p.locator('#s-bat').count(), 1);
  const tBat = p.locator('#t-bat');
  const txtBat = await tBat.textContent();
  chk('detecta la bateria desconectada', txtBat.includes('SIN BATERIA'), true);
  chk('detecta la sobretension', txtBat.includes('SOBRETENSION'), true);
  chk('detecta la temperatura', txtBat.includes('TEMPERATURA'), true);
  chk('la TCU sana no sale', txtBat.includes('TCU 7'), false);
  chk('colorea la alarma', await tBat.locator('tbody tr.alarma').count() > 0, 'true');
  chk('y el aviso aparte', await tBat.locator('tbody tr.aviso').count() > 0, 'true');
  // y sus filtros funcionan igual que los del diagnostico (columna Tipo = 2)
  await tBat.locator('tr.filtros td').nth(2).locator('button.fmb').click();
  await tBat.locator('tr.filtros td').nth(2).locator('div.fmp label', { hasText: 'SIN BATERIA' }).locator('input').check();
  await p.waitForTimeout(120);
  chk('filtra por tipo de fallo', await tBat.locator('tbody tr:visible').count(), 1);

  console.log(fallos === 0 ? '\nTODAS OK' : `\n${fallos} FALLOS`);
  await b.close();
  process.exit(fallos === 0 ? 0 : 1);
})();
