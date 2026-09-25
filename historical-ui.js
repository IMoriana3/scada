/* Historical analysis in the existing SCADA canvas/card. No identity inference. */
(function (root) {
  "use strict";
  const VARIABLES = Object.freeze({
    tilt_angle: ["Ángulo", "#2463ba", "°"], target_angle: ["Objetivo", "#bd6030", "°"],
    soc: ["SoC", "#7a48b3", "%"], soh: ["SoH", "#138572", "%"],
    battery_voltage: ["Batería", "#a36a0e", "mV"],
    battery_current: ["I batería", "#ad3c69", "mA"],
    temp_battery: ["T batería", "#337c9a", "°C"],
    temp_pcb: ["T placa", "#5b7d2c", "°C"],
    motor_current: ["I motor", "#ba3939", "mA"],
    panel_voltage: ["V panel", "#6975af", "mV"],
    comms_age_s: ["Edad comms", "#856143", "s"]
  });
  function variableStyle(variable, active) {
    return {color: active ? VARIABLES[variable][1] : "#8093a4", active};
  }
  function seriesStyle(variable, compared) {
    return {color: VARIABLES[variable][1], dash: compared ? "7 5" : ""};
  }
  function wall(instant, zone) {
    const parts = Object.fromEntries(new Intl.DateTimeFormat("en-GB", {
      timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", hourCycle: "h23"
    }).formatToParts(instant).map(p => [p.type, p.value]));
    return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}`;
  }
  function candidates(local, zone) {
    if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(local)) return [];
    const [y, mo, d, h, mi] = local.split(/[-T:]/).map(Number);
    const naive = Date.UTC(y, mo - 1, d, h, mi);
    if (new Date(naive).toISOString().slice(0, 16) !== local) return [];
    const result = [];
    for (let offset = -14 * 60; offset <= 14 * 60; offset += 15) {
      const instant = new Date(naive - offset * 60000);
      if (wall(instant, zone) === local) result.push(instant);
    }
    return result.sort((a, b) => a - b);
  }
  function shiftCalendar(local, days) {
    const [date, clock] = local.split("T");
    const [year, month, day] = date.split("-").map(Number);
    return new Date(Date.UTC(year, month - 1, day + days)).toISOString().slice(0, 10) + "T" + clock;
  }
  function layoutKey(m, scenario) {
    // The scene's source-local locator is only useful if a matching explicit
    // operational_asset_key binding is returned by 06_PLANT. Never use tn's
    // fallback (the browser assigns it by count for some layouts).
    if (scenario !== "burgo" || !m || !/^\d+$/.test(String(m.id)) ||
        Number(m.id) !== m.tn || !/^NCU-\d+$/.test(m.ncu)) return null;
    return `23003|${m.ncu}|tcu|${m.id}`;
  }
  const state = {layer: "instant", identity: null, byLayout: new Map(),
    byAsset: new Map(), coverage: new Map(), chart: null,
    primary: null, selected: new Set(["tilt_angle", "target_angle", "soc"]),
    range: null, comparison: ""};
  const api = {VARIABLES, variableStyle, seriesStyle, wall, candidates, shiftCalendar, layoutKey,
    get layer() { return state.layer; },
    assetForMotor(m) {
      const key = layoutKey(m, S.sc);
      return key ? state.byLayout.get(key) || null : null;
    },
    coverageMetric(m) { const id = api.assetForMotor(m); return id ? state.coverage.get(id) : null; },
    coverageColor(m) {
      if (S.sel && m.ncu !== S.sel) return "#9aa6b2";
      const metric = api.coverageMetric(m);
      if (!metric || metric.telemetry_availability_pct == null) return "#9aa6b2";
      // Continuous monochrome intensity: no unapproved good/degraded/poor cutoffs.
      return `hsl(205 68% ${Math.round(88 - metric.telemetry_availability_pct * .52)}%)`;
    },
    async connect(url) {
      const r = await fetch(url.replace(/\/$/, "") + "/identity", {cache: "no-store"});
      if (!r.ok) throw new Error("HTTP " + r.status + " · Package no publicado o no disponible");
      const identity = await r.json();
      if (identity.plant_id !== "23003" || S.sc !== "burgo" || !identity.read_only)
        throw new Error("Esta planta no tiene binding de escena aprobado para esta vista");
      const byLayout = new Map(), byAsset = new Map();
      for (const row of identity.assets) {
        if (byLayout.has(row.layout_key) || byAsset.has(row.asset_id))
          throw new Error("Binding de identidad ambiguo");
        byLayout.set(row.layout_key, row.asset_id); byAsset.set(row.asset_id, row);
      }
      state.identity = identity; state.byLayout = byLayout; state.byAsset = byAsset;
      state.coverage.clear(); state.layer = "instant";
      const date = wall(new Date(), identity.timezone).slice(0, 10);
      document.getElementById("coverage-day").value = shiftCalendar(date + "T00:00", -1).slice(0, 10);
      document.getElementById("coverage-layer").value = "instant";
      document.getElementById("coverage-control").title = identity.operationally_usable
        ? "Identidad publicada · sólo lectura" : "Identidad provisional: desarrollo sólo lectura, no operativa";
    },
    async fetchCoverage() {
      if (!state.identity || !S.scada.on) throw new Error("Conecta SCADA e IdentityRegistry");
      const date = document.getElementById("coverage-day").value;
      if (!date) throw new Error("Selecciona un día de la planta");
      const params = new URLSearchParams({day: date});
      if (S.sel) {
        const scopes = new Set([...state.byAsset.values()]
          .filter(row => row.layout_key.split("|")[1] === S.sel).map(row => row.ncu_asset_id));
        if (scopes.size !== 1) throw new Error("NCU sin binding de ámbito único");
        params.set("ncu_asset_id", [...scopes][0]);
      }
      const url = S.scada.url.replace(/\/$/, "") + "/coverage/measured?" + params;
      const r = await fetch(url, {cache: "no-store"});
      if (!r.ok) throw new Error("Cobertura medida: HTTP " + r.status);
      const data = await r.json();
      if (data.timezone !== state.identity.timezone || data.rf_modelled !== false)
        throw new Error("Contrato de cobertura no compatible");
      state.coverage = new Map(data.assets.map(a => [a.asset_id, a]));
      renderLegend();
      draw();
    },
    openForMotor(m) {
      const id = api.assetForMotor(m);
      if (!id) { alert("TCU sin binding explícito en el Plant Package"); return; }
      state.primary = id;
      const sel = document.getElementById("hist-compare");
      sel.innerHTML = '<option value="">Sin comparación</option>';
      for (const row of state.byAsset.values()) {
        if (row.asset_id === id) continue;
        const option = document.createElement("option"); option.value = row.asset_id;
        option.textContent = `${row.ncu} · TCU ${row.tcu}`; sel.append(option);
      }
      sel.value = state.comparison && state.comparison !== id ? state.comparison : "";
      if (!state.range) presetHours(24); else {
        setWall("from", state.range.from); setWall("to", state.range.to);
      }
      renderVariableButtons();
      document.getElementById("hist-modal").classList.add("open");
      loadChart();
    }
  };
  root.ScadaHistory = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  if (typeof document === "undefined") return;

  const el = id => document.getElementById("hist-" + id);
  function setWall(which, date) {
    const local = wall(date, state.identity.timezone);
    el(which).value = local;
    const select = el(which + "-offset"), matches = candidates(local, state.identity.timezone);
    select.innerHTML = "";
    for (const instant of matches) {
      const option = document.createElement("option"); option.value = instant.toISOString();
      option.textContent = instant.toISOString().slice(11, 16) + " UTC";
      select.append(option);
    }
    select.hidden = matches.length < 2;
    select.value = date.toISOString();
  }
  function readWall(which) {
    const local = el(which).value, matches = candidates(local, state.identity.timezone);
    if (!matches.length) throw new Error(`${which}: hora local inexistente o inválida`);
    const select = el(which + "-offset");
    if (matches.length === 2) {
      if (select.options.length !== 2 || !matches.some(d => d.toISOString() === select.value)) {
        select.innerHTML = "";
        for (const instant of matches) {
          const option = document.createElement("option"); option.value = instant.toISOString();
          option.textContent = instant.toISOString().slice(11, 16) + " UTC";
          select.append(option);
        }
        select.hidden = false;
        throw new Error(`${which}: hora repetida por cambio horario; elige el offset UTC y consulta`);
      }
      return new Date(select.value);
    }
    select.hidden = true;
    return matches[0];
  }
  function presetHours(hours) {
    const to = new Date(), from = new Date(to.getTime() - hours * 3600000);
    state.range = {from, to}; setWall("from", from); setWall("to", to);
  }
  function renderVariableButtons() {
    const box = el("variables"); box.innerHTML = "";
    for (const [key, [name, color]] of Object.entries(VARIABLES)) {
      const button = document.createElement("button"); button.type = "button";
      button.textContent = name; button.dataset.variable = key;
      const style = variableStyle(key, state.selected.has(key));
      button.classList.toggle("active", style.active); button.style.color = style.color;
      button.onclick = () => {
        if (state.selected.has(key)) state.selected.delete(key); else state.selected.add(key);
        renderVariableButtons(); loadChart();
      };
      box.append(button);
    }
  }
  async function loadChart() {
    if (!state.primary) return;
    const status = el("status");
    try {
      const from = readWall("from"), to = readWall("to");
      if (from >= to) throw new Error("Desde debe ser anterior a hasta");
      state.range = {from, to}; state.comparison = el("compare").value;
      if (!state.selected.size) { status.textContent = "Selecciona al menos una variable"; drawChart(null); return; }
      status.textContent = "Consultando histórico…";
      const params = new URLSearchParams({asset_id: state.primary, from: from.toISOString(),
                                         to: to.toISOString(), fields: [...state.selected].join(",")});
      if (state.comparison) params.set("compare_asset_id", state.comparison);
      const response = await fetch(S.scada.url.replace(/\/$/, "") + "/assets/history?" + params,
                                   {cache: "no-store"});
      if (!response.ok) throw new Error("Histórico: HTTP " + response.status);
      const result = await response.json(); state.chart = result;
      status.textContent = `${result.timezone} · ${result.from} → ${result.to} · datos cada ${result.window_s}s · sólo lectura`;
      drawChart(result);
    } catch (e) { status.textContent = e.message; }
  }
  function drawChart(data) {
    const svg = el("chart"), legend = el("legend");
    svg.innerHTML = ""; legend.innerHTML = "";
    if (!data) return;
    const selected = [...state.selected], width = 900, rowH = 105;
    svg.setAttribute("viewBox", `0 0 ${width} ${selected.length * rowH + 32}`);
    const from = Date.parse(data.from), to = Date.parse(data.to);
    const x = t => 105 + 770 * (Date.parse(t) - from) / (to - from);
    const ns = "http://www.w3.org/2000/svg";
    const node = (tag, attrs, parent) => {
      const n = document.createElementNS(ns, tag);
      for (const [key, value] of Object.entries(attrs)) n.setAttribute(key, String(value));
      (parent || svg).append(n); return n;
    };
    for (const [index, variable] of selected.entries()) {
      const [name, color, unit] = VARIABLES[variable], top = index * rowH + 12;
      const all = data.assets.flatMap(a => a.series[variable] || []).map(p => Number(p.v)).filter(Number.isFinite);
      let min = Math.min(...all), max = Math.max(...all);
      if (!all.length) { min = 0; max = 1; }
      if (min === max) { min -= 1; max += 1; }
      const label = node("text", {x: 8, y: top + 15}); label.textContent = `${name} (${unit})`;
      node("line", {x1: 105, y1: top + 80, x2: 875, y2: top + 80, stroke: "#bdcad2"});
      const maxLabel = node("text", {x: 56, y: top + 17}); maxLabel.textContent = max.toFixed(1);
      const minLabel = node("text", {x: 56, y: top + 81}); minLabel.textContent = min.toFixed(1);
      data.assets.forEach((asset, i) => {
        const points = (asset.series[variable] || []).filter(p => Number.isFinite(Number(p.v)))
          .sort((a, b) => Date.parse(a.t) - Date.parse(b.t));
        let path = "", prev = null;
        for (const point of points) {
          const px = x(point.t), py = top + 80 - (Number(point.v) - min) / (max - min) * 64;
          path += (!prev || Date.parse(point.t) - Date.parse(prev.t) > data.window_s * 2500 ? "M" : "L") + `${px.toFixed(1)} ${py.toFixed(1)} `;
          prev = point;
        }
        const stroke = seriesStyle(variable, !!i);
        if (path) node("path", {d: path, fill: "none", stroke: stroke.color, "stroke-width": 2,
          "stroke-dasharray": stroke.dash, "aria-label": `${name} ${asset.ncu} TCU ${asset.tcu}`});
        const item = document.createElement("span"); item.style.color = color;
        item.textContent = `${name} · ${asset.ncu} TCU ${asset.tcu} ${i ? "┄ comparada" : "━━ principal"}`;
        legend.append(item);
      });
      if (!all.length) {
        const no = node("text", {x: 415, y: top + 48}); no.textContent = "Sin datos";
      }
    }
    const left = node("text", {x: 105, y: selected.length * rowH + 21});
    left.textContent = wall(new Date(from), data.timezone).replace("T", " ");
    const right = node("text", {x: 770, y: selected.length * rowH + 21});
    right.textContent = wall(new Date(to), data.timezone).replace("T", " ");
  }

  document.getElementById("fi-history").onclick = () => {
    if (!S.scada.on || !S.ficha) { alert("Conecta SCADA para consultar el histórico"); return; }
    api.openForMotor(S.ficha.m);
  };
  el("close").onclick = () => el("modal").classList.remove("open");
  el("modal").onclick = e => { if (e.target === el("modal")) el("close").click(); };
  el("load").onclick = loadChart;
  el("compare").onchange = loadChart;
  for (const input of [el("from"), el("to")]) input.onchange = () => {
    el(input.id.slice(5) + "-offset").innerHTML = "";
  };
  for (const delta of [-1, 1]) el(delta === -1 ? "prev" : "next").onclick = () => {
    for (const which of ["from", "to"]) {
      el(which).value = shiftCalendar(el(which).value, delta);
      el(which + "-offset").innerHTML = "";
    }
    loadChart();
  };
  el("day").onclick = () => {
    const day = el("from").value.slice(0, 10);
    el("from").value = day + "T00:00";
    el("to").value = shiftCalendar(day + "T00:00", 1);
    loadChart();
  };
  document.querySelectorAll("[data-hist-hours]").forEach(button => {
    button.onclick = () => { presetHours(Number(button.dataset.histHours)); loadChart(); };
  });
  document.getElementById("coverage-layer").onchange = async e => {
    state.layer = e.target.value;
    S.v.circles = state.layer === "model";
    document.getElementById("t-circles").checked = S.v.circles;
    if (state.layer === "measured") {
      try { await api.fetchCoverage(); } catch (error) { alert(error.message); }
    }
    renderLegend(); draw();
  };
  document.getElementById("coverage-refresh").onclick = async () => {
    try { await api.fetchCoverage(); } catch (error) { alert(error.message); }
  };
})(typeof window !== "undefined" ? window : globalThis);
