const CACHE="factiun-scada-v1";
const CORE=["./","./index.html","./historical-ui.js","./overview-ui.js","./field-mode.js","./favicon.svg","./lib/xlsx.full.min.js","./manifest.json"];
self.addEventListener("install",function(e){e.waitUntil(caches.open(CACHE).then(function(c){return c.addAll(CORE);}).then(function(){return self.skipWaiting();}));});
self.addEventListener("activate",function(e){e.waitUntil(caches.keys().then(function(keys){return Promise.all(keys.filter(function(k){return k!==CACHE;}).map(function(k){return caches.delete(k);}));}).then(function(){return self.clients.claim();}));});
self.addEventListener("fetch",function(e){
  if(e.request.method!=="GET")return;
  var u=new URL(e.request.url);
  if(u.origin!==self.location.origin)return;
  e.respondWith(fetch(e.request).then(function(r){
    if(r&&r.ok){var copy=r.clone();caches.open(CACHE).then(function(c){c.put(e.request,copy);});}
    return r;
  }).catch(function(){return caches.match(e.request).then(function(r){return r||caches.match("./index.html");});}));
});