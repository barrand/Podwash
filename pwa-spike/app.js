const AUDIO_URL = "/audio/episode.mp3";
const CACHE_NAME = "podwash-pwa-spike-audio-v1";
const DOWNLOADED_KEY = "podwash.pwaSpike.downloaded";
const CHECKLIST_KEY = "podwash.pwaSpike.checklist";

const player = document.querySelector("#player");
const networkStatus = document.querySelector("#networkStatus");
const downloadButton = document.querySelector("#downloadButton");
const removeButton = document.querySelector("#removeButton");
const downloadState = document.querySelector("#downloadState");
const storageEstimate = document.querySelector("#storageEstimate");
const persistState = document.querySelector("#persistState");
const message = document.querySelector("#message");
const checks = [...document.querySelectorAll("[data-check]")];

function setMessage(text) {
  message.textContent = text;
}

function formatBytes(bytes) {
  if (!Number.isFinite(bytes)) return "Unknown";
  const units = ["B", "KB", "MB", "GB"];
  let value = bytes;
  let index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  return `${value.toFixed(value >= 10 || index === 0 ? 0 : 1)} ${units[index]}`;
}

function updateNetworkStatus() {
  const online = navigator.onLine;
  networkStatus.textContent = online ? "Online" : "Offline";
  networkStatus.classList.toggle("online", online);
  networkStatus.classList.toggle("offline", !online);
}

async function updateStorageEstimate() {
  if (!navigator.storage?.estimate) {
    storageEstimate.textContent = "Unavailable";
    return;
  }

  const estimate = await navigator.storage.estimate();
  const usage = formatBytes(estimate.usage);
  const quota = formatBytes(estimate.quota);
  storageEstimate.textContent = `${usage} of ${quota}`;
}

async function updatePersistState() {
  if (!navigator.storage?.persist) {
    persistState.textContent = "Unavailable";
    return;
  }

  const persisted = await navigator.storage.persisted?.();
  if (persisted) {
    persistState.textContent = "Granted";
    return;
  }

  const granted = await navigator.storage.persist();
  persistState.textContent = granted ? "Granted" : "Not granted";
}

async function isDownloaded() {
  const cache = await caches.open(CACHE_NAME);
  const response = await cache.match(AUDIO_URL, { ignoreSearch: true });
  return Boolean(response);
}

async function updateDownloadState() {
  const downloaded = await isDownloaded();
  localStorage.setItem(DOWNLOADED_KEY, downloaded ? "true" : "false");
  downloadState.textContent = downloaded
    ? "Downloaded. This should survive close/reopen and airplane mode."
    : "Not downloaded yet.";
  downloadButton.disabled = downloaded;
  removeButton.disabled = !downloaded;
}

async function downloadEpisode() {
  downloadButton.disabled = true;
  removeButton.disabled = true;
  setMessage("Downloading full episode into Cache API.");

  try {
    const response = await fetch(AUDIO_URL, { cache: "reload" });
    if (!response.ok) {
      throw new Error(`Download failed with HTTP ${response.status}`);
    }

    const cache = await caches.open(CACHE_NAME);
    await cache.put(AUDIO_URL, response.clone());
    localStorage.setItem(DOWNLOADED_KEY, "true");
    await updateDownloadState();
    await updateStorageEstimate();
    setMessage("Download complete. Try closing, reopening, airplane mode, and seeking.");
  } catch (error) {
    console.error(error);
    setMessage(error.message);
    await updateDownloadState();
  }
}

async function removeEpisode() {
  downloadButton.disabled = true;
  removeButton.disabled = true;
  const cache = await caches.open(CACHE_NAME);
  await cache.delete(AUDIO_URL, { ignoreSearch: true });
  localStorage.setItem(DOWNLOADED_KEY, "false");
  await updateDownloadState();
  await updateStorageEstimate();
  setMessage("Removed cached episode.");
}

function restoreChecklist() {
  const saved = JSON.parse(localStorage.getItem(CHECKLIST_KEY) || "{}");
  for (const check of checks) {
    check.checked = Boolean(saved[check.dataset.check]);
    check.addEventListener("change", () => {
      const next = JSON.parse(localStorage.getItem(CHECKLIST_KEY) || "{}");
      next[check.dataset.check] = check.checked;
      localStorage.setItem(CHECKLIST_KEY, JSON.stringify(next));
    });
  }
}

function setupMediaSession() {
  if (!("mediaSession" in navigator)) return;

  navigator.mediaSession.metadata = new MediaMetadata({
    title: "Maximal Americanness",
    artist: "This American Life",
    album: "PodWash PWA playback spike",
    artwork: [
      { src: "/icons/icon-192.png", sizes: "192x192", type: "image/png" },
      { src: "/icons/icon-512.png", sizes: "512x512", type: "image/png" },
    ],
  });

  navigator.mediaSession.setActionHandler("play", () => player.play());
  navigator.mediaSession.setActionHandler("pause", () => player.pause());
  navigator.mediaSession.setActionHandler("seekbackward", (event) => {
    player.currentTime = Math.max(player.currentTime - (event.seekOffset || 15), 0);
  });
  navigator.mediaSession.setActionHandler("seekforward", (event) => {
    player.currentTime = Math.min(player.currentTime + (event.seekOffset || 30), player.duration || Infinity);
  });
  navigator.mediaSession.setActionHandler("seekto", (event) => {
    if (event.fastSeek && "fastSeek" in player) {
      player.fastSeek(event.seekTime);
      return;
    }
    player.currentTime = event.seekTime;
  });
}

async function registerServiceWorker() {
  if (!("serviceWorker" in navigator)) {
    setMessage("Service workers are not supported in this browser.");
    return;
  }

  const registration = await navigator.serviceWorker.register("/service-worker.js");
  await navigator.serviceWorker.ready;
  if (registration.waiting) {
    registration.waiting.postMessage({ type: "SKIP_WAITING" });
  }
}

async function init() {
  updateNetworkStatus();
  restoreChecklist();
  setupMediaSession();

  window.addEventListener("online", updateNetworkStatus);
  window.addEventListener("offline", updateNetworkStatus);
  downloadButton.addEventListener("click", downloadEpisode);
  removeButton.addEventListener("click", removeEpisode);

  await registerServiceWorker();
  await updatePersistState();
  await updateDownloadState();
  await updateStorageEstimate();
  setMessage("Ready.");
}

init().catch((error) => {
  console.error(error);
  setMessage(error.message);
});
