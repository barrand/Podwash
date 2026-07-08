# Phase 2A Plan: Spartan Preprocessing UI

## Summary

Build a local web UI that proves one thing: PodWash can preprocess a short real podcast clip, show clear processing state, and play the censored result.

This is not a podcast app. It is a preprocessing lab with a tiny listening surface.

## Key Changes

- Keep the CLI working while exposing reusable processing functions.
- Add a standard-library Python server bound to `127.0.0.1`.
- Add a no-framework UI with a seeded clip list, selected clip details, process controls, stage status, match counts, a cleaned audio player, and a report link.
- Add `seeds/episodes.json` with the known-good local voice fixture and one remote podcast clip candidate.
- Store generated files under `outputs/episodes/<episode-id>/`.

## Processing Rules

- Clip first, then transcribe and censor the exact working clip.
- Convert each working clip to mono compressed M4A.
- Keep Phase 2A clips at 3 minutes or less.
- Check the working clip against the 25 MB transcription upload limit.
- Use `whisper-1` with `verbose_json` and word timestamps.
- Keep the current beep settings: 80 ms start padding, 120 ms end padding, 180 ms minimum duration, 1000 Hz beep, and 5 ms fades.
- Run only one processing job at a time.
- Reuse cached output unless `Reprocess` is clicked.

## UI States

- `Idle`
- `Clipping`
- `Transcribing`
- `Censoring`
- `Ready`
- `Failed`

The UI does not show raw target words by default. It shows match count, interval count, output audio, and a report link.

## Acceptance Criteria

- The known-good voice fixture still censors its expected target words.
- A seeded real podcast clip can be clipped, transcribed, censored, and played from the browser.
- The UI makes the preprocessing wait and failure state legible.
- No podcast library, RSS parsing, subscriptions, mobile app, or full-episode chunking is included in this phase.
