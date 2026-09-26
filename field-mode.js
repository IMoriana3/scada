/* Factiun Field Mode v1
 * Offline-first inspection surface bound ONLY through IdentityRegistry asset_id.
 * Local persistence is explicit: there is no invented backend sync contract.
 */
(function(){
"use strict";
var STORE_KEY="factiun_field_inspections_v1";
var DB_NAME="factiun-field-v1";
var photosPending=[];

function esc(v){return String(v==null?"":v).replaceAll("&","&amp;").replaceAll("<","&lt;").replaceAll(">","&gt;").replaceAll('"',"&quot;");}
function uid(){return "insp-"+Date.now()+"-"+Math.random().toString(16).slice(2);}
function readAll(){try{return JSON.parse(localStorage.getItem(STORE_KEY)||"[]");}catch(e){return [];}}
function writeAll(v){localStorage.setItem(STORE_KEY,JSON.stringify(v));}
function motorAsset(m){return window.ScadaHistory?ScadaHistory.assetForMotor(m):null;}
function boundMotors(){return Array.isArray(S.motors)?S.motors.filter(function(m){return !!motorAsset(m);}):[];}
function liveFor(asset){return S&&S.scada&&S.scada.data?S.scada.data[asset]||null:null;}
function selectedMotor(){
  var sel=document.getElementById("fm-asset"); if(!sel)return null;
  var asset=sel.value; return boundMotors().find(function(m){return motorAsset(m)===asset;})||null;
}
function selectedAsset(){var m=selectedMotor();return m?motorAsset(m):null;}

function db(){
  return new Promise(function(resolve,reject){
    if(!window.indexedDB)return reject(new Error("IndexedDB no disponible"));
    var req=indexedDB.open(DB_NAME,1);
    req.onupgradeneeded=function(){var d=req.result;if(!d.objectStoreNames.contains("photos"))d.createObjectStore("photos",{keyPath:"id"});};
    req.onsuccess=function(){resolve(req.result);}; req.onerror=function(){reject(req.error);};
  });
}
async function putPhoto(rec){var d=await db();return new Promise(function(resolve,reject){var tx=d.transaction("photos","readwrite");tx.objectStore("photos").put(rec);tx.oncomplete=resolve;tx.onerror=function(){reject(tx.error);};});}

function css(){
  var st=document.createElement("style");st.id="factiun-field-css";
  st.textContent=[
    "#fm-modal{position:fixed;inset:0;z-index:60;display:none;background:rgba(4,8,12,.74);backdrop-filter:blur(4px);align-items:center;justify-content:center;padding:14px}",
    "#fm-modal.open{display:flex}.fm-box{width:min(980px,100%);max-height:94vh;overflow:auto;background:#0f151d;border:1px solid #2a3948;border-radius:16px;color:#E7EEF4;box-shadow:0 24px 90px rgba(0,0,0,.45)}",
    ".fm-head{position:sticky;top:0;z-index:2;display:flex;align-items:center;justify-content:space-between;padding:14px 16px;background:#111922;border-bottom:1px solid #23303D}.fm-head h2{margin:0;font:700 18px 'Space Grotesk',sans-serif}.fm-close{background:none;border:0;color:#aab6c2;font-size:26px;cursor:pointer}",
    ".fm-body{padding:15px}.fm-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}.fm-card{border:1px solid #23303D;border-radius:12px;background:#111922;padding:12px}.fm-card h3{margin:0 0 10px;font:700 13px 'Space Grotesk',sans-serif}.fm-card.full{grid-column:1/-1}",
    ".fm-field{display:grid;gap:5px;margin:8px 0}.fm-field label{font:600 10px 'IBM Plex Mono',monospace;text-transform:uppercase;letter-spacing:.06em;color:#8093A4}.fm-field input,.fm-field select,.fm-field textarea{width:100%;box-sizing:border-box;border:1px solid #2b3a48;background:#0b1118;color:#E7EEF4;border-radius:8px;padding:9px;font:12px 'IBM Plex Mono',monospace}.fm-field textarea{min-height:90px;resize:vertical}",
    ".fm-live{display:grid;grid-template-columns:repeat(4,1fr);gap:8px}.fm-stat{border:1px solid #22303c;border-radius:8px;padding:8px;background:#0b1118}.fm-stat .k{font:9px 'IBM Plex Mono',monospace;color:#8093A4;text-transform:uppercase}.fm-stat .v{font:700 16px 'Space Grotesk',sans-serif;margin-top:3px}",
    ".fm-check{display:grid;grid-template-columns:1fr 90px;gap:6px;align-items:center;padding:6px 0;border-bottom:1px solid #1e2a35}.fm-check select{padding:6px;background:#0b1118;color:#E7EEF4;border:1px solid #2b3a48;border-radius:7px}",
    ".fm-actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:12px}.fm-btn{border:1px solid #2d3d4d;background:#121c26;color:#dce6ee;border-radius:8px;padding:8px 11px;cursor:pointer;font:600 11px 'IBM Plex Mono',monospace}.fm-btn.primary{background:#36D399;color:#07120e;border-color:#36D399}.fm-note{font:11px/1.5 'IBM Plex Mono',monospace;color:#8093A4}.fm-warn{color:#ffd35c}.fm-good{color:#7be0a8}.fm-photo-list{font:11px 'IBM Plex Mono',monospace;color:#aab6c2}",
    "@media(max-width:700px){.fm-grid{grid-template-columns:1fr}.fm-card.full{grid-column:auto}.fm-live{grid-template-columns:repeat(2,1fr)}}"
  ].join("\n");document.head.appendChild(st);
}
var CHECKS=[
  ["structure","Estructura / tornillería / holguras"],
  ["tube","Viga de torsión / alineación"],
  ["drive","Motor / reductora / corona"],
  ["dampers","Amortiguadores / bielas"],
  ["cables","Cableado / conectores / rozamientos"],
  ["tcu","TCU / caja / sellado / fijación"],
  ["antenna","Antena / cable coaxial / posición"],
  ["obstruction","Obstáculos / vegetación / interferencias"]
];
function shell(){
  var el=document.createElement("div");el.id="fm-modal";
  var checks=CHECKS.map(function(c){return '<div class="fm-check"><span>'+esc(c[1])+'</span><select data-check="'+esc(c[0])+'"><option value="na">N/A</option><option value="ok">OK</option><option value="warn">Revisar</option><option value="fail">Defecto</option></select></div>';}).join("");
  el.innerHTML='<div class="fm-box"><div class="fm-head"><div><h2>Modo campo · inspección de tracker</h2><div class="fm-note">asset_id canónico · offline-first</div></div><button class="fm-close" id="fm-close">×</button></div><div class="fm-body"><div class="fm-grid">'+
    '<section class="fm-card full"><div class="fm-field"><label>Activo</label><select id="fm-asset"></select></div><div class="fm-live" id="fm-live"></div><div class="fm-note" id="fm-bind-note"></div></section>'+
    '<section class="fm-card"><h3>Medición física</h3><div class="fm-field"><label>Ángulo físico firmado (°)</label><input id="fm-angle" type="number" step="0.1" placeholder="medida manual / inclinómetro"></div><button class="fm-btn" id="fm-level">Usar nivel del móvil</button><div class="fm-note" id="fm-level-note">El sensor automático registra por ahora |tilt| sin signo. El signo requiere fijar una convención física de colocación del teléfono.</div></section>'+
    '<section class="fm-card"><h3>Checklist tracker</h3>'+checks+'</section>'+
    '<section class="fm-card"><h3>Evidencia</h3><div class="fm-field"><label>Fotos</label><input id="fm-photos" type="file" accept="image/*" capture="environment" multiple></div><div class="fm-photo-list" id="fm-photo-list">0 fotos pendientes</div><div class="fm-field"><label>Notas / defecto / actuación</label><textarea id="fm-notes"></textarea></div></section>'+
    '<section class="fm-card"><h3>Resultado local</h3><div class="fm-field"><label>Estado de inspección</label><select id="fm-result"><option value="open">Abierta</option><option value="ok">Conforme</option><option value="followup">Requiere actuación</option><option value="blocked">Bloqueada</option></select></div><div class="fm-note fm-warn">SYNC backend: UNKNOWN. Hasta que exista contrato Operations, el registro queda LOCAL_ONLY y se puede exportar; no se envía a una base inventada.</div></section>'+
    '</div><div class="fm-actions"><button class="fm-btn primary" id="fm-save">Guardar inspección local</button><button class="fm-btn" id="fm-export">Exportar JSON</button><button class="fm-btn" id="fm-history">Inspecciones locales</button></div><div class="fm-note" id="fm-status"></div></div></div>';
  document.body.appendChild(el);
  document.getElementById("fm-close").onclick=close;
  el.onclick=function(e){if(e.target===el)close();};
  document.getElementById("fm-asset").onchange=renderLive;
  document.getElementById("fm-photos").onchange=function(e){photosPending=Array.from(e.target.files||[]);renderPhotoList();};
  document.getElementById("fm-level").onclick=measureLevel;
  document.getElementById("fm-save").onclick=save;
  document.getElementById("fm-export").onclick=exportJson;
  document.getElementById("fm-history").onclick=showHistory;
}
function options(preferred){
  var ms=boundMotors(),sel=document.getElementById("fm-asset");
  sel.innerHTML=ms.map(function(m){var a=motorAsset(m),lab=m.tcu||(m.ncu+" · T"+m.tn);return '<option value="'+esc(a)+'">'+esc(lab+" · "+m.ncu+" · GW"+(m.gw||1))+'</option>';}).join("");
  if(preferred&&ms.some(function(m){return motorAsset(m)===preferred;}))sel.value=preferred;
  document.getElementById("fm-bind-note").textContent=ms.length+" activos con binding explícito. Los motores sin asset_id no se ofrecen por similitud ni por posición.";
}
function renderLive(){
  var asset=selectedAsset(),d=asset?liveFor(asset):null,box=document.getElementById("fm-live");
  if(!d){box.innerHTML='<div class="fm-stat"><div class="k">Live</div><div class="v">—</div></div>';return;}
  function st(k,v){return '<div class="fm-stat"><div class="k">'+esc(k)+'</div><div class="v">'+esc(v==null?"—":v)+'</div></div>';}
  var a=num(d.tilt_angle),t=num(d.target_angle),delta=(a!=null&&t!=null)?a-t:null;
  box.innerHTML=st("Health",String(d.health||"?").toUpperCase())+
    st("Ángulo",a==null?null:a.toFixed(1)+"°")+
    st("Objetivo",t==null?null:t.toFixed(1)+"°")+
    st("Δ encoder",delta==null?null:delta.toFixed(1)+"°")+
    st("Modo",modeText(d))+
    st("SoC",d.soc==null?null:Number(d.soc).toFixed(0)+"%")+
    st("Motor",d.motor_current==null?null:Number(d.motor_current).toFixed(2)+" A")+
    st("Comms",d.comms_age_s==null?null:Number(d.comms_age_s).toFixed(0)+" s");
}
async function measureLevel(){
  var note=document.getElementById("fm-level-note");
  if(typeof DeviceMotionEvent==="undefined"){note.textContent="Este dispositivo/navegador no expone acelerómetro.";return;}
  try{
    if(typeof DeviceMotionEvent.requestPermission==="function"){
      var p=await DeviceMotionEvent.requestPermission();if(p!=="granted")throw new Error("permiso denegado");
    }
    note.textContent="Apoya el teléfono plano sobre el módulo y mantenlo quieto…";
    var vals=[];
    function on(e){
      var a=e.accelerationIncludingGravity;if(!a||a.x==null||a.y==null||a.z==null)return;
      var g=Math.sqrt(a.x*a.x+a.y*a.y+a.z*a.z);if(g<5)return;
      var tilt=Math.acos(Math.min(1,Math.abs(a.z)/g))*180/Math.PI;
      vals.push(tilt);
      if(vals.length>=12){
        window.removeEventListener("devicemotion",on);
        vals.sort(function(x,y){return x-y;});var med=vals[Math.floor(vals.length/2)];
        document.getElementById("fm-angle").value=med.toFixed(1);
        note.textContent="|tilt| sensor = "+med.toFixed(1)+"°. SIGNO UNKNOWN: confirma E/O antes de usarlo como offset del encoder.";
      }
    }
    window.addEventListener("devicemotion",on);
    setTimeout(function(){window.removeEventListener("devicemotion",on);if(vals.length<3)note.textContent="No llegaron suficientes muestras del sensor.";},4000);
  }catch(e){note.textContent="No se pudo usar el sensor: "+e.message;}
}
function renderPhotoList(){document.getElementById("fm-photo-list").textContent=photosPending.length+" foto(s) pendientes de guardar offline.";}
async function save(){
  var asset=selectedAsset(),m=selectedMotor();if(!asset||!m){alert("Selecciona un activo con asset_id.");return;}
  var now=new Date(),d=liveFor(asset),id=uid(),photoIds=[];
  for(var i=0;i<photosPending.length;i++){
    var f=photosPending[i],pid=id+"-p"+(i+1);
    try{await putPhoto({id:pid,inspection_id:id,asset_id:asset,name:f.name,type:f.type,size:f.size,created_at:now.toISOString(),blob:f});photoIds.push(pid);}catch(e){}
  }
  var checks={};document.querySelectorAll("#fm-modal [data-check]").forEach(function(el){checks[el.dataset.check]=el.value;});
  var rec={
    schema_version:"field-inspection/1",
    inspection_id:id,plant:S.sc||null,asset_id:asset,
    locator:{ncu:m.ncu||null,gw:m.gw||null,tcu:m.tcu||null,physical_tcu:m.tn||null},
    created_at:now.toISOString(),sync_status:"LOCAL_ONLY",
    result:document.getElementById("fm-result").value,
    measurements:{physical_angle_deg:num(document.getElementById("fm-angle").value),physical_angle_source:"manual_or_device_unsigned"},
    checklist:checks,notes:document.getElementById("fm-notes").value||"",
    photo_ids:photoIds,
    live_snapshot:d?JSON.parse(JSON.stringify(d)):null
  };
  var all=readAll();all.push(rec);writeAll(all);photosPending=[];renderPhotoList();
  document.getElementById("fm-status").textContent="Guardado LOCAL_ONLY · "+id+" · "+photoIds.length+" foto(s).";
}
function download(name,text,type){
  var a=document.createElement("a");a.href=URL.createObjectURL(new Blob([text],{type:type||"application/json"}));a.download=name;document.body.appendChild(a);a.click();setTimeout(function(){URL.revokeObjectURL(a.href);a.remove();},0);
}
function exportJson(){download("factiun_field_inspections.json",JSON.stringify({schema_version:"field-export/1",exported_at:new Date().toISOString(),inspections:readAll()},null,2));}
function showHistory(){
  var asset=selectedAsset(),rows=readAll().filter(function(r){return !asset||r.asset_id===asset;}).slice(-12).reverse();
  alert(rows.length?rows.map(function(r){return r.created_at+" · "+r.result+" · "+r.inspection_id;}).join("\n"):"No hay inspecciones locales para este activo.");
}
function open(opts){
  var preferred=opts&&opts.asset_id?opts.asset_id:(S.ficha&&S.ficha.m?motorAsset(S.ficha.m):null);
  options(preferred);renderLive();document.getElementById("fm-modal").classList.add("open");
}
function close(){document.getElementById("fm-modal").classList.remove("open");}
function init(){
  css();shell();renderPhotoList();
  var foot=document.querySelector("#fi-modal .eq-foot");
  if(foot&&!document.getElementById("fi-field")){
    var b=document.createElement("button");b.className="btn";b.id="fi-field";b.textContent="Modo campo";b.onclick=function(){var a=S.ficha&&S.ficha.m?motorAsset(S.ficha.m):null;open({asset_id:a});};foot.prepend(b);
  }
  window.FactiunField={open:open,close:close,exportJson:exportJson,storage:"LOCAL_ONLY"};
  if("serviceWorker" in navigator&&location.protocol!=="file:")navigator.serviceWorker.register("sw.js").catch(function(){});
}
if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",init);else init();
})();
