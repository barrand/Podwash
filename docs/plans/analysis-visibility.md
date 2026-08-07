# Analysis visibility

## Goal

Podcast preparation must never feel like a black box. When PodWash downloads and
analyzes an episode, listeners should be able to tell what is happening, whether
the episode is ready for clean playback, and what is delaying it.

## Listener experience

- The mini-player shows a compact **Preparing Up Next** shelf after playback
  begins. It shows only the first three current preparation candidates and opens
  a detailed preparation view. Its count is `ready / visible candidates`; the
  five-item warm-cache cap is not presented as a listener-facing queue.
- The detail view uses plain-language states: **Waiting to prepare**,
  **Downloading**, **Preparing clean playback**, **Checking for ads**,
  **Ready**, **Ad check delayed**, and **Needs attention**. It retains manual Up
  Next order and labels smart predictions as such.
- Progress is specific when it can be measured: download percentage and local
  transcription percentage. Transcription time remaining appears only when a
  measured throughput estimate is stable; otherwise it shows percentage only.
  Cloud ad detection shows its current state, elapsed time, and next retry time
  instead of an unreliable countdown.
- Manual Up Next episodes are prepared first; smart-autoplay predictions fill
  unused preparation slots. The first three unique candidates are eligible for
  active preparation; manual items always precede predictions.

## Preparation coordinator

- Preparation is a single, owned serial worker, not a collection of detached
  tasks. A job is keyed by episode ID and owns its download, local analysis, and
  cloud-ad-detection work.
- Re-aiming the queue cancels work that is no longer eligible, awaits its
  cancellation boundary, and then starts the new highest-priority job. An
  in-flight network request may finish after cancellation, but its result must
  not change queue state or start playback unless the episode is still eligible.
- Requests for an episode already downloading or analyzing attach to that job;
  they never start duplicate work. Playback preparation and background warming
  share this coordinator.
- The currently playing episode and background-prepared episodes use the same
  job state machine. Foreground playback exposes **Preparing clean playback**,
  **Checking for ads**, delayed, and terminal states in player chrome; the shelf
  is a compact projection of the same jobs, not a separate source of truth.
- At most five analyzed-but-unplayed episodes are retained as warm slots. When
  the cap is reached, only a no-longer-eligible, unplayed warm slot may be
  evicted; the coordinator never deletes a listener's download to enforce it.

## Readiness and recovery

- **Ready** means the downloaded local file, local profanity analysis, and—when
  cloud ad detection is enabled—cloud ad detection have completed. A zero-ad
  response is an explicit successful completion, not an empty-result cache miss.
- With cloud ad detection disabled, an episode is ready for **clean playback**
  after download and local analysis, but is labeled **Ad checks off** rather than
  ad-ready. It is eligible for normal auto-advance; no ad-filtering guarantee is
  implied. This makes the Settings choice functional rather than an indefinite
  delayed state.
- **Use cloud ad detection** controls whether transcript text is submitted and
  whether an ad-detection completion record can be produced. **Skip ads**
  controls whether completed detected spans are applied during playback. These
  controls are independent: detection may complete while Skip ads is off, and
  turning Skip ads on may apply a completed cached result without another cloud
  request.
- **Ad check delayed** is a retryable cloud failure or an active server-owned
  job. Retry with capped exponential backoff (30 s, 2 min, 10 min, then hourly)
  while the item remains eligible. Network-unavailable, timeout, and server
  overload are retryable; malformed responses and authorization/configuration
  failures become **Needs attention** after the current attempt.
- A delayed or needs-attention episode remains in its manual Up Next position.
  At auto-advance, choose the earliest later fully ready manual item without
  removing or reordering blocked items, and announce which item was deferred and
  why. If no queued item is ready, stop at the boundary and show **Still checking
  the next episode for ads**; never silently start ad-supported playback.
- **Play with ads** is available for any downloaded, non-ad-ready episode from
  preparation details. It starts immediately with the latest persisted local
  profanity intervals and does not require cloud completion. The cloud retry
  continues while the item remains eligible.
- When cloud detection later completes, its ad intervals apply only from the
  next seek, resume, or episode handoff; PodWash does not rewind or interrupt
  audio already played. The detail view then changes to **Ready**.

## Cloud request contract and diagnostics

- Before a job enters **Checking for ads**, verify the configured endpoint,
  Firebase initialization, anonymous-auth availability, and App Check token
  acquisition. A preflight failure becomes **Needs attention** with a specific
  listener-safe explanation; it must not be displayed as an active cloud scan.
- Record a privacy-safe lifecycle for each cloud attempt: started, credentials
  failed, request accepted, server-owned job polled, completed, and failed.
  Record only episode/job identifiers, elapsed time, HTTP status or error class,
  and retry count—never transcript text, sentence content, or audio metadata.
- Categorize outcomes as configuration/credentials, unauthorized, network,
  rate-limited, service unavailable, invalid response, and timeout. The detail
  view uses plain listener language while diagnostics retain the category needed
  to investigate it.
- A server response of `processing` is normal work in progress. The client must
  preserve the server job ID and poll with the same bounded-backoff policy as the
  coordinator until terminal completion, cancellation, or the job's explicit
  timeout. Three fixed one-second polls are not a completion policy.
- A cloud failure is never a no-ad result. Persist an explicit incomplete
  analysis record even when local profanity matching finds zero intervals, so
  relaunch and retry can resume cloud work without treating the episode as a
  completed empty cache hit or re-transcribing unnecessarily.

## Persistence and reconciliation

- Persist recovery-relevant job transitions and retry metadata, not every
  progress tick. Persist the episode ID, analysis fingerprint, stage, retry
  count, retry time, and last meaningful error category.
- On launch, reconcile every persisted job against the local download, interval
  cache completion record, transcript cache, current cleaning settings, and
  target-word fingerprint. Missing files invalidate readiness; a completed
  zero-ad record remains ready; an in-flight state resumes as queued rather than
  claiming background work survived process termination.
- Deleting a downloaded episode removes its preparation record and all related
  local analysis artifacts. Settings or fingerprint changes invalidate only the
  affected readiness claim and schedule a new eligible job.

## Privacy

PodWash transcribes audio on the device. Gemini ad detection receives transcript
text and timestamps, never episode audio. Cloud detection is enabled by default
and remains controllable in Settings; it must not interrupt listening with a
first-use approval prompt.

## Acceptance criteria

- A manual queue followed by smart predictions prepares unique manual episodes
  first, then uses remaining visible slots for predictions; only one download or
  analysis job is active at a time, including during re-aim.
- Re-aim cancels a slow eligible job without allowing its late completion to
  overwrite the state of the newly selected job; duplicate requests for the same
  episode result in one download and one analysis.
- Download and transcription expose measured progress. Cloud detection exposes
  elapsed/retry information and never exposes a countdown.
- Foreground and background preparation expose the same active and terminal
  states. Opening the shelf while the current episode is checking ads shows the
  same job rather than an unrelated warm-only status.
- A completed no-ad response is ready and survives relaunch. A relaunch during
  download, transcription, or cloud detection shows a truthful queued/recovery
  state and resumes without duplicating completed analysis.
- Cloud-off episodes auto-advance as local-clean ready and visibly state that ad
  checks are off. Retryable cloud failures follow the specified backoff;
  non-retryable failures reach Needs attention.
- Cloud preflight and every request outcome produce a privacy-safe diagnostic
  event with a categorized error. A `processing` response remains visibly in
  progress until its preserved server job reaches a terminal response or timeout.
- With detection on and Skip ads off, a successful scan is cached but does not
  alter playback; enabling Skip ads later applies that result without another
  cloud request. A failed scan is never persisted or shown as a no-ad result.
- Auto-advance bypasses a delayed manual item for the earliest later ready item,
  keeps the delayed item in place, and announces the reason. With no ready item,
  playback stops and no ad-supported fallback begins automatically.
- **Play with ads** requires a local file, applies persisted profanity intervals,
  keeps cloud retry active, and never rewinds or interrupts current audio when
  ad detection later succeeds.
- A signed production-like build passes a cloud smoke test: it obtains required
  Firebase credentials, submits a minimal fixture transcript to the configured
  endpoint, receives a terminal no-ad result, and projects that completion into
  the app. Stub-only tests do not satisfy this criterion.
