# PodWash Magic Trick Build Plan

## Summary

Build the smallest proof that PodWash can censor selected words from preprocessed audio. The prototype is a local command-line pipeline: one short self-recorded `.m4a` goes in, one beep-censored `.mp3` plus debug JSON comes out.

This does not build a podcast app yet. It proves the crux: word timestamp detection, target-word matching, and audio masking.

The first target words are deliberately harmless stand-ins: `freak`, `freaking`, `ship`, and `shipped`. If this works, the same mechanism can later point at a real profanity list.

## Implementation

- Read `Voice test.m4a` by default.
- Transcribe audio with OpenAI Audio Transcriptions:
  - model: `whisper-1`
  - `response_format="verbose_json"`
  - `timestamp_granularities=["word"]`
  - `language="en"`
  - prompt: `Transcribe verbatim, including the words freak, freaking, ship, and shipped.`
- Match normalized words against `freak`, `freaking`, `ship`, and `shipped`.
- Pad every matched interval:
  - start padding: 80 ms
  - end padding: 120 ms
  - minimum censor duration: 180 ms
- Merge overlapping intervals.
- Decode input audio to a temporary 16-bit PCM WAV with `ffmpeg`.
- Replace target intervals with a 1000 Hz beep using Python's built-in `wave` module.
- Add a 5 ms fade-in and fade-out to the beep to avoid clicks.
- Export the edited WAV to `outputs/voice-test.censored.mp3`.
- Write a debug report to `outputs/voice-test.report.json`.

## Acceptance Criteria

- The report contains all four target words:
  - `freak`
  - `freaking`
  - `ship`
  - `shipped`
- All four target words are covered by beeps in the output audio.
- No beginning or ending of the target words leaks through.
- Non-target words remain understandable.
- The output MP3 plays normally.
- The report JSON includes raw word timestamps and padded censor intervals.

## Assumptions

- `ffmpeg` is installed locally.
- Python 3 is installed locally.
- The OpenAI SDK is installed into a local virtual environment.
- `OPENAI_API_KEY` is provided by the user's shell environment.
- No iOS app, podcast RSS, streaming, subscriptions, accounts, or UI will be built in this step.
