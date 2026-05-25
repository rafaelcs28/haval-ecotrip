const CACHE = 'ecotrip-v367';

// Tudo do shell do PWA (HTML/CSS/JS/icons/libs) — pre-cached no install.
// Bumpar CACHE acima força o navegador a re-baixar tudo na próxima vez.
const PRECACHE = [
  '/',
  '/index.html',
  '/manifest.json',
  '/view-dash.html',
  '/view-drive.html',
  '/view-conforto.html',
  '/view-posto.html',
  '/view-desloc.html',
  '/view-logs.html',
  '/view-config.html',
  '/leaflet.css',
  '/leaflet.js',
  '/chart.min.js',
  '/simplewebauthn-browser.umd.min.js',
  '/icon-192.png',
  '/icon-512.png',
];

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE)
      // addAll falha se QUALQUER url falhar. Usa allSettled em put pra ser tolerante.
      .then(c => Promise.allSettled(PRECACHE.map(u =>
        fetch(u, { cache: 'no-cache' }).then(r => r.ok && c.put(u, r)).catch(() => {})
      )))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.matchAll({ type: 'window' }))
      .then(clients => clients.forEach(c => c.postMessage({ type: 'SW_UPDATED', version: CACHE })))
  );
  self.clients.claim();
});

// Estratégia "stale-while-revalidate" pro shell:
// - Serve do cache IMEDIATO (PWA abre instantâneo)
// - Em paralelo, busca da rede e atualiza o cache pra próxima vez
// Resultado: app carrega offline ou em segundos mesmo com 3G ruim.
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);

  // APIs: sempre network (dados frescos)
  if (url.pathname.startsWith('/api/')) {
    e.respondWith(
      fetch(e.request).catch(() =>
        new Response('{}', { headers: { 'Content-Type': 'application/json' } })
      )
    );
    return;
  }

  // Tiles de mapa do CartoCDN: cache-first (mapas raramente mudam)
  if (url.hostname.endsWith('basemaps.cartocdn.com')) {
    e.respondWith(
      caches.match(e.request).then(cached => {
        if (cached) return cached;
        return fetch(e.request).then(r => {
          if (r.ok) {
            const clone = r.clone();
            caches.open(CACHE).then(c => c.put(e.request, clone));
          }
          return r;
        }).catch(() => cached);
      })
    );
    return;
  }

  // Shell (HTML/CSS/JS/icons): stale-while-revalidate
  e.respondWith(
    caches.match(e.request).then(cached => {
      const networkFetch = fetch(e.request).then(r => {
        if (r.ok && (url.pathname === '/' || url.pathname.endsWith('.html') ||
                     url.pathname.endsWith('.js') || url.pathname.endsWith('.css') ||
                     url.pathname.endsWith('.png'))) {
          const clone = r.clone();
          caches.open(CACHE).then(c => c.put(e.request, clone));
        }
        return r;
      }).catch(() => cached);
      return cached || networkFetch;
    })
  );
});

// Permite o cliente checar a versão atual do SW
self.addEventListener('message', e => {
  if (e.data && e.data.type === 'GET_VERSION') {
    e.ports[0]?.postMessage({ version: CACHE });
  }
});

// ── Push Notifications ────────────────────────────────────────────────────────
// O payload pode incluir tag/silent/renotify customizados pra "notification ao
// vivo" durante recarga (mesmo tag = substitui a anterior, silent = atualiza
// sem ding/vibração). Sem isso, cai no comportamento legado: tag fixa de carga
// + renotify true.
self.addEventListener('push', e => {
  let data = { title: 'EcoTrip', body: '' };
  try { data = e.data?.json() || data; } catch (_) {}
  const tag      = data.tag      || 'ecotrip-charge';
  const silent   = data.silent   === true;
  const renotify = data.renotify !== undefined ? !!data.renotify : !silent;
  const opts = {
    body:     data.body,
    icon:     '/icon-192.png',
    badge:    '/icon-192.png',
    tag,
    renotify,
    silent,
  };
  if (!silent) opts.vibrate = [200, 100, 200];
  e.waitUntil(self.registration.showNotification(data.title, opts));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil((async () => {
    // Tenta abrir o app nativo iOS via URL scheme havalecotrip://
    // (registrado no Info.plist do app wrapper). Se o app não estiver
    // instalado, o iOS abre o PWA normal como fallback silencioso.
    try {
      await clients.openWindow('havalecotrip://open');
      return;
    } catch (_) {}
    // Fallback: foca uma janela do PWA já aberta, senão abre nova
    const list = await clients.matchAll({ type: 'window', includeUncontrolled: true });
    const focused = list.find(c => c.url.includes(self.location.origin) && 'focus' in c);
    if (focused) return focused.focus();
    return clients.openWindow('/');
  })());
});
