#!/usr/bin/env python3
"""Transcribe ad-eval episodes to PodWash TimedWord JSON + readable text."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

from ad_eval_common import DEFAULT_WORKDIR, SHOWS, fmt_time, http_get, load_meta, show_dir


def strip_html(text: str) -> str:
    text = re.sub(r"<[^>]+>", " ", text)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def fetch_tal_transcript(url: str) -> str:
    raw = http_get(url, timeout=120).decode("utf-8", errors="replace")
    raw = re.sub(r"<script[^>]*>.*?</script>", " ", raw, flags=re.I | re.S)
    raw = re.sub(r"<style[^>]*>.*?</style>", " ", raw, flags=re.I | re.S)
    raw = strip_html(raw)
    # Trim everything before the standard show open when present.
    for marker in ("From WBEZ Chicago", "From WBEZ", "This American Life"):
        idx = raw.find(marker)
        if idx != -1:
            raw = raw[idx:]
            break
    # Drop trailing site chrome after the standard close when present.
    for end_marker in ("I'm Ira Glass. Back next week", "PRI Public Radio International"):
        idx = raw.find(end_marker)
        if idx != -1:
            raw = raw[: idx + len(end_marker) + 80]
            break
    return raw.strip()


def tal_text_to_timed_words(text: str, duration: float) -> list[dict]:
    words = [w for w in re.findall(r"\S+", text) if w]
    if not words:
        return []
    if len(words) == 1:
        return [{"word": words[0], "start": 0.0, "end": duration}]
    step = duration / len(words)
    out: list[dict] = []
    t = 0.0
    for w in words:
        out.append({"word": w, "start": round(t, 3), "end": round(t + step, 3)})
        t += step
    out[-1]["end"] = round(duration, 3)
    return out


def probe_duration_ffprobe(audio_path: Path) -> float:
    try:
        result = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(audio_path),
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        return float(result.stdout.strip())
    except (subprocess.CalledProcessError, ValueError, FileNotFoundError):
        return 0.0


def transcribe_faster_whisper(audio_path: Path, model_size: str = "tiny.en") -> list[dict]:
    try:
        from faster_whisper import WhisperModel
    except ImportError as exc:
        raise RuntimeError(
            "faster-whisper not installed. Run: pip3 install faster-whisper"
        ) from exc

    model = WhisperModel(model_size, device="cpu", compute_type="int8")
    segments, _info = model.transcribe(
        str(audio_path),
        word_timestamps=True,
        vad_filter=True,
    )

    words: list[dict] = []
    for segment in segments:
        if segment.words:
            for w in segment.words:
                token = (w.word or "").strip()
                if not token:
                    continue
                words.append(
                    {
                        "word": token,
                        "start": round(float(w.start), 3),
                        "end": round(float(w.end), 3),
                    }
                )
        else:
            text = (segment.text or "").strip()
            if not text:
                continue
            for token in text.split():
                words.append(
                    {
                        "word": token,
                        "start": round(float(segment.start), 3),
                        "end": round(float(segment.end), 3),
                    }
                )
    return words


def write_transcript_outputs(
    out_dir: Path,
    words: list[dict],
    source: str,
) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "transcript.json").write_text(
        json.dumps(words, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    plain = " ".join(w["word"] for w in words)
    (out_dir / "transcript.txt").write_text(plain + "\n", encoding="utf-8")

    lines: list[str] = []
    if words:
        bucket = 0.0
        line_words: list[str] = []
        for w in words:
            if w["start"] - bucket >= 30.0 and line_words:
                lines.append(f"[[{fmt_time(bucket)}]] " + " ".join(line_words))
                line_words = []
                bucket = w["start"]
            line_words.append(w["word"])
        if line_words:
            lines.append(f"[[{fmt_time(bucket)}]] " + " ".join(line_words))
    (out_dir / "transcript.md").write_text("\n\n".join(lines) + "\n", encoding="utf-8")

    meta_path = out_dir / "transcript_source.json"
    meta_path.write_text(
        json.dumps({"source": source, "wordCount": len(words)}, indent=2) + "\n",
        encoding="utf-8",
    )


def transcribe_show(
    workdir: Path,
    slug: str,
    model: str,
    force: bool,
    tal_web: bool,
) -> None:
    meta = load_meta(workdir, slug)
    out_dir = show_dir(workdir, slug)
    audio_path = workdir / meta.audio_path
    if not audio_path.exists():
        raise FileNotFoundError(audio_path)

    json_path = out_dir / "transcript.json"
    if json_path.exists() and not force:
        print(f"[{slug}] transcript exists, skipping")
        return

    duration = meta.duration_sec or probe_duration_ffprobe(audio_path)
    if duration <= 0:
        duration = probe_duration_ffprobe(audio_path)
    if duration <= 0:
        duration = 3600.0

    if tal_web and meta.tal_transcript_url:
        print(f"[{slug}] fetching TAL web transcript {meta.tal_transcript_url}")
        text = fetch_tal_transcript(meta.tal_transcript_url)
        words = tal_text_to_timed_words(text, duration)
        source = f"tal_web:{meta.tal_transcript_url}"
    else:
        if meta.tal_transcript_url and not tal_web:
            print(f"[{slug}] Whisper {model} on {audio_path.name} (TAL web transcript skipped — use --tal-web for script text)")
        else:
            print(f"[{slug}] Whisper {model} on {audio_path.name}")
        words = transcribe_faster_whisper(audio_path, model)
        source = f"faster_whisper:{model}"
        if words:
            duration = max(w["end"] for w in words)

    if not words:
        raise RuntimeError(f"No transcript words for {slug}")

    write_transcript_outputs(out_dir, words, source)
    print(f"[{slug}] wrote {len(words)} words")


def main() -> None:
    parser = argparse.ArgumentParser(description="Transcribe ad-eval episodes")
    parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    parser.add_argument("--model", default="tiny.en")
    parser.add_argument("--show", action="append")
    parser.add_argument("--force", action="store_true")
    parser.add_argument(
        "--tal-web",
        action="store_true",
        help="Use TAL website script text with synthetic timings (not for ad eval)",
    )
    args = parser.parse_args()

    workdir = args.workdir.resolve()
    selected = SHOWS
    if args.show:
        wanted = set(args.show)
        selected = [(s, _) for s, _ in SHOWS if s in wanted]

    for slug, _ in selected:
        transcribe_show(workdir, slug, args.model, args.force, args.tal_web)


if __name__ == "__main__":
    main()
