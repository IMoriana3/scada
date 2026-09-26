/* Factiun SCADA Overview v1.
 * Presentation only: same IdentityRegistry and same /assets/live payload.
 * No health reclassification, identity inference or tracker physics here.
 */
(function () {
  "use strict";
  var ID = "factiun-overview";
  var active = false;

  function esc(v) {
    return String(v == null ? "" : v)
      .replaceAll("&", "&amp;").replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;").replaceAll('"', "&quot;");
  }
  function num(v) { var x = Number(v); return Number.isFinite(x) ? x : null; }
  function pct(a, b) { return b > 0 ? 100 * a / b : null; }
  function fmt(v, d) { return v == null ? "—" : Number(v).toFixed(d == null ? 0 : d); }
  function modeText(d) {
    var v = d && (d.main_state_txt != null ? d.main_state_txt : d.main_state);
    return v == null ? null : String(v).toUpperCase();
  }
  function isAuto(d) {
    var m = modeText(d);
    return m === "AUTO" || m === "AUTOMATIC" || m === "1";
  }
  function issueRank(d) {
    var r = {alarm:0, offline:1, warn:2, ok:3};
    return r[d.health] == null ? 9 : r[d.health];
  }
  function card(k, v, s, cls) {
    return '<div class="ov-card"><div class="k">'+esc(k)+'</div><div class="v '+(cls||"")+'">'+esc(v)+'</div><div class="s">'+esc(s||"")+'</div></div>';
  }

  function installCss() {
    var st = document.createElement("style");
    st.id = "factiun-overview-css";
    st.textContent = [
      "#overview-toggle{border-color:#36D399;color:#36D399}",
      "#overview-toggle.on{background:#36D399;color:#07120e}",
      "#"+ID+"{position:absolute;inset:0;z-index:7;display:none;overflow:auto;background:linear-gradient(180deg,#0c131b 0%,#0b0f14 100%);color:#E7EEF4;padding:18px 20px 28px;font-family:'IBM Plex Sans',system-ui,sans-serif}",
      "#"+ID+".open{display:block}",
      ".ov-head{display:flex;align-items:flex-start;justify-content:space-between;gap:16px;margin-bottom:14px}",
      ".ov-title{font:700 20px/1.2 'Space Grotesk',sans-serif}",
      ".ov-sub{color:#8093A4;font:12px/1.5 'IBM Plex Mono',monospace;margin-top:4px}",
      ".ov-live{display:inline-flex;align-items:center;gap:7px;border:1px solid #23303D;border-radius:999px;padding:6px 10px;background:#101923;font:600 11px 'IBM Plex Mono',monospace}",
      ".ov-dot{width:8px;height:8px;border-radius:50%;background:#7b8794}.ov-dot.live{background:#36D399}",
      ".ov-kpis{display:grid;grid-template-columns:repeat(6,minmax(125px,1fr));gap:10px;margin-bottom:12px}",
      ".ov-card{background:#111922;border:1px solid #23303D;border-radius:12px;padding:12px 13px;min-height:82px}",
      ".ov-card .k{font:600 10px/1.2 'IBM Plex Mono',monospace;text-transform:uppercase;letter-spacing:.08em;color:#8093A4}",
      ".ov-card .v{font:700 25px/1.1 'Space Grotesk',sans-serif;margin-top:7px}",
      ".ov-card .s{font:11px/1.35 'IBM Plex Mono',monospace;color:#8093A4;margin-top:4px}",
      ".ov-good{color:#7be0a8}.ov-warn{color:#ffd35c}.ov-bad{color:#ff8a80}.ov-off{color:#aab6c2}",
      ".ov-grid{display:grid;grid-template-columns:minmax(0,1.65fr) minmax(300px,.75fr);gap:12px}",
      ".ov-panel{background:#111922;border:1px solid #23303D;border-radius:12px;overflow:hidden}",
      ".ov-panel-h{display:flex;align-items:center;justify-content:space-between;padding:11px 13px;border-bottom:1px solid #23303D}",
      ".ov-panel-h b{font:700 13px 'Space Grotesk',sans-serif}.ov-panel-h span{font:11px 'IBM Plex Mono',monospace;color:#8093A4}",
      ".ov-table{width:100%;border-collapse:collapse;font-size:12px}.ov-table th{position:sticky;top:0;background:#0f151d;text-align:left;color:#8093A4;font:600 10px 'IBM Plex Mono',monospace;text-transform:uppercase;letter-spacing:.05em}",
      ".ov-table th,.ov-table td{padding:8px 10px;border-bottom:1px solid #1d2935}.ov-table tr[data-asset]{cursor:pointer}.ov-table tr[data-asset]:hover{background:#16212c}",
      ".ov-badge{display:inline-flex;align-items:center;border-radius:999px;padding:3px 7px;font:700 10px 'IBM Plex Mono',monospace}.ov-badge.ok{background:#173629;color:#7be0a8}.ov-badge.warn{background:#3b3216;color:#ffd35c}.ov-badge.alarm{background:#421d20;color:#ff8a80}.ov-badge.offline{background:#26313b;color:#c0c8cf}",
      ".ov-bars{padding:12px}.ov-bar{display:grid;grid-template-columns:82px 1fr 44px;align-items:center;gap:8px;margin:9px 0;font:11px 'IBM Plex Mono',monospace}.ov-track{height:8px;background:#202c37;border-radius:999px;overflow:hidden}.ov-fill{height:100%;border-radius:999px;background:#36D399}",
      ".ov-empty{padding:30px 14px;text-align:center;color:#8093A4;font:12px/1.6 'IBM Plex Mono',monospace}.ov-actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:12px}.ov-btn{border:1px solid #2d3d4d;background:#121c26;color:#dce6ee;border-radius:8px;padding:7px 10px;cursor:pointer;font:600 11px 'IBM Plex Mono',monospace}.ov-btn:hover{border-color:#36D399;color:#7be0a8}",
      "@media(max-width:1100px){.ov-kpis{grid-template-columns:repeat(3,1fr)}.ov-grid{grid-template-columns:1fr}}",
      "@media(max-width:650px){#"+ID+"{padding:12px}.ov-kpis{grid-template-columns:repeat(2,1fr)}.ov-card .v{font-size:21px}.ov-table .hide-sm{display:none}}"
    ].join("\n");
    document.head.appendChild(st);
  }

  function installShell() {
    var stage = document.getElementById("stage");
    if (!stage || document.getElementById(ID)) return;
    var el = document.createElement("section");
    el.id = ID;
    el.innerHTML =
      '<div class="ov-head"><div><div class="ov-title">Power Plant Overview</div><div class="ov-sub" id="ov-plant">Factiun · misma identidad y telemetría del SCADA</div></div><div class="ov-live"><i class="ov-dot" id="ov-dot"></i><span id="ov-live">SCADA desconectado</span></div></div>'+
      '<div class="ov-kpis" id="ov-kpis"></div>'+
      '<div class="ov-grid"><div class="ov-panel"><div class="ov-panel-h"><b>Activos que requieren atención</b><span id="ov-issues-count">—</span></div><div id="ov-issues"></div></div>'+
      '<div class="ov-panel"><div class="ov-panel-h"><b>Estado de planta</b><span>live</span></div><div class="ov-bars" id="ov-bars"></div></div></div>'+
      '<div class="ov-actions"><button class="ov-btn" id="ov-map">Abrir plano de planta</button><button class="ov-btn" id="ov-connect">Conectar / reconectar SCADA</button><button class="ov-btn" id="ov-field">Modo campo</button></div>';
    stage.appendChild(el);

    var actions = document.querySelector(".stage-actions");
    if (actions) {
      var b = document.createElement("button");
      b.className = "btn";
      b.id = "overview-toggle";
      b.textContent = "Overview";
      b.title = "Resumen operacional de planta";
      actions.prepend(b);
      b.onclick = function () { setActive(!active); };
    }
    document.getElementById("ov-map").onclick = function () { setActive(false); };
    document.getElementById("ov-connect").onclick = async function () {
      try { if (typeof scadaStart === "function") await scadaStart(); }
      finally { render(); }
    };
    document.getElementById("ov-field").onclick = function () {
      if (window.FactiunField && typeof window.FactiunField.open === "function") window.FactiunField.open();
      else alert("Modo campo no disponible en esta versión.");
    };
  }

  function setActive(on) {
    active = !!on;
    var el = document.getElementById(ID);
    var b = document.getElementById("overview-toggle");
    if (el) el.classList.toggle("open", active);
    if (b) b.classList.toggle("on", active);
    if (active) render();
  }

  function findMotor(assetId) {
    if (!window.ScadaHistory || !Array.isArray(S.motors)) return null;
    return S.motors.find(function (m) { return ScadaHistory.assetForMotor(m) === assetId; }) || null;
  }
  function openAsset(assetId) {
    var m = findMotor(assetId);
    if (!m || typeof fiOpen !== "function") return;
    setActive(false);
    fiOpen({m:m, ncu:m.ncu, gw:m.gw||1, tn:m.tn, stale:false});
  }

  function render() {
    if (!document.getElementById(ID)) return;
    var data = S && S.scada ? Object.values(S.scada.data || {}) : [];
    var connected = !!(S && S.scada && S.scada.on);
    var dot = document.getElementById("ov-dot");
    dot.classList.toggle("live", connected && !S.scada.err);
    document.getElementById("ov-live").textContent = connected ?
      (S.scada.err ? "SCADA con error" : "Live · "+(S.scada.last ? S.scada.last.toLocaleTimeString().slice(0,8) : "conectando")) :
      "SCADA desconectado";
    var tag = document.querySelector(".header .tag");
    document.getElementById("ov-plant").textContent = (tag ? tag.textContent : (S.sc || "Planta"))+" · Overview operacional";

    if (!data.length) {
      document.getElementById("ov-kpis").innerHTML =
        card("TCU del plano", Array.isArray(S.motors) ? S.motors.length : "—", "inventario visual", "")+
        card("Telemetría", "—", connected ? "sin respuesta live" : "conecta SCADA", "ov-off")+
        card("Alarmas", "—", "sin dato", "")+card("Offline", "—", "sin dato", "")+
        card("AUTO", "—", "sin dato", "")+card("Δ ángulo", "—", "sin dato", "");
      document.getElementById("ov-issues").innerHTML = '<div class="ov-empty">Sin telemetría live. El Overview no inventa estado a partir del plano.</div>';
      document.getElementById("ov-bars").innerHTML = '<div class="ov-empty">Conecta la API para ver salud, modo, SoC y seguimiento.</div>';
      return;
    }

    var c={ok:0,warn:0,alarm:0,offline:0}, auto=0, modeKnown=0, socSum=0, socN=0, errSum=0, errN=0, badAngle=0;
    data.forEach(function(d){
      if(c[d.health]!=null)c[d.health]++;
      if(modeText(d)!=null){modeKnown++;if(isAuto(d))auto++;}
      var soc=num(d.soc);if(soc!=null){socSum+=soc;socN++;}
      var a=num(d.tilt_angle),t=num(d.target_angle);
      if(a!=null&&t!=null){var e=Math.abs(a-t);errSum+=e;errN++;if(e>5)badAngle++;}
    });
    var healthy=pct(c.ok,data.length),autoPct=pct(auto,modeKnown),avgSoc=socN?socSum/socN:null,avgErr=errN?errSum/errN:null;
    var wind=null;try{wind=JSON.parse(localStorage.getItem("factiun_meteo")||"null");}catch(e){}
    var windTxt=wind&&num(wind.ws)!=null?fmt(wind.ws,1)+" m/s":"—";
    document.getElementById("ov-kpis").innerHTML =
      card("Disponibles",fmt(healthy,1)+" %",c.ok+"/"+data.length+" TCU OK",healthy>=98?"ov-good":healthy>=95?"ov-warn":"ov-bad")+
      card("Alarmas",c.alarm,c.warn+" aviso · "+c.offline+" offline",c.alarm?"ov-bad":c.warn?"ov-warn":"ov-good")+
      card("Modo AUTO",autoPct==null?"—":fmt(autoPct,1)+" %",modeKnown?auto+"/"+modeKnown:"campo no disponible",autoPct!=null&&autoPct<99?"ov-warn":"ov-good")+
      card("Δ ángulo medio",avgErr==null?"—":fmt(avgErr,2)+"°",badAngle+" TCU > 5°",badAngle?"ov-warn":"ov-good")+
      card("SoC medio",avgSoc==null?"—":fmt(avgSoc,0)+" %",socN+" lecturas",avgSoc!=null&&avgSoc<30?"ov-bad":"")+
      card("Viento planta",windTxt,wind&&num(wind.wd)!=null?fmt(wind.wd,0)+"° · "+(wind.n||1)+" HSU":"HSU sin dato","");

    var issues=data.filter(function(d){
      var a=num(d.tilt_angle),t=num(d.target_angle);
      return d.health!=="ok" || !isAuto(d) || (a!=null&&t!=null&&Math.abs(a-t)>5);
    }).sort(function(a,b){return issueRank(a)-issueRank(b);}).slice(0,50);
    document.getElementById("ov-issues-count").textContent=issues.length+(issues.length===50?"+":"")+" mostrados";
    if(!issues.length){
      document.getElementById("ov-issues").innerHTML='<div class="ov-empty">No hay activos live que requieran atención con los criterios contractuales actuales.</div>';
    } else {
      var rows=issues.map(function(d){
        var a=num(d.tilt_angle),t=num(d.target_angle),delta=(a!=null&&t!=null)?Math.abs(a-t):null;
        var label=d.tcu||d.asset_id||"TCU";
        var detail=d.alarms||(delta!=null&&delta>5?"Δ "+fmt(delta,1)+"°":(!isAuto(d)?"No AUTO":"—"));
        return '<tr data-asset="'+esc(d.asset_id||"")+'"><td><b>'+esc(label)+'</b><br><span style="color:#8093A4;font:10px IBM Plex Mono">'+esc(d.ncu||"")+'</span></td><td><span class="ov-badge '+esc(d.health||"offline")+'">'+esc((d.health||"?").toUpperCase())+'</span></td><td class="hide-sm">'+esc(modeText(d)||"—")+'</td><td>'+(a==null?"—":fmt(a,1)+"°")+(t==null?"":" / "+fmt(t,1)+"°")+'</td><td class="hide-sm">'+esc(detail)+'</td></tr>';
      }).join("");
      document.getElementById("ov-issues").innerHTML='<table class="ov-table"><thead><tr><th>Activo</th><th>Estado</th><th class="hide-sm">Modo</th><th>Ángulo</th><th class="hide-sm">Alarma / motivo</th></tr></thead><tbody>'+rows+'</tbody></table>';
      document.querySelectorAll("#ov-issues tr[data-asset]").forEach(function(tr){tr.onclick=function(){openAsset(tr.dataset.asset);};});
    }

    var bars=[["OK",c.ok,"#36D399"],["Aviso",c.warn,"#ffd35c"],["Alarma",c.alarm,"#ff8a80"],["Offline",c.offline,"#7b8794"]];
    document.getElementById("ov-bars").innerHTML=bars.map(function(x){
      var p=pct(x[1],data.length)||0;
      return '<div class="ov-bar"><span>'+x[0]+'</span><span class="ov-track"><i class="ov-fill" style="width:'+p+'%;background:'+x[2]+'"></i></span><b>'+x[1]+'</b></div>';
    }).join("")+'<div class="ov-empty" style="padding:14px 2px 4px;text-align:left">Los colores reutilizan <b>health</b> del collector; esta vista no crea umbrales alternativos.</div>';
  }

  function init() {
    if(document.getElementById("factiun-overview-css"))return;
    installCss();installShell();render();
    setInterval(function(){if(active)render();},2000);
    window.FactiunOverview={open:function(){setActive(true);},close:function(){setActive(false);},render:render};
  }
  if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",init);else init();
})();
