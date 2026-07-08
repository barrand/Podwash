#!/usr/bin/env python3
"""Tiny PodWash prototype: transcribe a clip, find target words, beep them out."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Optional


DEFAULT_INPUT = Path("Voice test.m4a")
DEFAULT_OUTPUT = Path("outputs/voice-test.censored.mp3")
DEFAULT_REPORT = Path("outputs/voice-test.report.json")
MAX_TRANSCRIPTION_BYTES = 25 * 1024 * 1024

TARGET_WORDS = {"freak", "freaking", "ship", "shipped"}
TARGET_PROFILES = {
    "harmless": {"freak", "freaking", "ship", "shipped"},
    "profanity": {
        "fuck",
        "fucked",
        "fucker",
        "fuckers",
        "fucking",
        "fucks",
        "shit",
        "shits",
        "shitty",
        "bullshit",
    },
}
START_PADDING_SECONDS = 0.080
END_PADDING_SECONDS = 0.120
MIN_CENSOR_SECONDS = 0.180
BEEP_FREQUENCY_HZ = 1000.0
BEEP_VOLUME = 0.35
BEEP_FADE_SECONDS = 0.005


@dataclass(frozen=True)
class WordTimestamp:
    word: str
    normalized: str
    start: float
    end: float


@dataclass(frozen=True)
class CensorMatch:
    word: str
    normalized: str
    original_start: float
    original_end: float
    padded_start: float
    padded_end: float


@dataclass(frozen=True)
class Interval:
    start: float
    end: float


@dataclass(frozen=True)
class ProcessResult:
    transcript_text: str
    match_count: int
    interval_count: int
    output_path: Path
    report_path: Path
    working_clip_path: Path
    warnings: list[str]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Detect target words in a short audio clip and beep them out."
    )
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument(
        "--targets",
        nargs="+",
        default=sorted(TARGET_WORDS),
        help="Target words to censor after normalization.",
    )
    parser.add_argument(
        "--clip-output",
        type=Path,
        help="Optional clipped/compressed audio path to transcribe and censor.",
    )
    return parser.parse_args()


def require_prerequisites(input_path: Path) -> None:
    if not input_path.exists():
        raise SystemExit(f"Input audio not found: {input_path}")

    if not shutil.which("ffmpeg"):
        raise SystemExit("ffmpeg was not found on PATH. Install ffmpeg before running.")

    if not os.environ.get("OPENAI_API_KEY"):
        raise SystemExit("OPENAI_API_KEY is not set.")


def require_processing_prerequisites() -> None:
    if not shutil.which("ffmpeg"):
        raise RuntimeError("ffmpeg was not found on PATH. Install ffmpeg before running.")

    if not os.environ.get("OPENAI_API_KEY"):
        raise RuntimeError("OPENAI_API_KEY is not set.")


def normalize_word(word: str) -> str:
    normalized = word.lower().strip()
    return re.sub(r"^[^a-z0-9']+|[^a-z0-9']+$", "", normalized)


def transcribe_audio(input_path: Path, prompt: Optional[str] = None) -> Any:
    try:
        from openai import OpenAI
        from openai import OpenAIError
    except ImportError as exc:
        raise RuntimeError(
            "The OpenAI Python SDK is not installed. Run: python -m pip install -r requirements.txt"
        ) from exc

    transcript_prompt = prompt or (
        "Transcribe verbatim, including the words freak, freaking, ship, and shipped."
    )
    client = OpenAI()
    with input_path.open("rb") as audio_file:
        try:
            return client.audio.transcriptions.create(
                file=audio_file,
                model="whisper-1",
                response_format="verbose_json",
                timestamp_granularities=["word"],
                language="en",
                prompt=transcript_prompt,
            )
        except OpenAIError as exc:
            message = str(exc)
            if "insufficient_quota" in message or "exceeded your current quota" in message:
                raise RuntimeError(
                    "OpenAI rejected the transcription request because this API account has no "
                    "available quota. Add billing/credits at https://platform.openai.com/settings/"
                    "organization/billing, then run the script again."
                ) from exc
            raise RuntimeError(f"OpenAI transcription failed: {message}") from exc


def response_to_dict(response: Any) -> dict[str, Any]:
    if hasattr(response, "model_dump"):
        return response.model_dump(mode="json")
    if isinstance(response, dict):
        return response
    if hasattr(response, "to_dict_recursive"):
        return response.to_dict_recursive()
    raise TypeError(f"Unsupported transcription response type: {type(response)!r}")


def extract_words(transcript: dict[str, Any]) -> list[WordTimestamp]:
    words = transcript.get("words") or []
    extracted: list[WordTimestamp] = []

    for item in words:
        word = str(item.get("word", ""))
        start = item.get("start")
        end = item.get("end")
        if start is None or end is None:
            continue
        extracted.append(
            WordTimestamp(
                word=word,
                normalized=normalize_word(word),
                start=float(start),
                end=float(end),
            )
        )

    return extracted


def find_censor_matches(
    words: Iterable[WordTimestamp], target_words: set[str]
) -> list[CensorMatch]:
    matches: list[CensorMatch] = []

    for word in words:
        if word.normalized not in target_words:
            continue

        padded_start = max(0.0, word.start - START_PADDING_SECONDS)
        padded_end = word.end + END_PADDING_SECONDS

        if padded_end - padded_start < MIN_CENSOR_SECONDS:
            midpoint = (padded_start + padded_end) / 2
            half_duration = MIN_CENSOR_SECONDS / 2
            padded_start = max(0.0, midpoint - half_duration)
            padded_end = midpoint + half_duration

        matches.append(
            CensorMatch(
                word=word.word,
                normalized=word.normalized,
                original_start=word.start,
                original_end=word.end,
                padded_start=padded_start,
                padded_end=padded_end,
            )
        )

    return matches


def merge_intervals(matches: Iterable[CensorMatch]) -> list[Interval]:
    sorted_intervals = sorted(
        (Interval(match.padded_start, match.padded_end) for match in matches),
        key=lambda interval: interval.start,
    )
    if not sorted_intervals:
        return []

    merged = [sorted_intervals[0]]
    for interval in sorted_intervals[1:]:
        previous = merged[-1]
        if interval.start <= previous.end:
            merged[-1] = Interval(previous.start, max(previous.end, interval.end))
        else:
            merged.append(interval)

    return merged


def run_ffmpeg(args: list[str]) -> None:
    try:
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", *args], check=True)
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"ffmpeg failed with exit code {exc.returncode}.") from exc


def probe_audio_duration(input_path: Path) -> float:
    try:
        completed = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(input_path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"ffprobe failed with exit code {exc.returncode}.") from exc

    try:
        return float(completed.stdout.strip())
    except ValueError as exc:
        raise RuntimeError(f"Could not read audio duration for {input_path}.") from exc


def clip_to_working_audio(
    source: str,
    clip_path: Path,
    clip_start_seconds: float = 0.0,
    clip_duration_seconds: Optional[float] = None,
) -> None:
    clip_path.parent.mkdir(parents=True, exist_ok=True)
    args = ["-y"]
    if clip_start_seconds > 0:
        args.extend(["-ss", f"{clip_start_seconds:.3f}"])
    args.extend(["-i", source, "-vn"])
    if clip_duration_seconds is not None and clip_duration_seconds > 0:
        args.extend(["-t", f"{clip_duration_seconds:.3f}"])
    args.extend(["-ac", "1", "-ar", "48000", "-c:a", "aac", "-b:a", "64k", str(clip_path)])
    run_ffmpeg(args)


def ensure_transcription_size(input_path: Path) -> None:
    size = input_path.stat().st_size
    if size > MAX_TRANSCRIPTION_BYTES:
        mb = size / (1024 * 1024)
        raise RuntimeError(
            f"Working clip is {mb:.1f} MB, which exceeds the 25 MB transcription limit."
        )


def decode_to_wav(input_path: Path, wav_path: Path) -> None:
    run_ffmpeg(
        [
            "-y",
            "-i",
            str(input_path),
            "-vn",
            "-acodec",
            "pcm_s16le",
            str(wav_path),
        ]
    )


def export_to_mp3(wav_path: Path, output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    run_ffmpeg(
        [
            "-y",
            "-i",
            str(wav_path),
            "-codec:a",
            "libmp3lame",
            "-q:a",
            "2",
            str(output_path),
        ]
    )


def apply_beeps(input_wav: Path, output_wav: Path, intervals: Iterable[Interval]) -> None:
    with wave.open(str(input_wav), "rb") as reader:
        params = reader.getparams()
        frame_rate = reader.getframerate()
        channels = reader.getnchannels()
        sample_width = reader.getsampwidth()
        frame_count = reader.getnframes()
        audio = bytearray(reader.readframes(frame_count))

    if sample_width != 2:
        raise SystemExit(f"Expected 16-bit PCM WAV, got sample width {sample_width}.")

    max_sample = int(32767 * BEEP_VOLUME)
    fade_frames = max(1, int(BEEP_FADE_SECONDS * frame_rate))
    bytes_per_sample = sample_width
    bytes_per_frame = channels * bytes_per_sample

    for interval in intervals:
        start_frame = max(0, int(interval.start * frame_rate))
        end_frame = min(frame_count, int(math.ceil(interval.end * frame_rate)))
        duration_frames = max(1, end_frame - start_frame)

        for frame_index in range(start_frame, end_frame):
            relative_frame = frame_index - start_frame
            fade_in = min(1.0, relative_frame / fade_frames)
            fade_out = min(1.0, (duration_frames - relative_frame - 1) / fade_frames)
            fade = max(0.0, min(fade_in, fade_out))
            sample_value = int(
                max_sample
                * fade
                * math.sin(2 * math.pi * BEEP_FREQUENCY_HZ * frame_index / frame_rate)
            )
            sample_bytes = sample_value.to_bytes(
                bytes_per_sample, byteorder="little", signed=True
            )

            frame_offset = frame_index * bytes_per_frame
            for channel in range(channels):
                sample_offset = frame_offset + channel * bytes_per_sample
                audio[sample_offset : sample_offset + bytes_per_sample] = sample_bytes

    with wave.open(str(output_wav), "wb") as writer:
        writer.setparams(params)
        writer.writeframes(bytes(audio))


def dataclass_dicts(items: Iterable[Any]) -> list[dict[str, Any]]:
    return [item.__dict__ for item in items]


def write_report(
    report_path: Path,
    input_path: Path,
    output_path: Path,
    target_words: set[str],
    transcript: dict[str, Any],
    words: list[WordTimestamp],
    matches: list[CensorMatch],
    intervals: list[Interval],
    warnings: Optional[list[str]] = None,
) -> None:
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report = {
        "input": str(input_path),
        "output": str(output_path),
        "target_words": sorted(target_words),
        "transcript_text": transcript.get("text", ""),
        "words": dataclass_dicts(words),
        "matches": dataclass_dicts(matches),
        "merged_intervals": dataclass_dicts(intervals),
        "warnings": warnings or [],
    }
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


def process_audio_file(
    input_path: Path,
    output_path: Path,
    report_path: Path,
    target_words: set[str],
) -> ProcessResult:
    if not input_path.exists():
        raise RuntimeError(f"Input audio not found: {input_path}")
    require_processing_prerequisites()
    ensure_transcription_size(input_path)

    transcript_response = transcribe_audio(input_path)
    transcript = response_to_dict(transcript_response)
    words = extract_words(transcript)
    if not words:
        raise RuntimeError("Transcription returned no word timestamps.")

    matches = find_censor_matches(words, target_words)
    intervals = merge_intervals(matches)
    warnings: list[str] = []
    if not matches:
        warnings.append("No target words were found in the transcript.")

    with tempfile.TemporaryDirectory(prefix="podwash-") as temp_dir:
        temp_path = Path(temp_dir)
        decoded_wav = temp_path / "decoded.wav"
        censored_wav = temp_path / "censored.wav"

        decode_to_wav(input_path, decoded_wav)
        apply_beeps(decoded_wav, censored_wav, intervals)
        export_to_mp3(censored_wav, output_path)

    if not output_path.exists():
        raise RuntimeError(f"Censored MP3 was not produced: {output_path}")

    write_report(
        report_path,
        input_path,
        output_path,
        target_words,
        transcript,
        words,
        matches,
        intervals,
        warnings,
    )

    return ProcessResult(
        transcript_text=str(transcript.get("text", "")),
        match_count=len(matches),
        interval_count=len(intervals),
        output_path=output_path,
        report_path=report_path,
        working_clip_path=input_path,
        warnings=warnings,
    )


def process_clip(
    source: str,
    working_clip_path: Path,
    output_path: Path,
    report_path: Path,
    target_words: set[str],
    clip_start_seconds: float = 0.0,
    clip_duration_seconds: Optional[float] = None,
) -> ProcessResult:
    require_processing_prerequisites()
    clip_to_working_audio(source, working_clip_path, clip_start_seconds, clip_duration_seconds)
    return process_audio_file(working_clip_path, output_path, report_path, target_words)


def main() -> int:
    args = parse_args()
    input_path = args.input
    output_path = args.output
    report_path = args.report
    target_words = {normalize_word(word) for word in args.targets}

    try:
        require_prerequisites(input_path)

        working_input = input_path
        if args.clip_output:
            clip_to_working_audio(str(input_path), args.clip_output)
            working_input = args.clip_output

        result = process_audio_file(working_input, output_path, report_path, target_words)
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except RuntimeError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1

    print(f"Transcript: {result.transcript_text}")
    print(f"Matched {result.match_count} target word(s):")
    for match in report.get("matches", []):
        print(
            "  "
            f"{match['word']!r} [{match['original_start']:.2f}-{match['original_end']:.2f}s] "
            f"-> beep [{match['padded_start']:.2f}-{match['padded_end']:.2f}s]"
        )
    print(f"Output audio: {output_path}")
    print(f"Report: {report_path}")

    missing = target_words.difference(match["normalized"] for match in report.get("matches", []))
    if missing:
        print(f"Warning: target word(s) not found in transcript: {', '.join(sorted(missing))}")
    for warning in result.warnings:
        print(f"Warning: {warning}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
