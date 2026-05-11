const CACHE = 'ecotrip-v31';
const SHELL = ['/', '/app.js', '/style.css', '/manifest.json'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)));
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys =>
    Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
  ));
  self.clients.claim();
});

self.addEventListener('fetch', e => {
  // API calls: network first, sem cache
  if (e.request.url.includes('/api/')) {
    e.respondWith(fetch(e.request).catch(() => new Response('{}', { headers: { 'Content-Type': 'application/json' } })));
    return;
  }
  // Shell: cache first
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
