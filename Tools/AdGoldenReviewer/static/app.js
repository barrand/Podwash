"use strict";

const LABELS = {
  paid_dai: { name: "Paid DAI", short: "DAI" },
  paid_baked_in: { name: "Paid baked-in", short: "Baked-in" },
  paid_host_read: { name: "Paid host-read", short: "Host-read" },
  network_promo: { name: "Network promo", short: "Promo" },
  membership_cta: { name: "Membership CTA", short: "Membership" },
};

const state = {
  episode: null,
  words: [],
  proposal: null,
  review: null,
  spans: [],
  wordElements: [],
  spanAtWord: [],
  selection: null,
  activeSpanId: null,
  cursorWord: null,
  dragging: null,
  boundaryDragging: null,
  undoStack: [],
  redoStack: [],
  saveTimer: null,
  saving: false,
  dirty: false,
  savePromise: Promise.resolve(),
  scrollTimer: null,
  toastTimer: null,
  idCounter: 1,
};

const loading = document.getElementById("loading");
const dashboard = document.getElementById("dashboard");
const reviewer = document.getElementById("reviewer");
const episodeCards = document.getElementById("episodeCards");
const dashboardSummary = document.getElementById("dashboardSummary");
const transcript = document.getElementById("transcript");
const floatingPalette = document.getElementById("floatingPalette");
const saveStatus = document.getElementById("saveStatus");
const selectionStatus = document.getElementById("selectionStatus");
const activeEditor = document.getElementById("activeEditor");
const activeOrigin = document.getElementById("activeOrigin");
const advertiserInput = document.getElementById("advertiserInput");
const noteInput = document.getElementById("noteInput");
const progressFill = document.getElementById("progressFill");
const progressFraction = document.getElementById("progressFraction");
const reviewPercent = document.getElementById("reviewPercent");
const auditList = document.getElementById("auditList");
const auditCount = document.getElementById("auditCount");
const attestationCheckbox = document.getElementById("attestationCheckbox");
const approveButton = document.getElementById("approveButton");
const approvalHelp = document.getElementById("approvalHelp");
const reviewMarker = document.getElementById("reviewMarker");
const toast = document.getElementById("toast");

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function showToast(message) {
  toast.textContent = message;
  toast.classList.remove("hidden");
  clearTimeout(state.toastTimer);
  state.toastTimer = setTimeout(() => toast.classList.add("hidden"), 3200);
}

function setSaveStatus(kind, text) {
  saveStatus.className = `save-status ${kind}`;
  saveStatus.textContent = text;
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: options.body ? { "Content-Type": "application/json" } : undefined,
    ...options,
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = new Error(payload.error || `${response.status} ${response.statusText}`);
    error.status = response.status;
    throw error;
  }
  return payload;
}

async function loadDashboard() {
  const payload = await api("/api/episodes");
  const episodes = payload.episodes || [];
  const approvedCount = episodes.filter((episode) => episode.goldenExists || episode.status === "approved").length;
  const transcriptCount = episodes.filter((episode) => episode.transcriptReady).length;
  dashboardSummary.textContent = "";
  const approvedStat = document.createElement("div");
  approvedStat.className = "summary-stat";
  approvedStat.innerHTML = `<strong>${approvedCount}/${episodes.length}</strong><span>goldens saved</span>`;
  const transcriptStat = document.createElement("div");
  transcriptStat.className = "summary-stat";
  transcriptStat.innerHTML = `<strong>${transcriptCount}/${episodes.length}</strong><span>transcripts ready</span>`;
  dashboardSummary.append(approvedStat, transcriptStat);

  episodeCards.textContent = "";
  for (const episode of episodes) {
    const approved = episode.goldenExists || episode.status === "approved";
    const card = document.createElement("article");
    card.className = `episode-card${approved ? " approved" : ""}`;
    const check = document.createElement("div");
    check.className = `golden-check${approved ? " checked" : ""}`;
    check.setAttribute("aria-label", approved ? "Golden saved" : "Golden not saved");
    check.textContent = approved ? "✓" : "";
    const copy = document.createElement("div");
    copy.className = "episode-copy";
    const show = document.createElement("p");
    show.className = "episode-show";
    show.textContent = episode.showName || episode.slug;
    const title = document.createElement("h2");
    title.textContent = episode.title;
    const detail = document.createElement("p");
    const percent = Math.round((episode.progress || 0) * 100);
    const readiness = [
      `${humanStatus(episode.status)} · ${percent}% reviewed`,
      episode.transcriptReady ? `${Number(episode.wordCount || 0).toLocaleString()} words` : "needs transcript",
      episode.proposalReady ? "AI pass ready" : "needs AI pass",
    ];
    detail.textContent = readiness.join(" · ");
    copy.append(show, title, detail);
    const button = document.createElement("button");
    button.type = "button";
    button.className = "primary-button";
    button.textContent = dashboardButtonText(episode);
    button.disabled = !dashboardEpisodeCanOpen(episode);
    button.addEventListener("click", () => openEpisode(episode.slug));
    card.append(check, copy, button);
    episodeCards.append(card);
  }
  floatingPalette.classList.add("hidden");
  loading.classList.add("hidden");
  reviewer.classList.add("hidden");
  dashboard.classList.remove("hidden");
}

function dashboardButtonText(episode) {
  if (episode.status === "transcript_missing") return "Need transcript";
  if (episode.goldenExists || episode.status === "approved") return "View / edit golden";
  if (!episode.proposalReady && !episode.reviewExists) return "Need AI pass";
  if (episode.status === "not_started") return "Start review";
  return "Continue review";
}

function dashboardEpisodeCanOpen(episode) {
  if (episode.status === "transcript_missing") return false;
  if (episode.goldenExists || episode.status === "approved") return true;
  return Boolean(episode.proposalReady || episode.reviewExists);
}

function humanStatus(status) {
  return {
    transcript_missing: "Transcript not ready",
    not_started: "Ready",
    in_review: "In review",
    approved: "Approved",
  }[status] || status;
}

async function openEpisode(slug) {
  loading.textContent = "Opening the complete transcript…";
  loading.classList.remove("hidden");
  dashboard.classList.add("hidden");
  try {
    const episode = await api(`/api/episodes/${encodeURIComponent(slug)}`);
    state.episode = episode;
    state.words = episode.words;
    state.proposal = episode.proposal;
    state.review = episode.review;
    state.spans = clone(episode.review.spans || []);
    state.activeSpanId = null;
    state.selection = null;
    state.cursorWord = null;
    state.undoStack = [];
    state.redoStack = [];
    state.idCounter = nextIdCounter();
    document.getElementById("showName").textContent = episode.showName;
    document.getElementById("episodeTitle").textContent = episode.title;
    approveButton.textContent = `Approve ${episode.showName} golden`;
    attestationCheckbox.checked = Boolean(state.review.attested);
    buildTranscript();
    renderAll();
    loading.classList.add("hidden");
    reviewer.classList.remove("hidden");
    const resume = Number(state.review.resumeWord || state.review.reviewedThroughWord || 0);
    requestAnimationFrame(() => scrollToWord(resume, false));
  } catch (error) {
    loading.classList.add("hidden");
    dashboard.classList.remove("hidden");
    showToast(error.message);
  }
}

function nextIdCounter() {
  let max = 0;
  for (const span of state.spans) {
    const match = String(span.id).match(/(\d+)$/);
    if (match) max = Math.max(max, Number(match[1]));
  }
  return max + 1;
}

function newSpanId(prefix = "human") {
  return `${prefix}-${state.idCounter++}`;
}

function buildTranscript() {
  transcript.textContent = "";
  state.wordElements = new Array(state.words.length);
  const fragment = document.createDocumentFragment();
  let paragraph = document.createElement("p");
  paragraph.className = "paragraph";
  let paragraphStart = 0;

  state.words.forEach((word, index) => {
    const element = document.createElement("span");
    element.className = "word";
    element.dataset.index = String(index);
    element.textContent = word.word;
    state.wordElements[index] = element;
    paragraph.append(element, document.createTextNode(" "));

    const token = String(word.word || "").trim();
    const sentenceEnd = /[.!?]["')\]]?$/.test(token);
    const paragraphLength = index - paragraphStart + 1;
    if ((sentenceEnd && paragraphLength >= 38) || paragraphLength >= 110) {
      fragment.append(paragraph);
      paragraph = document.createElement("p");
      paragraph.className = "paragraph";
      paragraphStart = index + 1;
    }
  });
  if (paragraph.childNodes.length) fragment.append(paragraph);
  transcript.append(fragment);
}

function sortedSpans() {
  return [...state.spans].sort(
    (left, right) => left.startWord - right.startWord || left.endWord - right.endWord,
  );
}

function renderAll() {
  renderAnnotations();
  renderSelection();
  renderEditor();
  renderProgress();
  renderAudit();
  renderApproval();
}

function renderAnnotations() {
  state.spanAtWord = new Array(state.words.length).fill(null);
  for (const element of state.wordElements) {
    element.className = "word";
    element.removeAttribute("data-chip");
    element.querySelectorAll(".boundary-handle").forEach((handle) => handle.remove());
  }

  for (const span of sortedSpans()) {
    for (let index = span.startWord; index < span.endWord; index += 1) {
      const element = state.wordElements[index];
      if (!element) continue;
      state.spanAtWord[index] = span.id;
      element.classList.add(`label-${span.label}`);
      element.classList.add(span.origin === "ai-proposal" ? "ai-proposal" : "human-span");
    }
    const startElement = state.wordElements[span.startWord];
    if (startElement) {
      startElement.classList.add("span-start");
      startElement.dataset.chip = LABELS[span.label]?.short || span.label;
    }
  }

  const active = activeSpan();
  if (active) {
    for (let index = active.startWord; index < active.endWord; index += 1) {
      state.wordElements[index]?.classList.add("active-span");
    }
    addBoundaryHandle(active, "start", active.startWord);
    addBoundaryHandle(active, "end", active.endWord - 1);
  }
}

function addBoundaryHandle(span, edge, wordIndex) {
  const element = state.wordElements[wordIndex];
  if (!element) return;
  const handle = document.createElement("button");
  handle.type = "button";
  handle.className = `boundary-handle ${edge}`;
  handle.setAttribute("aria-label", `Drag ${edge} boundary`);
  handle.addEventListener("pointerdown", (event) => startBoundaryDrag(event, span.id, edge));
  element.append(handle);
}

function activeSpan() {
  return state.spans.find((span) => span.id === state.activeSpanId) || null;
}

function renderSelection() {
  for (const element of state.wordElements) {
    element.classList.remove("range-selected");
  }
  if (!state.selection) {
    selectionStatus.textContent = activeSpan()
      ? "Span selected. Drag a handle or choose another label."
      : "Drag across words to select a range.";
    floatingPalette.classList.add("hidden");
    return;
  }
  const [start, end] = normalizedSelection();
  for (let index = start; index < end; index += 1) {
    state.wordElements[index]?.classList.add("range-selected");
  }
  selectionStatus.textContent = `${end - start} word${end - start === 1 ? "" : "s"} selected`;
}

function normalizedSelection() {
  if (!state.selection) return [0, 0];
  return [
    Math.min(state.selection.anchor, state.selection.focus),
    Math.max(state.selection.anchor, state.selection.focus) + 1,
  ];
}

function setSelection(anchor, focus = anchor, floatingPoint = null) {
  const previous = state.selection ? normalizedSelection() : null;
  state.selection = { anchor, focus };
  if (previous) {
    for (let index = previous[0]; index < previous[1]; index += 1) {
      state.wordElements[index]?.classList.remove("range-selected");
    }
  }
  const [start, end] = normalizedSelection();
  for (let index = start; index < end; index += 1) {
    state.wordElements[index]?.classList.add("range-selected");
  }
  selectionStatus.textContent = `${end - start} word${end - start === 1 ? "" : "s"} selected`;
  state.cursorWord = focus;
  if (floatingPoint) showFloatingPalette(floatingPoint.x, floatingPoint.y);
}

function clearSelection() {
  if (state.selection) {
    const [start, end] = normalizedSelection();
    for (let index = start; index < end; index += 1) {
      state.wordElements[index]?.classList.remove("range-selected");
    }
  }
  state.selection = null;
  floatingPalette.classList.add("hidden");
  selectionStatus.textContent = activeSpan()
    ? "Span selected. Drag a handle or choose another label."
    : "Drag across words to select a range.";
}

function showFloatingPalette(x, y) {
  floatingPalette.classList.remove("hidden");
  const width = 260;
  const height = 50;
  floatingPalette.style.left = `${Math.max(8, Math.min(window.innerWidth - width - 8, x - width / 2))}px`;
  floatingPalette.style.top = `${Math.max(82, Math.min(window.innerHeight - height - 8, y + 12))}px`;
}

function renderEditor() {
  const span = activeSpan();
  if (!span) {
    activeEditor.classList.add("hidden");
    return;
  }
  activeEditor.classList.remove("hidden");
  activeOrigin.textContent = span.origin === "ai-proposal" ? "AI proposal" : "Human edited";
  if (document.activeElement !== advertiserInput) advertiserInput.value = span.advertiser || "";
  if (document.activeElement !== noteInput) noteInput.value = span.note || "";
}

function renderProgress() {
  const reviewed = Math.min(state.words.length, Number(state.review.reviewedThroughWord || 0));
  const percent = state.words.length ? reviewed / state.words.length : 0;
  progressFill.style.width = `${(percent * 100).toFixed(1)}%`;
  progressFraction.textContent = `${reviewed.toLocaleString()} / ${state.words.length.toLocaleString()}`;
  reviewPercent.textContent = `${Math.round(percent * 100)}% reviewed`;
  positionReviewMarker(reviewed);
}

function positionReviewMarker(reviewed) {
  if (reviewed <= 0 || reviewed >= state.words.length) {
    reviewMarker.classList.add("hidden");
    return;
  }
  const element = state.wordElements[reviewed - 1];
  if (!element) return;
  const rect = element.getBoundingClientRect();
  reviewMarker.style.top = `${window.scrollY + rect.bottom + 5}px`;
  reviewMarker.classList.remove("hidden");
}

function auditItems() {
  return state.proposal?.auditItems || [];
}

function renderAudit() {
  const items = auditItems();
  auditCount.textContent = `${items.length}`;
  auditList.textContent = "";
  if (!items.length) {
    const empty = document.createElement("p");
    empty.className = "muted";
    empty.textContent = "No model review notes.";
    auditList.append(empty);
    return;
  }

  for (const item of items) {
    const card = document.createElement("div");
    card.className = "audit-item";
    card.tabIndex = 0;
    card.setAttribute("role", "button");
    card.setAttribute("aria-label", "Jump to model note");
    const jumpToItem = () => {
      setSelection(Number(item.startWord), Math.max(Number(item.startWord), Number(item.endWord) - 1));
      scrollToWord(Number(item.startWord), true);
    };
    card.addEventListener("click", jumpToItem);
    card.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        jumpToItem();
      }
    });
    const reason = document.createElement("p");
    reason.textContent = item.reason || "Review this possible missed ad.";
    card.append(reason);
    auditList.append(card);
  }
}

function approvalProblems() {
  const problems = [];
  if (Number(state.review.reviewedThroughWord || 0) !== state.words.length) {
    problems.push("finish the transcript");
  }
  if (!state.review.attested) problems.push("check the final attestation");
  return problems;
}

function renderApproval() {
  const problems = approvalProblems();
  approveButton.disabled = Boolean(problems.length) || state.review.status === "approved";
  approvalHelp.textContent = state.review.status === "approved"
    ? "This golden is human-approved."
    : problems.length
      ? `Before approval: ${problems.join(", ")}.`
      : "Ready to write the tracked human-approved golden.";
}

function snapshot() {
  return {
    spans: clone(state.spans),
    reviewedThroughWord: Number(state.review.reviewedThroughWord || 0),
    auditDecisions: clone(state.review.auditDecisions || {}),
    attested: Boolean(state.review.attested),
  };
}

function pushHistory() {
  state.undoStack.push(snapshot());
  if (state.undoStack.length > 100) state.undoStack.shift();
  state.redoStack = [];
}

function restoreSnapshot(saved) {
  state.spans = clone(saved.spans);
  state.review.reviewedThroughWord = saved.reviewedThroughWord;
  state.review.auditDecisions = clone(saved.auditDecisions);
  state.review.attested = saved.attested;
  attestationCheckbox.checked = saved.attested;
  state.activeSpanId = null;
  clearSelection();
  renderAll();
  scheduleSave();
}

function undo() {
  if (!state.undoStack.length) return;
  state.redoStack.push(snapshot());
  restoreSnapshot(state.undoStack.pop());
}

function redo() {
  if (!state.redoStack.length) return;
  state.undoStack.push(snapshot());
  restoreSnapshot(state.redoStack.pop());
}

function paintSelection(label) {
  if (!state.selection) {
    const span = activeSpan();
    if (!span) {
      showToast("Select words or an existing span first.");
      return;
    }
    if (label === "content") {
      deleteActive();
      return;
    }
    pushHistory();
    span.label = label;
    span.origin = "human-edited";
    renderAll();
    scheduleSave();
    return;
  }
  const [start, end] = normalizedSelection();
  paintRange(start, end, label);
}

function paintRange(start, end, label) {
  pushHistory();
  const next = [];
  for (const span of state.spans) {
    if (span.endWord <= start || span.startWord >= end) {
      next.push(span);
      continue;
    }
    if (span.startWord < start) {
      next.push({
        ...span,
        id: newSpanId("split"),
        endWord: start,
        origin: "human-edited",
      });
    }
    if (span.endWord > end) {
      next.push({
        ...span,
        id: newSpanId("split"),
        startWord: end,
        origin: "human-edited",
      });
    }
  }
  let created = null;
  if (label !== "content") {
    created = {
      id: newSpanId(),
      startWord: start,
      endWord: end,
      label,
      advertiser: "",
      note: "",
      origin: "human-added",
      proposalId: null,
    };
    next.push(created);
  }
  state.spans = next.sort((left, right) => left.startWord - right.startWord);
  state.activeSpanId = created?.id || null;
  clearSelection();
  renderAll();
  scheduleSave();
}

function deleteActive() {
  const span = activeSpan();
  if (!span) return;
  pushHistory();
  state.spans = state.spans.filter((candidate) => candidate.id !== span.id);
  state.activeSpanId = null;
  clearSelection();
  renderAll();
  scheduleSave();
}

function splitActive() {
  const span = activeSpan();
  if (!span) return;
  const splitAt = state.cursorWord ?? (state.selection ? normalizedSelection()[0] : null);
  if (splitAt === null || splitAt <= span.startWord || splitAt >= span.endWord) {
    showToast("Click a word inside the selected span, then split.");
    return;
  }
  pushHistory();
  const left = { ...span, endWord: splitAt, origin: "human-edited" };
  const right = {
    ...span,
    id: newSpanId("split"),
    startWord: splitAt,
    origin: "human-edited",
  };
  state.spans = state.spans.filter((candidate) => candidate.id !== span.id);
  state.spans.push(left, right);
  state.spans.sort((a, b) => a.startWord - b.startWord);
  state.activeSpanId = right.id;
  renderAll();
  scheduleSave();
}

function mergeNext() {
  const spans = sortedSpans();
  const index = spans.findIndex((span) => span.id === state.activeSpanId);
  if (index < 0 || index + 1 >= spans.length) {
    showToast("There is no following span to merge.");
    return;
  }
  const left = spans[index];
  const right = spans[index + 1];
  if (left.endWord !== right.startWord) {
    showToast("Only directly adjacent spans can merge; content is never swallowed.");
    return;
  }
  pushHistory();
  left.endWord = right.endWord;
  left.origin = "human-edited";
  state.spans = state.spans.filter((span) => span.id !== right.id);
  renderAll();
  scheduleSave();
}

function nudge(edge, delta) {
  const span = activeSpan();
  if (!span) return;
  let start = span.startWord;
  let end = span.endWord;
  if (edge === "start") start = Math.max(0, Math.min(end - 1, start + delta));
  else end = Math.min(state.words.length, Math.max(start + 1, end + delta));
  const clamped = clampRangeAgainstOtherSpans(span.id, start, end);
  if (clamped.start === span.startWord && clamped.end === span.endWord) return;
  pushHistory();
  span.startWord = clamped.start;
  span.endWord = clamped.end;
  span.origin = "human-edited";
  renderAll();
  scheduleSave();
}

function clampRangeAgainstOtherSpans(spanId, start, end) {
  let clampedStart = start;
  let clampedEnd = end;
  for (const other of sortedSpans()) {
    if (other.id === spanId) continue;
    if (other.endWord <= clampedStart || other.startWord >= clampedEnd) continue;
    const active = state.spans.find((span) => span.id === spanId);
    if (active && other.endWord <= active.startWord) clampedStart = other.endWord;
    else if (active && other.startWord >= active.endWord) clampedEnd = other.startWord;
    else {
      clampedStart = active?.startWord ?? clampedStart;
      clampedEnd = active?.endWord ?? clampedEnd;
    }
  }
  return { start: clampedStart, end: clampedEnd };
}

function startBoundaryDrag(event, spanId, edge) {
  event.preventDefault();
  event.stopPropagation();
  const span = state.spans.find((candidate) => candidate.id === spanId);
  if (!span) return;
  state.boundaryDragging = {
    spanId,
    edge,
    originalStart: span.startWord,
    originalEnd: span.endWord,
    previewStart: span.startWord,
    previewEnd: span.endWord,
  };
  setSelection(span.startWord, span.endWord - 1);
}

function updateBoundaryDrag(wordIndex) {
  const drag = state.boundaryDragging;
  if (!drag) return;
  let start = drag.originalStart;
  let end = drag.originalEnd;
  if (drag.edge === "start") start = Math.min(wordIndex, end - 1);
  else end = Math.max(start + 1, wordIndex + 1);
  start = Math.max(0, start);
  end = Math.min(state.words.length, end);
  const clamped = clampRangeAgainstOtherSpans(drag.spanId, start, end);
  drag.previewStart = clamped.start;
  drag.previewEnd = clamped.end;
  setSelection(clamped.start, clamped.end - 1);
}

function finishBoundaryDrag() {
  const drag = state.boundaryDragging;
  if (!drag) return;
  const span = state.spans.find((candidate) => candidate.id === drag.spanId);
  state.boundaryDragging = null;
  if (!span) return;
  if (span.startWord !== drag.previewStart || span.endWord !== drag.previewEnd) {
    pushHistory();
    span.startWord = drag.previewStart;
    span.endWord = drag.previewEnd;
    span.origin = "human-edited";
    clearSelection();
    renderAll();
    scheduleSave();
  } else {
    clearSelection();
    renderAll();
  }
}

function wordFromPoint(x, y) {
  const element = document.elementFromPoint(x, y);
  const word = element?.closest?.(".word");
  if (!word) return null;
  const index = Number(word.dataset.index);
  return Number.isInteger(index) ? index : null;
}

function handleTranscriptPointerDown(event) {
  if (event.button !== 0 || event.target.closest(".boundary-handle")) return;
  const word = event.target.closest(".word");
  if (!word) return;
  event.preventDefault();
  const index = Number(word.dataset.index);
  state.cursorWord = index;
  floatingPalette.classList.add("hidden");
  if (event.shiftKey && state.selection) {
    setSelection(state.selection.anchor, index, { x: event.clientX, y: event.clientY });
    return;
  }
  state.dragging = {
    anchor: index,
    focus: index,
    moved: false,
    x: event.clientX,
    y: event.clientY,
  };
  setSelection(index, index);
}

function handleDocumentPointerMove(event) {
  const index = wordFromPoint(event.clientX, event.clientY);
  if (index === null) return;
  if (state.boundaryDragging) {
    updateBoundaryDrag(index);
    return;
  }
  if (!state.dragging) return;
  if (index !== state.dragging.anchor) state.dragging.moved = true;
  state.dragging.focus = index;
  state.dragging.x = event.clientX;
  state.dragging.y = event.clientY;
  setSelection(state.dragging.anchor, index);
}

function handleDocumentPointerUp(event) {
  if (state.boundaryDragging) {
    finishBoundaryDrag();
    return;
  }
  const drag = state.dragging;
  state.dragging = null;
  if (!drag) return;
  if (!drag.moved) {
    const coveringId = state.spanAtWord[drag.anchor];
    if (coveringId) {
      state.activeSpanId = coveringId;
      clearSelection();
      renderAll();
      return;
    }
  }
  setSelection(drag.anchor, drag.focus, { x: event.clientX, y: event.clientY });
}

function reviewPayload() {
  return {
    revision: Number(state.review.revision || 0),
    reviewedThroughWord: Number(state.review.reviewedThroughWord || 0),
    resumeWord: Number(state.review.resumeWord || 0),
    spans: state.spans,
    auditDecisions: state.review.auditDecisions || {},
    attested: Boolean(state.review.attested),
    reviewer: state.review.reviewer || "Brian",
  };
}

function scheduleSave() {
  state.dirty = true;
  setSaveStatus("saving", "Unsaved");
  clearTimeout(state.saveTimer);
  state.saveTimer = setTimeout(() => {
    state.savePromise = flushSave();
  }, 320);
}

async function flushSave() {
  clearTimeout(state.saveTimer);
  if (state.saving || !state.dirty || !state.episode) return state.savePromise;
  state.saving = true;
  state.dirty = false;
  let succeeded = false;
  setSaveStatus("saving", "Saving…");
  try {
    const previousStatus = state.review.status;
    const payload = await api(`/api/episodes/${encodeURIComponent(state.episode.slug)}/review`, {
      method: "PUT",
      body: JSON.stringify(reviewPayload()),
    });
    state.review = { ...state.review, ...payload.review, spans: state.spans };
    if (previousStatus === "approved" && payload.review.status !== "approved") {
      showToast("This edit reopened the golden; approve it again when finished.");
    }
    succeeded = true;
    setSaveStatus("saved", "Saved");
    renderApproval();
  } catch (error) {
    state.dirty = true;
    setSaveStatus("error", error.status === 409 ? "Conflict" : "Save failed");
    showToast(error.status === 409 ? "Another tab changed this review. Reload before continuing." : error.message);
  } finally {
    state.saving = false;
  }
  if (succeeded && state.dirty) {
    state.savePromise = flushSave();
    return state.savePromise;
  }
  return succeeded;
}

function markReviewedThroughSelection() {
  let through = state.cursorWord !== null ? state.cursorWord + 1 : Number(state.review.resumeWord || 0) + 1;
  if (state.selection) through = normalizedSelection()[1];
  pushHistory();
  state.review.reviewedThroughWord = Math.max(
    Number(state.review.reviewedThroughWord || 0),
    Math.min(state.words.length, through),
  );
  renderProgress();
  renderApproval();
  scheduleSave();
}

function markReviewedToEnd() {
  pushHistory();
  state.review.reviewedThroughWord = state.words.length;
  renderProgress();
  renderApproval();
  scheduleSave();
}

function scrollToWord(index, smooth = true) {
  const safeIndex = Math.max(0, Math.min(state.words.length - 1, Number(index) || 0));
  const element = state.wordElements[safeIndex];
  if (!element) return;
  element.scrollIntoView({ behavior: smooth ? "smooth" : "auto", block: "center" });
  state.cursorWord = safeIndex;
  state.review.resumeWord = safeIndex;
}

function updateResumeFromViewport() {
  const elements = document.elementsFromPoint(100, Math.min(window.innerHeight - 20, 120));
  const word = elements.find((element) => element.classList?.contains("word"));
  if (!word) return;
  const index = Number(word.dataset.index);
  if (!Number.isInteger(index) || state.review.resumeWord === index) return;
  state.review.resumeWord = index;
  scheduleSave();
}

async function approveGolden() {
  if (approvalProblems().length) return;
  approveButton.disabled = true;
  setSaveStatus("saving", "Finalizing…");
  try {
    if (state.dirty || state.saving) {
      state.savePromise = flushSave();
      const saved = await state.savePromise;
      if (!saved) return;
    }
    const payload = await api(`/api/episodes/${encodeURIComponent(state.episode.slug)}/approve`, {
      method: "POST",
      body: JSON.stringify(reviewPayload()),
    });
    state.review = payload.review;
    state.spans = clone(payload.review.spans);
    setSaveStatus("saved", "Golden approved");
    renderAll();
    const showName = state.episode?.showName || state.episode?.title || "Episode";
    const git = payload.git || {};
    const gitMessage = git.attempted
      ? (git.success ? " Committed and pushed." : ` Git still needs attention: ${git.message}`)
      : "";
    showToast(`${showName} golden saved and human-approved.${gitMessage}`);
  } catch (error) {
    setSaveStatus("error", "Approval failed");
    showToast(error.message);
    renderApproval();
  }
}

function updateActiveField(field, value) {
  const span = activeSpan();
  if (!span || span[field] === value) return;
  pushHistory();
  span[field] = value;
  span.origin = "human-edited";
  renderAnnotations();
  renderEditor();
  scheduleSave();
}

function toggleHighlights() {
  document.body.classList.toggle("hide-highlights");
  document.getElementById("hideHighlightsButton").textContent =
    document.body.classList.contains("hide-highlights") ? "Show labels" : "Hide labels";
}

function handleKeydown(event) {
  if (!state.episode) return;
  const typing = ["INPUT", "TEXTAREA"].includes(document.activeElement?.tagName);
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "z") {
    event.preventDefault();
    if (event.shiftKey) redo();
    else undo();
    return;
  }
  if (typing) return;
  const labelsByKey = {
    "1": "paid_dai",
    "2": "paid_baked_in",
    "3": "paid_host_read",
    "4": "network_promo",
    "5": "membership_cta",
    "0": "content",
  };
  if (labelsByKey[event.key]) {
    event.preventDefault();
    paintSelection(labelsByKey[event.key]);
  } else if (event.key === "Backspace" || event.key === "Delete") {
    event.preventDefault();
    deleteActive();
  } else if (event.key.toLowerCase() === "h") {
    event.preventDefault();
    toggleHighlights();
  }
}

function bindEvents() {
  transcript.addEventListener("pointerdown", handleTranscriptPointerDown);
  document.addEventListener("pointermove", handleDocumentPointerMove);
  document.addEventListener("pointerup", handleDocumentPointerUp);
  document.addEventListener("keydown", handleKeydown);
  window.addEventListener("resize", () => renderProgress());
  window.addEventListener("scroll", () => {
    clearTimeout(state.scrollTimer);
    state.scrollTimer = setTimeout(() => {
      updateResumeFromViewport();
      renderProgress();
    }, 500);
  }, { passive: true });

  document.querySelectorAll("[data-label]").forEach((button) => {
    button.addEventListener("click", () => paintSelection(button.dataset.label));
  });
  document.getElementById("backButton").addEventListener("click", async () => {
    if (state.dirty || state.saving) {
      state.savePromise = flushSave();
      const saved = await state.savePromise;
      if (!saved) return;
    }
    state.episode = null;
    reviewer.classList.add("hidden");
    loadDashboard().catch((error) => showToast(error.message));
  });
  document.getElementById("continueButton").addEventListener("click", () => {
    scrollToWord(state.review.resumeWord || state.review.reviewedThroughWord || 0, true);
  });
  document.getElementById("hideHighlightsButton").addEventListener("click", toggleHighlights);
  advertiserInput.addEventListener("change", () => updateActiveField("advertiser", advertiserInput.value.trim()));
  noteInput.addEventListener("change", () => updateActiveField("note", noteInput.value.trim()));
  document.getElementById("startLeftButton").addEventListener("click", () => nudge("start", -1));
  document.getElementById("startRightButton").addEventListener("click", () => nudge("start", 1));
  document.getElementById("endLeftButton").addEventListener("click", () => nudge("end", -1));
  document.getElementById("endRightButton").addEventListener("click", () => nudge("end", 1));
  document.getElementById("splitButton").addEventListener("click", splitActive);
  document.getElementById("mergeButton").addEventListener("click", mergeNext);
  document.getElementById("deleteButton").addEventListener("click", deleteActive);
  document.getElementById("markReviewedButton").addEventListener("click", markReviewedThroughSelection);
  document.getElementById("markEndButton").addEventListener("click", markReviewedToEnd);
  attestationCheckbox.addEventListener("change", () => {
    pushHistory();
    state.review.attested = attestationCheckbox.checked;
    renderApproval();
    scheduleSave();
  });
  approveButton.addEventListener("click", approveGolden);
}

bindEvents();
loadDashboard().catch((error) => {
  loading.textContent = `Could not load reviewer: ${error.message}`;
});
