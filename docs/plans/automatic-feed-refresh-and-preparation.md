# Automatic Feed Refresh and Reliable Episode Preparation

## Outcome and product rules

PodWash should open immediately with the listener’s saved library, update stale feeds automatically, and prepare likely upcoming episodes without requiring individual download requests.

Success means:

- Returning after several weeks shows newly published episodes as feed requests complete.
- The current episode and playback position restore immediately, without autoplay or waiting for network access.
- PodWash aims to have the next two listening choices ready.
- Preparation survives ordinary suspension and relaunch without duplicate downloads, overlapping transcription, or lost completed work.
- Automatic work remains bounded, visible, and reversible.

### Agreed defaults

- Automatic preparation is enabled by default.
- Automatic network transfers require Wi-Fi and must respect Low Data Mode.
- Automatic assets have a **1 GB budget**, with a **2 GB free-space reserve**.
- Only automatically managed assets may be evicted automatically.
- Existing installs receive a one-time enablement migration and a dismissible notice linking to Settings. Subsequent opt-outs are authoritative.
- Existing cloud consent and cleaning settings remain authoritative.

### Listening order and selection

Use one shared upcoming-order function for preparation, Queue presentation, and automatic playback decisions:

1. Manual Up Next in its saved order.
2. Existing `SmartOrderEngine` predictions, excluding the current episode and duplicates.

Preserve existing Binge and least-recently-heard ordering. Do not introduce listening-history scoring or another recommendation algorithm in this change.

Automatic preparation and Smart Autoplay are separate preferences. Turning off Smart Autoplay prevents automatic playback advancement, but does not disable preparing suggested episodes.

Select automatic episodes only to fill gaps in the first two upcoming choices:

| Manual Up Next count | Additional automatic selections |
|---|---:|
| 0 | Up to 2 |
| 1 | Up to 1 |
| 2 or more | 0 |

All explicit Add & Prepare requests remain eligible for preparation, regardless of the two-choice target. Process them before speculative work. Manual preparation is not constrained by the automatic asset budget, but still respects actual disk capacity and operating-system restrictions.

The target of two is best effort. Insufficient eligible episodes, disk space, connectivity, consent-dependent service availability, or runtime may leave fewer ready.

## Listener experience and lifecycle

### Opening and refreshing

- Render persisted Library, episode lists, and paused playback state before starting network work.
- Refresh feeds on cold launch and foreground activation when their last successful validation is at least **15 minutes** old.
- Opening a show also requests refresh if that feed is stale; coalesce it with any existing request.
- Add pull-to-refresh to Library and show detail. Library refreshes all subscriptions; detail refreshes its feed.
- Manual refresh bypasses staleness and retry backoff, but still joins an existing in-flight request.
- Restore explicit preparation requests immediately. Delay new speculative preparation until the launch refresh pass completes or **10 seconds** elapse.
- After that deadline, use the available catalog. Later results may update pending selections without restarting useful work already in progress.
- Never interrupt currently playing audio because a feed or analysis setting changed.

### First subscription and subsequent subscriptions

A successful subscription already fetched its feed: record that successful refresh time and avoid fetching it again immediately.

Reconcile preparation after subscription succeeds. With one ordinary show, the newest eligible episode is the first candidate; do not download its backlog to fill the second slot. Existing Binge behavior may select consecutive episodes when enabled.

Do not create a separate first-run preparation pipeline.

### Visible state

Add a compact **Ready to Play** section above Library subscriptions:

- Show at most two ready choices, ordered by the shared upcoming-order function.
- Tapping an episode uses the existing immediate-play behavior.
- Link to the existing Queue screen for all prepared episodes and preparation details.
- When no episode is ready but selected work exists, show one useful status line and a Queue link.

Use these preparation states:

- Waiting to prepare
- Downloading
- Preparing clean playback
- Checking for ads
- Waiting for Wi-Fi
- Waiting for charging
- Paused to save power
- Waiting for space
- Ad check delayed
- Needs attention
- Ready to Play

“Ready to Play” requires local audio and preparation valid for the episode’s enabled cleaning features. If cloud ad checks are disabled, local readiness is sufficient, with “Ad checks off” where relevant. A failed required ad check must not become fully ready silently.

Show download percentages only when byte totals are known. Do not invent transcription percentages or remaining-time estimates.

During RSS refresh, retain usable content and show unobtrusive progress. On partial failure, say “Some shows couldn’t update” with Retry. Do not report the whole library as current when some requests failed.

### Settings and migration

Rename the existing auto-download setting to **Keep episodes ready automatically**, with explanatory copy: “Prepares your next two choices. Automatic downloads use Wi-Fi.”

Preserve the existing accessibility identifier where practical.

Add a versioned migration marker. On its first execution:

1. Enable automatic preparation.
2. Mark migration complete.
3. Schedule a one-time nonblocking notice: “PodWash now keeps up to 2 episodes ready on Wi-Fi.”

Separate migration completion from notice dismissal so dismissing or delaying UI does not rerun the migration. Never modify cloud consent.

Turning automatic preparation off cancels unneeded speculative transfers and pending work, stops automatic refilling, and retains completed assets. Explicit requests continue.

## Architecture and implementation contract

### Ownership and composition

Use three responsibilities:

| Component | Responsibility |
|---|---|
| `FeedRefreshCoordinator` | Fetch, validate, merge, and publish catalog changes |
| `UpcomingSelectionPolicy` | Pure calculation of ordered choices and desired preparation |
| `PreparationScheduler` | Durable jobs, priorities, execution, retries, recovery, and resource limits |

Evolve the existing `WarmPlanner` into the scheduler; a compatibility alias is acceptable during migration. Do not introduce another independent worker beside it.

Create these services once per app process, independently of SwiftUI view construction. Background entry points must access persistence and scheduling without building the Library or playback UI. Phone scenes and CarPlay share them.

`AppShellModel` consumes service state and issues commands. It must not duplicate selection or retry rules.

### Feed refresh contract

Extend `FeedFetching` to accept cached validators and return one of:

- Modified: response body, response validators.
- Not modified: response validators.

Keep HTTP handling in the fetcher and XML parsing in `RSSParser`.

Persist per-feed:

- Last attempt and last successful validation time.
- ETag and Last-Modified.
- Consecutive failure count and next eligible retry time.
- Listener-safe failure category.

Rules:

- Maximum **three concurrent feed requests**.
- At most one in-flight refresh per feed.
- A `304` advances successful validation time without replacing catalog content.
- A modified response advances successful validation time and validators only after parsing and database commit succeed.
- Missing validators in a successful modified response clear obsolete stored validators.
- Automatic retry delays are **15 minutes, 1 hour, then 6 hours**, capped at 6 hours. Success resets backoff.
- Use a **30-second total timeout per feed attempt**.
- Failure leaves the prior catalog and successful-validation timestamp intact.
- An unsubscribed feed must not be recreated by a late refresh response; verify subscription membership at commit.
- Coalesce published catalog-change notifications so one feed batch does not repeatedly restart preparation.

Implement a transactional `mergeRefreshedFeed` operation that updates episode metadata in place and inserts new episodes.

Preserve existing episodes absent from the latest RSS response. **Do not implement catalog pruning in this feature.**

Preserve playback position, played/dismissed flags, queue entries, local asset ownership, and analysis state. Deduplicate incoming IDs before merging. The current globally unique episode-ID assumption remains; reject a cross-feed collision as a feed failure instead of deleting or reassigning another show’s episode. A broader identity migration is outside this change.

A changed enclosure URL must not silently replace downloaded audio or associate newly downloaded bytes with an old analysis result.

### Pure selection policy

Inputs must be value snapshots:

- Current episode ID.
- Ordered manual queue.
- Podcast and episode eligibility data.
- Existing smart-order context.
- Automatic preparation preference.
- Per-episode automatic suppression.
- Existing selected and ready episodes.

Output:

- Ordered manual requests.
- Up to two selected automatic episode IDs.
- Request priorities and selection reasons.

Inject time into any ranking code that currently calls `Date()` internally, allowing deterministic tests.

Remove `peekCount = 4` and the in-memory five-item cap as preparation-budget mechanisms. The UI may separately request a longer preview, but preview length must not start additional work.

### Durable scheduler and jobs

Persist scheduler jobs in Core Data using an additive model migration. Import existing `AnalysisJobStore` records once where episodes still exist. Existing assets with unknown ownership are treated as protected/manual.

A job needs:

- Episode ID.
- Origin: manual or automatic.
- Stage.
- Waiting reason, if any.
- Retry count and next-attempt time.
- Updated time and preparation completion time.
- Transfer association.
- Input revision/fingerprint identifying the audio and analysis settings used.

Store live byte progress in memory; persist lifecycle transitions rather than every progress tick.

Use a single resource gate for analysis across foreground playback, recovery, replay, automatic preparation, and retry paths.

Execution bounds:

- At most **one transcription/analysis operation**.
- At most **one audio transfer**, which may overlap analysis for another episode.
- Priority: current listener-requested preparation, manual queue order, selected automatic work.
- Complete or checkpoint useful work before changing targets.
- Explicit current-episode preparation may preempt speculative work, but the replacement must wait until the prior analyzer has actually stopped.
- Network completion callbacks do not require a surviving async continuation to commit results.

Reconciliation must be idempotent: repeated events with identical inputs must not cancel, duplicate, or restart work.

Replace detached delayed retry tasks with persisted retry deadlines serviced by the same scheduler. Cancellation and task expiration are resumable interruptions, not retryable service failures. Never immediately retry a cancellation inside `analyzeWithOneRetry`.

Removing a download records `automaticPreparationSuppressed` for that episode. Automatic refill must respect it. Explicit Play or Add & Prepare clears suppression.

Queueing or beginning playback of an automatically prepared episode promotes its assets to protected ownership. Removing it from the queue later does not silently restore automatic eviction eligibility.

### Recovery and artifact validity

On process start or background wake:

1. Reconnect background URL sessions.
2. Enumerate their actual tasks and match persisted jobs.
3. Verify local files and completed preparation artifacts.
4. Convert orphaned running states to resumable pending states.
5. Recompute desired work and execute only what the current runtime permits.

Preserve completed stages:

- Completed download survives transcription interruption.
- Completed transcript survives ad-check failure.
- Retry ad detection without repeating transcription.
- Settings changes reuse valid transcripts and rebuild only invalid derived results.

Do not claim partial ASR resume unless implemented and tested. For this version, checkpoint transcription at **whole-episode completion**; an interrupted transcription attempt may restart. Prevent partially written transcripts or analysis from being published as complete.

Tie analysis validity to downloaded audio identity and the existing relevant settings/pipeline fingerprint. Redownloading audio must invalidate results for the previous audio, even when the episode ID is unchanged.

### Network, power, and storage

Apply network restrictions to automatic network work, not local computation:

- RSS refresh may use cellular, including manual refresh.
- Automatic audio and cloud requests require Wi-Fi and an unconstrained connection.
- Explicit Play/Add & Prepare may use cellular under the app’s existing explicit-action behavior.
- Local analysis may proceed without Wi-Fi.
- Low Power Mode or serious/critical thermal state pauses speculative execution at a safe boundary.
- Scheduled automatic background analysis requires external power.
- Explicit actions remain subject to system runtime and actual storage availability.

Use separate stable background URL-session configurations for automatic and explicit transfers so restrictive automatic policies do not block explicit work. Globally deduplicate episode transfers across both sessions.

The **1 GB budget** covers automatic audio, partial downloads, transcripts, and derived artifacts. Protected assets are excluded from that budget but still consume physical free space. Include temporary processing requirements when checking the **2 GB reserve**.

Use known response lengths where available and monitor actual bytes for unknown-length downloads. Pause/cancel automatic work that cannot stay within budget. Never present disk-pressure pauses as corrupt-download failures.

Automatic cleanup may remove only unprotected automatic assets. Evict unselected assets first, oldest preparation first; use episode ID as a deterministic tie-breaker.

Keep two selected slots and permit at most **one replacement episode** in progress. Retain an old ready episode until its replacement is ready when space permits. Under pressure, release an unselected automatic episode first.

Eviction removes that episode’s automatically owned audio and derived artifacts together. Deleting or evicting assets must settle affected work before removal so late callbacks cannot recreate them.

## Background execution and delivery sequence

### Platform integration

Register handlers during app startup and configure the required permitted identifiers and background modes.

- `BGAppRefreshTask`: refresh due feeds and persist/reconcile desired work. Request the next opportunity no earlier than **one hour** later. Reschedule after each invocation.
- Background `URLSession`: transfer audio and commit completed files after suspension or system relaunch.
- `BGProcessingTask`: perform pending automatic analysis while charging. Request network connectivity only when the intended pending stage needs it.
- `BGContinuedProcessingTask`: support foreground user-requested Play/Add & Prepare work continuing after the app leaves the foreground. Use user-visible job descriptions and cancellation. Do not submit this task for automatic predictions.

Apple requires continued processing to originate from a user action; scheduled background work remains system-controlled. [Apple’s continued-processing guidance](https://developer.apple.com/documentation/BackgroundTasks/performing-long-running-tasks-on-ios-and-ipados)

All expiration handlers must stop accepting work, request cancellation, preserve completed stages, and complete the operating-system task exactly once. Background-task cancellation must not cancel unrelated playback.

If continued processing is unavailable or submission fails, keep the request durable, run while foreground execution is allowed, and show an honest waiting state after suspension.

### Implementation sequence and required outcomes

1. **Prove background analysis feasibility.** On a supported physical device, run the real production analyzer on a representative 45–90 minute episode while locked and charging. Exercise expiration and relaunch. Establish a supported compute configuration for scheduled background execution; explicitly avoid relying on unsupported accelerator access. If it cannot complete reliably, record the limitation and leave scheduled ASR disabled rather than silently claiming the feature works.
2. **Ship-safe feed refresh foundation.** Add transactional merge, conditional requests, lifecycle refresh, and live UI updates. Existing listening state must survive.
3. **Unify preparation execution.** Add durable jobs, shared selection, one analyzer gate, transfer reconciliation, and stage-aware retries. Route existing foreground and warm paths through it before enabling new automatic behavior.
4. **Add automatic policies and background integration.** Implement resource gates, ownership, suppression, replacement, budgets, and platform handlers.
5. **Enable the experience.** Add Library readiness UI, settings copy, migration notice, and release validation.

Preserve unrelated working-tree changes. Re-read the affected lifecycle, audio, and playback code before editing because those areas already contain ongoing work.

No new backend, remote notification system, bulk offline shelf, catalog pruning, or recommendation-model changes are required.

## Validation and acceptance requirements

### Automated behavioral tests

Use injected clock, feed transport, network/power state, disk capacity, analyzer, and background-task adapters. Tests must not depend on sleeps, real RSS publishers, or actual background scheduling.

Required scenarios:

| Area | Required assertion |
|---|---|
| Launch | Cached UI and paused playback restore before a deliberately blocked RSS response completes |
| Freshness | Repeated activation within 15 minutes performs no redundant request; stale activation refreshes |
| Fetching | Maximum three requests; same-feed requests coalesce; `304`, timeout, malformed XML, and backoff behave correctly |
| Persistence | Refresh preserves queue, position, played/dismissed state, ownership, and missing-from-RSS episodes |
| Races | Unsubscribe during refresh does not recreate the subscription; cross-feed ID collision changes neither feed |
| Selection | Zero, one, and multiple manual entries yield the specified automatic selections; Binge order and suppression are respected |
| Preferences | Smart Autoplay off still allows preparation; automatic preparation off prevents speculative work |
| Serialization | A delayed retry, foreground Play, and automatic job cannot produce overlapping analyzer calls |
| Reconciliation | Repeated identical events do not cancel or restart running work |
| Preemption | Explicit Play takes priority only after prior analyzer cancellation settles |
| Recovery | Relaunch after download or transcript completion resumes the next stage without repeating completed stages |
| Transfers | Completion without an in-memory waiter still commits once; recovered tasks do not create duplicate downloads |
| Validity | New audio cannot reuse old-audio analysis; changed settings invalidate only affected preparation |
| Cloud failure | Ad retry reuses the transcript; missing consent causes zero cloud submissions |
| Resource gates | Wi-Fi, Low Data Mode, power, thermal, byte budget, unknown lengths, and free-space reserve are enforced |
| Cleanup | Manual/current/started/queued assets survive; deleting an episode does not trigger automatic redownload |
| Migration | Enablement happens once; notice state is separate; later opt-out survives relaunch |
| UI | Ready means locally playable under enabled cleaning settings; partial refresh failure does not claim full freshness |

Test cancellation separately from network failure. Include an analyzer fake that notices cancellation late to expose overlapping-worker bugs.

Keep fixture launches isolated from live network requests and OS background scheduling, while allowing tests to inject those events explicitly.

### Physical-device acceptance

Required before declaring background preparation complete:

- Open after a stale catalog interval and observe fresh episodes without navigating away.
- Start explicit preparation, lock the phone, and verify supported continuation or truthful resumable waiting behavior.
- Complete scheduled analysis while charging and locked using production models.
- Expire work during transcription and during ad checking; relaunch and verify completed stages are retained.
- Suspend during an audio transfer and verify system-managed completion/reconciliation.
- Force-quit and reopen; recover without promising that iOS continued work while force-quit.
- Exercise Wi-Fi loss, Low Power Mode, and limited disk space.
- Verify ongoing playback remains responsive and uninterrupted during preparation.

Simulator tests establish application logic. Physical-device evidence establishes background-runtime and compute feasibility.

### Delivery evidence

The implementation handoff must include:

- The resulting user behavior and migration behavior.
- Automated commands run and their outcomes.
- Device/OS/model configuration and background-analysis results.
- Any background capability still unverified or disabled.
- Diagnostic events for refresh success/failure, preparation stage transitions, interruption, retry, and eviction reasons, without transcript content or sensitive feed URLs.

Do not mark the work complete solely because the app builds or scheduler mocks pass. Background analysis, interruption recovery, and listener-state preservation are release acceptance requirements.
