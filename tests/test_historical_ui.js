"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const ui = require("../historical-ui.js");
const html = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");

assert.equal(ui.shiftCalendar("2026-03-28T12:45", 1), "2026-03-29T12:45");
assert.equal(ui.shiftCalendar("2026-10-25T12:45", -1), "2026-10-24T12:45");
assert.equal(ui.candidates("2026-03-29T02:30", "Europe/Madrid").length, 0);
assert.equal(ui.candidates("2026-10-25T02:30", "Europe/Madrid").length, 2);
assert.equal(ui.candidates("2026-09-24T12:45", "Europe/Madrid").length, 1);
for (const key of Object.keys(ui.VARIABLES)) {
  assert.equal(ui.variableStyle(key, true).color, ui.seriesStyle(key, false).color);
  assert.equal(ui.seriesStyle(key, false).color, ui.seriesStyle(key, true).color);
  assert.equal(ui.variableStyle(key, false).color, "#8093a4");
  assert.equal(ui.seriesStyle(key, false).dash, "");
  assert.notEqual(ui.seriesStyle(key, true).dash, "");
}
assert.equal(ui.layoutKey({id: "7", tn: 7, ncu: "NCU-01"}, "burgo"), "23003|NCU-01|tcu|7");
assert.equal(ui.layoutKey({id: "ABC", tn: 7, ncu: "NCU-01"}, "burgo"), null);
assert.equal(ui.layoutKey({id: "7", tn: 8, ncu: "NCU-01"}, "burgo"), null);
assert.equal(ui.layoutKey({id: "7", tn: 7, ncu: "NCU-01"}, "ayora"), null);
assert.match(html, /<script src="historical-ui\.js"><\/script>/);
assert.match(html, /id="hist-compare"/);
assert.match(html, /id="coverage-layer"/);
assert.doesNotMatch(html, /function scadaOf\(m\)\{[^}]*scadaIdx/);
console.log("Historical UI: OK (calendario, DST, color, identidad y montaje)");
