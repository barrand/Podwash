"use strict";

const CATEGORY_NAMES = {
  paid_ad: "Paid ad",
  underwriting: "Underwriting",
  cross_show_promo: "Other-show promo",
  publisher_promo: "Publisher promo",
  membership_appeal: "Membership appeal",
  engagement_request: "Follow request",
  production_credit: "Production credit",
  network_id: "Network ID",
  signoff: "Sign-off",
};

const episodes = document.getElementById("episodes");
const audit = document.getElementById("audit");
const transcript = document.getElementById("transcript");

async function api(path) {
  const response = await fetch(path);
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error || "Could not load audit");
  return payload;
}

function setPage(page) {
  episodes.classList.toggle("hidden", page === "audit");
  audit.classList.toggle("hidden", page !== "audit");
}

async function loadList() {
  const payload = await api("/api/typed-audits");
  episodes.textContent = "";
  for (const item of payload.audits || []) {
    const card = document.createElement("button");
    card.className = "episode";
    card.type = "button";
    card.innerHTML = `<span>${escapeHtml(item.showName)}</span><strong>${escapeHtml(item.title)}</strong><small>${item.spanCount} typed spans · current golden shown underneath</small>`;
    card.addEventListener("click", () => openAudit(item.slug));
    episodes.append(card);
  }
  if (!episodes.childElementCount) episodes.textContent = "No typed-policy audits are prepared yet.";
}

function escapeHtml(value) {
  return String(value || "").replace(/[&<>\"]/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[char]));
}

function spanMap(spans, field) {
  const map = new Map();
  for (const span of spans) {
    for (let index = span.startWord; index < span.endWord; index += 1) map.set(index, span[field]);
  }
  return map;
}

async function openAudit(slug) {
  const payload = await api(`/api/typed-audits/${encodeURIComponent(slug)}`);
  document.getElementById("show").textContent = payload.showName;
  document.getElementById("title").textContent = payload.title;
  const firstPass = payload.audit.spans || [];
  const baseline = payload.baselineSpans || [];
  const jevSpans = payload.jevSpans || [];
  const jevVersion = jevSpans[0]?.version || "v6";
  document.getElementById("summary").textContent = `${firstPass.length} first-pass typed spans and ${jevSpans.length} Jev ${jevVersion} detections. Colored background is the proposed customer-setting category; amber underline is the current approved ads-only golden; green underline and Jev badge are model detections.`;
  const findings = document.getElementById("findings");
  findings.textContent = "";
  for (const finding of payload.audit.findings || []) {
    const note = document.createElement("p");
    note.textContent = finding;
    findings.append(note);
  }
  const typedAt = spanMap(firstPass, "category");
  const goldenAt = spanMap(baseline, "id");
  const jevAt = spanMap(jevSpans, "id");
  transcript.textContent = "";
  const fragment = document.createDocumentFragment();
  let paragraph = document.createElement("p");
  let paragraphStart = 0;
  payload.words.forEach((word, index) => {
    const element = document.createElement("span");
    element.className = "word";
    const category = typedAt.get(index);
    if (category) element.classList.add(category);
    if (goldenAt.has(index)) element.classList.add("in-golden");
    if (jevAt.has(index)) element.classList.add("jev-detected");
    const firstWord = firstPass.find((span) => span.startWord === index);
    if (firstWord) {
      const label = document.createElement("b");
      label.className = "chip";
      label.textContent = CATEGORY_NAMES[firstWord.category] || firstWord.category;
      element.append(label);
    }
    const jevStart = jevSpans.find((span) => span.startWord === index);
    if (jevStart) {
      const label = document.createElement("b");
      label.className = "jev-chip";
      const reasons = (jevStart.reasons || []).map((reason) => CATEGORY_NAMES[reason] || reason);
      label.textContent = reasons.length ? `Jev ${jevStart.version}: ${reasons.join(" + ")}` : `Jev ${jevStart.version}`;
      element.append(label);
    }
    element.append(document.createTextNode(word.word));
    paragraph.append(element, document.createTextNode(" "));
    const sentenceEnd = /[.!?]["')\]]?$/.test(String(word.word || "").trim());
    const paragraphLength = index - paragraphStart + 1;
    if ((sentenceEnd && paragraphLength >= 38) || paragraphLength >= 110) {
      fragment.append(paragraph);
      paragraph = document.createElement("p");
      paragraphStart = index + 1;
    }
  });
  if (paragraph.childNodes.length) fragment.append(paragraph);
  transcript.append(fragment);
  setPage("audit");
  window.scrollTo({ top: 0, behavior: "instant" });
}

document.getElementById("back").addEventListener("click", () => setPage("list"));
loadList().catch((error) => { episodes.textContent = error.message; });
