# PodWash Prototype README (archived)

> Archived for remembered context. This was the original `README.md` describing the
> command-line "magic trick" prototype and the preprocessing lab. The prototype
> proved the core mechanic (word-level timestamp detection + audio masking) that
> the product now builds on. For the current product direction, see
> [`docs/product-requirements.md`](../product-requirements.md).

PodWash is starting with a tiny "magic trick" prototype: take one recorded audio file, detect a few target words with word-level timestamps, and beep over those words.

## Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
export OPENAI_API_KEY="your_api_key_here"
```

You also need `ffmpeg` on your `PATH`.

## Run The Prototype

```bash
python podwash.py
```

By default, the script reads:

```text
Voice test.m4a
```

And writes:

```text
outputs/voice-test.censored.mp3
outputs/voice-test.report.json
```

You can pass custom paths:

```bash
python podwash.py --input "Voice test.m4a" --output outputs/custom.censored.mp3 --report outputs/custom.report.json
```

## First Acceptance Test

Listen to `outputs/voice-test.censored.mp3` and check that `freak`, `freaking`, `ship`, and `shipped` are fully covered by beeps while the rest of the sentence stays understandable.

## Run The Preprocessing Lab

```bash
python app_server.py
```

Open:

```text
http://127.0.0.1:8765
```

The lab uses seeded clips from:

```text
seeds/episodes.json
```

It writes per-clip outputs under:

```text
outputs/episodes/<episode-id>/
```

Phase 2A clips are intentionally short. Remote podcast seeds are clipped and compressed before transcription so the working file stays under the 25 MB upload limit.

The longer Phase 2B seed uses chunked transcription: PodWash normalizes one working clip, transcribes overlapping chunks, offsets matches back onto the full timeline, and renders one continuous censored MP3.
