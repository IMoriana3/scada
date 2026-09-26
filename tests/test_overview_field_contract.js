const fs = require('fs');
const vm = require('vm');

function ok(cond, msg) {
  if (!cond) {
    console.error('FAIL:', msg);
    process.exitCode = 1;
  }
}

for (const file of ['overview-ui.js', 'field-mode.js', 'sw.js']) {
  const src = fs.readFileSync(file, 'utf8');
  try {
    new vm.Script(src, { filename: file });
  } catch (e) {
    console.error(e);
    process.exitCode = 1;
  }
}

const ov = fs.readFileSync('overview-ui.js', 'utf8');
ok(ov.includes('ScadaHistory.assetForMotor'), 'Overview must resolve scene -> asset through IdentityRegistry binding');
ok(!ov.includes('find(function(m){return m.tcu==='), 'Overview must not infer identity from TCU label');
ok(ov.includes('return d.health!=="ok";'), 'Overview attention list must reuse collector health');
ok(ov.includes('no crea umbrales alternativos'), 'Overview must disclose that health thresholds are canonical');

const fm = fs.readFileSync('field-mode.js', 'utf8');
ok(fm.includes('sync_status:"LOCAL_ONLY"'), 'Field inspections must declare local-only persistence');
ok(fm.includes('ScadaHistory.assetForMotor'), 'Field mode must bind through asset_id');
ok(fm.includes('SIGNO UNKNOWN'), 'Unsigned phone inclinometer must not invent E/W sign');
ok(fm.includes('schema_version:"field-inspection/1"'), 'Field inspection records must be versioned');
ok(fm.includes('IndexedDB') || fm.includes('indexedDB'), 'Field photos must use persistent offline storage');

const idx = fs.readFileSync('index.html', 'utf8');
ok(idx.includes('<script src="overview-ui.js"></script>'), 'SCADA shell must load Overview');
ok(idx.includes('<script src="field-mode.js"></script>'), 'SCADA shell must load Field Mode');
ok(idx.includes('<link rel="manifest" href="manifest.json">'), 'SCADA shell must expose PWA manifest');

console.log(process.exitCode ? 'overview/field contract: FAILED' : 'overview/field contract: OK');
