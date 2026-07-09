// Service Worker de Upco InsurGest: recibe notificaciones push aunque la app esté cerrada.
self.addEventListener("push", (event) => {
  let data = { title: "Upco InsurGest", body: "Tienes un pendiente." };
  try { data = event.data.json(); } catch (e) {}
  event.waitUntil(
    self.registration.showNotification(data.title || "Upco InsurGest", {
      body: data.body || "",
      icon: "icon-192.png",
      badge: "icon-192.png",
      vibrate: [200, 100, 200],
      data: { url: data.url || "./" },
    })
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || "./";
  event.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
      for (const c of list) { if ("focus" in c) return c.focus(); }
      if (clients.openWindow) return clients.openWindow(url);
    })
  );
});
