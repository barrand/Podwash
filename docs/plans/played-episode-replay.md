# Played episodes, transcripts, and replay preparation

## Goal

Separate listener history (**Played**), stored audio, and prepared transcript/
cleaning data. A listener can read a played episode's transcript after its audio
has been removed, and can explicitly prepare a fresh replay without PodWash
silently selecting another episode.

## Listener experience

- Played rows show a checkmark and **Played**.
- Selecting a played row offers **View Transcript** plus one replay action:
  - **Replay from Beginning** when local audio and analysis are ready.
  - **Prepare to Replay** when analysis must be rebuilt; copy states whether
    audio also has to be downloaded and warns that it can take several minutes.
- Confirming preparation immediately removes the old transcript and analysis.
  If local audio remains, PodWash reprocesses it; otherwise it downloads a fresh
  copy and processes that. A fresh download never uses old timestamps.
- Preparation changes neither another episode's current playback nor the played
  flag. When ready, show an in-app **Ready to replay** banner with **Play** and
  **Not now**; never autoplay or notify.
- **Play** resets the saved position to zero before selecting the episode. This
  prevents near-end restore from triggering smart autoplay into another show.
- Failure shows **Preparation failed — Try Again**. No automatic uncleaned
  playback is added.

## Technical design

### State and UI

Add `PlayedEpisodeActionState` with `replayNow`,
`prepare(requiresDownload:)`, `preparing`, `failed`, and `blocked` cases.
`AppShellModel` owns the single active replay id, ready-banner id, and an
episode-list revision. State evaluation must prefer the active replay job over
general local-file readiness; this prevents cleaning-disabled replays from
becoming playable before their forced analysis finishes.

`EpisodeListView` receives played state, replay state, replay callbacks, and
the revision. Played row taps present an iPad-safe action sheet. The existing
transcript icon remains a side-effect-free shortcut. The download accessory on
a played row with no local audio invokes the same preparation confirmation.

### Cleanup

Rename `DownloadManager.deleteDownload` to `removeAudio`. It removes audio,
partial files, resume data, and download state only. It must not touch the
transcript, interval cache, or durable analysis artifact.

`AppShellModel` owns explicit helpers for analysis-only purge and full local
episode discard. Ordinary trash and automatic removal after playing remove only
audio. Unsubscribe, unfinished queue cleanup, and replay preparation perform a
full cleanup where appropriate. Audit every compiler-exposed former
`deleteDownload` call site deliberately.

### Preparation worker

Extend `WarmPlanner.reaim` to accept an optional replay episode. It schedules
replay first, then manual Up Next, then predictions; replay bypasses the warm
cap and never enters Up Next. Use a private request-kind enum only; do not
change persisted `AnalysisJob` schema.

Replay work downloads only when audio is missing but always invokes analysis.
It respects current processing consent/settings and uses existing jobs, retry
behavior, and progress stages.

Add an async `WarmPlanner.quiesce()` that cancels and awaits existing work.
Replay preparation purges analysis immediately, quiesces existing work,
cancels the target download, purges analysis a second time to guard against
late writes, then re-aims the planner. All normal re-aim calls include the
active replay id so queue updates cannot drop it.

Terminal ready and failed replay requests do not block another replay. **Not
now** retires the active replay state and terminal job while retaining prepared
files, so the banner cannot reappear.

### Replay start

`replayFromBeginning` requires replay readiness, calls
`ResumePositionStore.resetForReplay` before the existing `play(episodeID:)`
path, clears replay UI state, and removes the terminal replay job. It must not
construct a second playback pipeline.

## Required tests

- Audio-only removal retains Played state, transcript, intervals, and durable
  analysis; full discard and unsubscribe remove all local artifacts.
- Replay state precedence, including cleaning-disabled replays, active-job
  blocking, terminal-job retirement, and one-time ready banner dismissal.
- Replay work priority, warm-cap bypass, local-audio reanalysis without a
  download, fresh-download analysis, quiesce late-write protection, and retry.
- The near-end regression: a played episode at >=95% starts at zero and does
  not invoke smart autoplay during startup.
- UI fixtures cover played/replay-now, prepare-local, prepare-download,
  preparing, failed, blocked, and ready; assert copy, actions, transcript
  independence, progress, and banner behavior.

## Guardrails

- Keep the existing 95% Played threshold.
- Do not use “completed” for listener state.
- Do not reuse artifacts after a fresh download.
- Do not redownload audio that is already local solely to rebuild analysis.
- Do not delete analysis during ordinary audio removal.
- Do not add replay items to Up Next, parallel preparation infrastructure,
  automatic replay, or notification permission.
- Do not disable smart autoplay to hide the position-reset bug.

## Documentation and verification

Rename the setting to **Remove downloads after playing** and update privacy copy
to state that audio removal retains transcripts and local analysis; replay
preparation replaces them; unsubscribe and app deletion remove them.

Run focused cleanup, planner, app-shell, and episode-list tests, then:

```text
VERIFY_TIER=3a scripts/verify.sh
VERIFY_TIER=3b scripts/verify.sh
scripts/verify.sh
```

The feature is complete only when the final unfiltered run has zero failures
and zero skips.
