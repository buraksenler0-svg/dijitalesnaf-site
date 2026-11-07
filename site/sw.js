// Digital Esnaf AI · service worker
// Sayfaları (navigasyon) hiç yakalamaz: her açılışta en güncel sürüm gelir.
// Yalnızca ikonları ve manifest dosyasını ağ öncelikli önbelleğe alır; veri isteklerine hiç dokunmaz.
const CACHE='digital-esnaf-v8';
self.addEventListener('install',e=>self.skipWaiting());
self.addEventListener('activate',e=>e.waitUntil((async()=>{
  const adlar=await caches.keys();
  await Promise.all(adlar.filter(a=>a!==CACHE).map(a=>caches.delete(a)));
  await self.clients.claim();
})()));
self.addEventListener('fetch',e=>{
  const r=e.request;
  if(r.method!=='GET'||r.mode==='navigate')return;
  const u=new URL(r.url);
  if(u.origin!==location.origin)return;
  if(!/^\/(icon-192|icon-512|maskable-512|apple-touch-icon)\.png$|^\/favicon\.svg$|^\/manifest\.webmanifest$/.test(u.pathname))return;
  e.respondWith((async()=>{
    try{
      const yanit=await fetch(r);
      if(yanit.ok){const c=await caches.open(CACHE);c.put(r,yanit.clone()).catch(()=>{})}
      return yanit;
    }catch(h){
      const eski=await caches.match(r);
      if(eski)return eski;
      throw h;
    }
  })());
});
