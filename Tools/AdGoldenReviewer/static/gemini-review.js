"use strict";

const select = document.getElementById("episodeSelect");
const transcript = document.getElementById("transcript");
const metrics = document.getElementById("metrics");
const goldenList = document.getElementById("goldenList");
const geminiList = document.getElementById("geminiList");
const deltaList = document.getElementById("deltaList");
const deltaCount = document.getElementById("deltaCount");
const previousDelta = document.getElementById("previousDelta");
const nextDelta = document.getElementById("nextDelta");
const subtitle = document.getElementById("subtitle");
let wordElements = [];
let deltas = [];
let activeDelta = -1;

async function api(path) {
  const response = await fetch(path);
  const payload = await response.json();
  if (!response.ok) throw new Error(payload.error || response.statusText);
  return payload;
}

function percent(value) { return `${(Number(value || 0) * 100).toFixed(1)}%`; }
function seconds(value) { return `${Number(value || 0).toFixed(1)} sec/hr`; }

function rangeMap(spans, className, words) {
  const marks = new Array(words.length).fill(false);
  spans.forEach((span) => {
    for (let index = span.startWord; index < span.endWord; index += 1) marks[index] = true;
  });
  return marks;
}

function jump(startWord) { wordElements[startWord]?.scrollIntoView({ behavior: "smooth", block: "center" }); }

function deltaRuns(golden, gemini, words) {
  const typeAt = (index) => {
    if (golden[index] && !gemini[index]) return "missed";
    if (gemini[index] && !golden[index]) return "extra";
    return null;
  };
  const runs = [];
  let start = 0; let type = typeAt(0);
  for (let index = 1; index <= words.length; index += 1) {
    const next = index < words.length ? typeAt(index) : null;
    if (next === type) continue;
    if (type) runs.push({ type, startWord: start, endWord: index, start: words[start].start, end: words[index - 1].end });
    start = index; type = next;
  }
  return runs;
}

function renderDeltas() {
  deltaList.textContent = "";
  deltaCount.textContent = deltas.length ? `${deltas.length} regions` : "none";
  previousDelta.disabled = !deltas.length;
  nextDelta.disabled = !deltas.length;
  if (!deltas.length) { deltaList.innerHTML = "<li class='muted'>No yellow-only or purple-only regions.</li>"; return; }
  deltas.forEach((delta, index) => {
    const item = document.createElement("li"); const button = document.createElement("button");
    const kind = delta.type === "missed" ? "Missed by Gemini (yellow)" : "Gemini-only coverage (purple)";
    button.textContent = `${kind}: ${delta.start.toFixed(1)}–${delta.end.toFixed(1)}`;
    button.addEventListener("click", () => { activeDelta = index; jump(delta.startWord); });
    item.append(button); deltaList.append(item);
  });
}

function moveDelta(direction) {
  if (!deltas.length) return;
  activeDelta = (activeDelta + direction + deltas.length) % deltas.length;
  jump(deltas[activeDelta].startWord);
}

function renderSpanList(container, spans, title) {
  container.textContent = "";
  if (!spans.length) { container.innerHTML = "<li class='muted'>None</li>"; return; }
  spans.forEach((span, index) => {
    const item = document.createElement("li");
    const button = document.createElement("button");
    const label = span.label ? ` · ${span.label.replaceAll("_", " ")}` : "";
    button.textContent = `${title} ${index + 1}: ${span.start.toFixed(1)}–${span.end.toFixed(1)}${label}`;
    button.addEventListener("click", () => jump(span.startWord));
    item.append(button); container.append(item);
  });
}

function renderEpisode(data) {
  const tw = data.score.timeWeighted || {};
  subtitle.textContent = `${data.showName} · ${data.title} · ${data.model}`;
  metrics.innerHTML = `<h2>Measured result</h2><div class="metric">
    <span>Time precision</span><strong>${percent(tw.precision)}</strong>
    <span>Time recall</span><strong>${percent(tw.recall)}</strong>
    <span>Content loss</span><strong>${seconds(data.score.contentLossSecondsPerListeningHour)}</strong>
    <span>Missed ads</span><strong>${seconds(data.score.missedAdSecondsPerListeningHour)}</strong>
    <span>API cost</span><strong>$${Number(data.cost.totalCostUsd || 0).toFixed(4)}</strong>
  </div>`;
  const golden = rangeMap(data.goldenSpans, "golden", data.words);
  const gemini = rangeMap(data.geminiSpans, "gemini", data.words);
  deltas = deltaRuns(golden, gemini, data.words); activeDelta = -1; renderDeltas();
  transcript.textContent = ""; wordElements = new Array(data.words.length);
  const fragment = document.createDocumentFragment(); let paragraph = document.createElement("p"); paragraph.className = "paragraph";
  data.words.forEach((word, index) => {
    const element = document.createElement("span"); element.className = "word"; element.textContent = word.word; element.id = `word-${index}`;
    if (golden[index] && gemini[index]) element.classList.add("both");
    else if (golden[index]) element.classList.add("golden");
    else if (gemini[index]) element.classList.add("gemini");
    wordElements[index] = element; paragraph.append(element, document.createTextNode(" "));
    if ((/[.!?]["')\]]?$/.test(String(word.word)) && index % 38 > 20) || index % 110 === 109) { fragment.append(paragraph); paragraph = document.createElement("p"); paragraph.className = "paragraph"; }
  });
  if (paragraph.childNodes.length) fragment.append(paragraph); transcript.append(fragment);
  renderSpanList(goldenList, data.goldenSpans, "Golden"); renderSpanList(geminiList, data.geminiSpans, "Gemini");
}

async function loadEpisode(slug) { renderEpisode(await api(`/api/gemini/${encodeURIComponent(slug)}`)); }
async function main() {
  try {
    const { episodes } = await api("/api/gemini/episodes");
    episodes.forEach((episode) => { const option = document.createElement("option"); option.value = episode.slug; option.textContent = `${episode.showName} — R ${percent(episode.recall)}`; select.append(option); });
    select.addEventListener("change", () => loadEpisode(select.value));
    previousDelta.addEventListener("click", () => moveDelta(-1));
    nextDelta.addEventListener("click", () => moveDelta(1));
    if (episodes.length) await loadEpisode(episodes[0].slug); else subtitle.textContent = "No completed Gemini experiment results found.";
  } catch (error) { subtitle.textContent = error.message; }
}
main();
