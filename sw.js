// In. service worker: shows notifications and opens the right run when you tap one.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('push', e => {
  let n = {};
  try { n = e.data ? e.data.json() : {}; } catch (x) { n = { body: e.data ? e.data.text() : '' }; }
  const tag = n.tag || 'in';
  e.waitUntil(self.registration.showNotification(n.title || 'In.', {
    body: n.body || '', tag, renotify: true, icon: 'icon-192.png', badge: 'icon-192.png', data: { url: n.url || './' },
  }));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || './';
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const w of wins) {
      if ('focus' in w) { await w.focus(); w.postMessage({ type: 'open', url }); return; }
    }
    await self.clients.openWindow(url);
  })());
});
