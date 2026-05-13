const CACHE = 'ecotrip-v152';
// app.js e style.css: NETWORK first (código sempre atualizado)
// index.html e manifest: cache first (estrutura estável)
const NETWORK_FIRST = ['/app.js', '/style.css'];
const SHELL         = ['/', '/manifest.json'];

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE)
      .then(c => c.addAll([...SHELL, ...NETWORK_FIRST]))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.matchAll({ type: 'window' }))
      .then(clients => clients.forEach(c => c.postMessage({ type: 'SW_UPDATED' })))
  );
  self.clients.claim();
});

self.addEventListener('fetch', e => {
  const url = e.request.url;

  // API: network only
  if (url.includes('/api/')) {
    e.respondWith(fetch(e.request).catch(() => new Response('{}', { headers: { 'Content-Type': 'application/json' } })));
    return;
  }

  // app.js + style.css: network first → atualiza cache → fallback cache se offline
  if (NETWORK_FIRST.some(p => url.includes(p))) {
    e.respondWith(
      fetch(e.request)
        .then(r => {
          if (r.ok) {
            const clone = r.clone();
            caches.open(CACHE).then(c => c.put(e.request, clone));
          }
          return r;
        })
        .catch(() => caches.match(e.request))
    );
    return;
  }

  // Resto do shell: cache first
  e.respondWith(
    caches.match(e.request).then(cached => cached || fetch(e.request))
  );
});

// ── Push Notifications ────────────────────────────────────────────────────────
self.addEventListener('push', e => {
  let data = { title: 'EcoTrip', body: '' };
  try { data = e.data?.json() || data; } catch (_) {}
  e.waitUntil(
    self.registration.showNotification(data.title, {
      body:      data.body,
      icon:      '/icon-192.png',
      badge:     '/icon-192.png',
      tag:       'ecotrip-charge',
      renotify:  true,
      vibrate:   [200, 100, 200],
    })
  );
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
      const focused = list.find(c => c.url.includes(self.location.origin) && 'focus' in c);
      return focused ? focused.focus() : clients.openWindow('/');
    })
  );
});
