# Phase 2B Plan: Chunked Preprocessing Lab

## Summary

Extend the preprocessing lab so PodWash can process a 10-15 minute podcast segment by chunking transcription work while producing one continuous censored MP3.

The crux is chunk mechanics: timestamp offsets, overlap handling, duplicate removal, and final audio continuity.

## Key Changes

- Add a longer seeded WTF with Marc Maron segment with `chunking_enabled: true`.
- Normalize the source into one `working-full.m4a`.
- Create 5-minute transcription chunks with 3 seconds of overlap.
- Transcribe each chunk with `whisper-1` word timestamps.
- Convert chunk-local timestamps into full-clip timestamps.
- Dedupe overlap matches by normalized word and near-identical global start time.
- Apply all censor intervals once to the full working clip.
- Export one final `censored.mp3`.

## Report Additions

- `chunks`: per-chunk index, global start/end seconds, path, file size, match count, and transcription time.
- `matches`: kept global matches used for censoring.
- `all_matches`: kept and deduped matches, with dedupe status.
- `words`: global word timestamps with source chunk indexes.

## Test Plan

- Re-run the known-good voice fixture.
- Re-run the 3-minute WTF clip.
- Process the 15-minute chunked WTF seed.
- Confirm generated chunks stay under the transcription upload limit.
- Confirm the final MP3 is continuous and the report shows global intervals.
