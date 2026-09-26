const CACHE="factiun-field-v1";
const ASSETS=["./field.html","./field-mode.js","./field-manifest.webmanifest","./favicon.svg"];
self.addEventListener("install",e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(ASSETS)).then(()=>self.skipWaiting())));
self.addEventListener("activate",e=>e.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim())));
self.addEventListener("fetch",e=>{
  const u=new URL(e.request.url);
  if(e.request.method!=="GET") return;
  if(u.pathname.includes("/assets/live")||u.pathname.includes("/meteo")||u.pathname.includes("/traffic")){
    e.respondWith(fetch(e.request).catch(()=>caches.match(e.request)));
    return;
  }
  e.respondWith(caches.match(e.request).then(hit=>hit||fetch(e.request).then(r=>{const c=r.clone();caches.open(CACHE).then(x=>x.put(e.request,c));return r;})));
});