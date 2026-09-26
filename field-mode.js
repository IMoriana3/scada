/* Field Mode core helpers. No solar/tracker physics lives here. */
(function (root) {
  "use strict";

  const API = {};

  API.SCHEMA_VERSION = "1.0.0";

  API.num = function (v) {
    if (v == null || v === "") return null;
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  };

  API.angleDeviation = function (physicalDeg, telemetryDeg) {
    const p = API.num(physicalDeg), t = API.num(telemetryDeg);
    return p == null || t == null ? null : p - t;
  };

  API.normalizedStringValues = function (rows, unit) {
    return (rows || []).map((r, i) => {
      const value = API.num(r.value);
      const modules = API.num(r.modules);
      let normalized = value;
      if (unit === "kW" && value != null && modules != null && modules > 0) {
        normalized = value * 1000 / modules; // W/module, only relative comparison.
      }
      return { index: i, label: r.label || ("String " + (i + 1)),
               value, modules, normalized };
    }).filter((r) => r.normalized != null);
  };

  API.median = function (xs) {
    const a = (xs || []).filter(Number.isFinite).slice().sort((x, y) => x - y);
    if (!a.length) return null;
    const m = Math.floor(a.length / 2);
    return a.length % 2 ? a[m] : (a[m - 1] + a[m]) / 2;
  };

  API.compareStrings = function (rows, unit) {
    const vals = API.normalizedStringValues(rows, unit);
    const med = API.median(vals.map((r) => r.normalized));
    return vals.map((r) => {
      const deviation = med && med !== 0 ? r.normalized / med - 1 : null;
      let status = "unknown";
      if (deviation != null) {
        const d = Math.abs(deviation);
        status = d <= 0.05 ? "ok" : d <= 0.10 ? "warn" : "alarm";
      }
      return { ...r, median: med, deviation, status };
    });
  };

  API.newInspection = function (asset, telemetry) {
    if (!asset || !asset.asset_id) throw new Error("asset_id required");
    return {
      schema_version: API.SCHEMA_VERSION,
      inspection_id: (root.crypto && root.crypto.randomUUID)
        ? root.crypto.randomUUID()
        : "insp-" + Date.now() + "-" + Math.random().toString(16).slice(2),
      asset_id: asset.asset_id,
      layout_key: asset.layout_key || null,
      started_at: new Date().toISOString(),
      completed_at: null,
      telemetry_snapshot: telemetry || null,
      measurements: {
        physical_tilt_deg: null,
        voc_v: null,
        isc_a: null,
      },
      strings: [],
      checklist: {},
      notes: "",
      photos: [],
      provenance: {
        surface: "scada-field-mode",
        persistence: "device-local",
        server_sync: "UNAVAILABLE_UNTIL_CONTRACT_APPROVED",
      },
    };
  };

  API.finishInspection = function (inspection) {
    return { ...inspection, completed_at: new Date().toISOString() };
  };

  if (typeof module !== "undefined" && module.exports) module.exports = API;
  root.FactiunField = API;
})(typeof window !== "undefined" ? window : globalThis);
