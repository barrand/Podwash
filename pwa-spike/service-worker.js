const SHELL_CACHE = "podwash-pwa-spike-shell-v1";
const AUDIO_CACHE = "podwash-pwa-spike-audio-v1";
const AUDIO_PATH = "/audio/episode.mp3";
const SHELL_ASSETS = [
  "/",
  "/index.html",
  "/styles.css",
  "/app.js",
  "/manifest.webmanifest",
  "/icons/icon-192.png",
  "/icons/icon-512.png",
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(SHELL_CACHE).then((cache) => cache.addAll(SHELL_ASSETS))
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((names) =>
      Promise.all(
        names
          .filter((name) => ![SHELL_CACHE, AUDIO_CACHE].includes(name))
          .map((name) => caches.delete(name))
      )
    )
  );
  self.clients.claim();
});

self.addEventListener("message", (event) => {
  if (event.data?.type === "SKIP_WAITING") {
    self.skipWaiting();
  }
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);

  if (url.origin === self.location.origin && url.pathname === AUDIO_PATH) {
    event.respondWith(handleAudioRequest(event.request));
    return;
  }

  if (event.request.mode === "navigate") {
    event.respondWith(cacheFirst("/index.html", event.request));
    return;
  }

  if (url.origin === self.location.origin) {
    event.respondWith(cacheFirst(url.pathname, event.request));
  }
});

async function cacheFirst(cacheKey, request) {
  const cache = await caches.open(SHELL_CACHE);
  const cached = await cache.match(cacheKey);
  if (cached) return cached;

  const response = await fetch(request);
  if (response.ok && request.method === "GET") {
    cache.put(cacheKey, response.clone());
  }
  return response;
}

async function handleAudioRequest(request) {
  const cache = await caches.open(AUDIO_CACHE);
  const cached = await cache.match(AUDIO_PATH, { ignoreSearch: true });

  if (!cached) {
    return fetch(request);
  }

  const rangeHeader = request.headers.get("Range");
  if (!rangeHeader) {
    return cached;
  }

  const range = parseRangeHeader(rangeHeader);
  if (!range) {
    return new Response(null, { status: 416 });
  }

  const buffer = await cached.arrayBuffer();
  const size = buffer.byteLength;
  const start = range.start ?? Math.max(size - range.suffixLength, 0);
  const end = Math.min(range.end ?? size - 1, size - 1);

  if (start >= size || end < start) {
    return new Response(null, {
      status: 416,
      headers: {
        "Content-Range": `bytes */${size}`,
        "Accept-Ranges": "bytes",
      },
    });
  }

  const body = buffer.slice(start, end + 1);
  return new Response(body, {
    status: 206,
    statusText: "Partial Content",
    headers: {
      "Content-Range": `bytes ${start}-${end}/${size}`,
      "Accept-Ranges": "bytes",
      "Content-Length": String(body.byteLength),
      "Content-Type": "audio/mpeg",
    },
  });
}

function parseRangeHeader(rangeHeader) {
  const match = rangeHeader.match(/^bytes=(\d*)-(\d*)$/);
  if (!match) return null;

  const [, startText, endText] = match;
  if (!startText && !endText) return null;

  if (!startText) {
    return { suffixLength: Number(endText) };
  }

  return {
    start: Number(startText),
    end: endText ? Number(endText) : undefined,
  };
}
