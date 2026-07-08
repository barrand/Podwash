const stages = ["Idle", "Clipping", "Transcribing", "Censoring", "Ready", "Failed"];

let episodes = [];
let selectedId = null;
let pollTimer = null;

const listEl = document.querySelector("#episodes");
const emptyEl = document.querySelector("#empty-state");
const detailsEl = document.querySelector("#details");
const showEl = document.querySelector("#show");
const titleEl = document.querySelector("#title");
const statePillEl = document.querySelector("#state-pill");
const sourceTypeEl = document.querySelector("#source-type");
const clipStartEl = document.querySelector("#clip-start");
const clipLengthEl = document.querySelector("#clip-length");
const targetProfileEl = document.querySelector("#target-profile");
const processModeEl = document.querySelector("#process-mode");
const processBtn = document.querySelector("#process-btn");
const reprocessBtn = document.querySelector("#reprocess-btn");
const messageEl = document.querySelector("#message");
const warningEl = document.querySelector("#warning");
const matchCountEl = document.querySelector("#match-count");
const intervalCountEl = document.querySelector("#interval-count");
const playerBlockEl = document.querySelector("#player-block");
const audioPlayerEl = document.querySelector("#audio-player");
const reportLinkEl = document.querySelector("#report-link");

function formatSeconds(value) {
  if (value === null || value === undefined) return "Full clip";
  const seconds = Number(value);
  if (!Number.isFinite(seconds)) return "Full clip";
  const minutes = Math.floor(seconds / 60);
  const remainder = Math.round(seconds % 60).toString().padStart(2, "0");
  return `${minutes}:${remainder}`;
}

async function fetchEpisodes() {
  const response = await fetch("/api/episodes");
  const payload = await response.json();
  episodes = payload.episodes;
  if (!selectedId && episodes.length) selectedId = episodes[0].id;
  render();
}

function selectedEpisode() {
  return episodes.find((episode) => episode.id === selectedId);
}

function renderList() {
  listEl.innerHTML = "";
  episodes.forEach((episode) => {
    const button = document.createElement("button");
    button.className = `episode-button${episode.id === selectedId ? " active" : ""}`;
    button.type = "button";
    button.innerHTML = `<strong></strong><span></span><span></span>`;
    button.querySelector("strong").textContent = episode.title;
    button.querySelectorAll("span")[0].textContent = episode.show;
    button.querySelectorAll("span")[1].textContent = episode.status.state;
    button.addEventListener("click", () => {
      selectedId = episode.id;
      render();
      startPollingIfNeeded();
    });
    listEl.appendChild(button);
  });
}

function renderStages(state) {
  document.querySelectorAll("#stages li").forEach((item) => {
    item.classList.remove("active", "failed");
    const stage = item.dataset.stage;
    if (state === "Failed" && stage === "Failed") item.classList.add("failed");
    if (stage === state) item.classList.add("active");
  });
}

function renderDetails() {
  const episode = selectedEpisode();
  if (!episode) {
    detailsEl.classList.add("hidden");
    emptyEl.classList.remove("hidden");
    return;
  }

  const status = episode.status;
  emptyEl.classList.add("hidden");
  detailsEl.classList.remove("hidden");
  showEl.textContent = episode.show;
  titleEl.textContent = episode.title;
  statePillEl.textContent = status.state;
  statePillEl.className = `state-pill ${status.state}`;
  sourceTypeEl.textContent = episode.source_type;
  clipStartEl.textContent = formatSeconds(episode.clip_start_seconds);
  clipLengthEl.textContent = formatSeconds(episode.clip_duration_seconds);
  targetProfileEl.textContent = episode.target_profile;
  processModeEl.textContent = episode.chunking_enabled ? "chunked" : "single";
  messageEl.textContent = status.message || "";
  matchCountEl.textContent = status.match_count ?? "-";
  intervalCountEl.textContent = status.interval_count ?? "-";

  if (status.warning) {
    warningEl.textContent = status.warning;
    warningEl.classList.remove("hidden");
  } else if (status.error) {
    warningEl.textContent = status.error;
    warningEl.classList.remove("hidden");
  } else {
    warningEl.classList.add("hidden");
  }

  renderStages(status.state);

  const processing = ["Clipping", "Transcribing", "Censoring"].includes(status.state);
  processBtn.disabled = processing || status.state === "Ready";
  reprocessBtn.disabled = processing || status.state !== "Ready";

  if (status.output_url) {
    playerBlockEl.classList.remove("hidden");
    audioPlayerEl.src = `${status.output_url}?v=${Math.round(status.updated_at || Date.now())}`;
    reportLinkEl.href = status.report_url || "#";
  } else {
    playerBlockEl.classList.add("hidden");
    audioPlayerEl.removeAttribute("src");
    reportLinkEl.href = "#";
  }
}

function render() {
  renderList();
  renderDetails();
}

async function processSelected(force = false) {
  if (!selectedId) return;
  await fetch(`/api/episodes/${encodeURIComponent(selectedId)}/process${force ? "?force=1" : ""}`, {
    method: "POST",
  });
  await refreshSelectedStatus();
  startPollingIfNeeded();
}

async function refreshSelectedStatus() {
  const episode = selectedEpisode();
  if (!episode) return;
  const response = await fetch(`/api/episodes/${encodeURIComponent(episode.id)}/status`);
  episode.status = await response.json();
  render();
}

function startPollingIfNeeded() {
  if (pollTimer) clearInterval(pollTimer);
  if (!shouldPoll()) return;
  pollTimer = setInterval(async () => {
    await refreshSelectedStatus();
    if (!shouldPoll()) {
      clearInterval(pollTimer);
      pollTimer = null;
      await fetchEpisodes();
    }
  }, 1000);
}

function shouldPoll() {
  const status = selectedEpisode()?.status;
  if (!status) return false;
  if (["Clipping", "Transcribing", "Censoring"].includes(status.state)) return true;
  return status.state === "Idle" && status.message === "Queued for processing.";
}

processBtn.addEventListener("click", () => processSelected(false));
reprocessBtn.addEventListener("click", () => processSelected(true));

fetchEpisodes().then(startPollingIfNeeded);
