#!/usr/bin/env python3
"""Tiny local PodWash preprocessing lab."""

from __future__ import annotations

import json
import mimetypes
import tempfile
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional
from urllib.parse import parse_qs, unquote, urlparse

import podwash


HOST = "127.0.0.1"
PORT = 8765
ROOT = Path(__file__).resolve().parent
STATIC_DIR = ROOT / "static"
SEEDS_PATH = ROOT / "seeds" / "episodes.json"
OUTPUT_ROOT = ROOT / "outputs" / "episodes"
MAX_PHASE_2A_CLIP_SECONDS = 180
MAX_PHASE_2B_SEGMENT_SECONDS = 15 * 60
CHUNK_DURATION_SECONDS = 5 * 60
CHUNK_OVERLAP_SECONDS = 3
DEDUPE_WINDOW_SECONDS = 1.0

JOB_LOCK = threading.Lock()


def load_episodes() -> list[dict]:
    return json.loads(SEEDS_PATH.read_text(encoding="utf-8"))


def find_episode(episode_id: str) -> dict:
    for episode in load_episodes():
        if episode["id"] == episode_id:
            return episode
    raise KeyError(episode_id)


def episode_dir(episode_id: str) -> Path:
    return OUTPUT_ROOT / episode_id


def status_path(episode_id: str) -> Path:
    return episode_dir(episode_id) / "status.json"


def default_status(episode: dict) -> dict:
    output_path = episode_dir(episode["id"]) / "censored.mp3"
    report_path = episode_dir(episode["id"]) / "report.json"
    state = "Ready" if output_path.exists() and report_path.exists() else "Idle"
    status = {
        "state": state,
        "message": "Cached output is ready." if state == "Ready" else "Ready to process.",
        "match_count": None,
        "interval_count": None,
        "warning": None,
        "error": None,
        "output_url": f"/outputs/episodes/{episode['id']}/censored.mp3" if state == "Ready" else None,
        "report_url": f"/outputs/episodes/{episode['id']}/report.json" if state == "Ready" else None,
        "updated_at": time.time(),
    }

    if report_path.exists():
        try:
            report = json.loads(report_path.read_text(encoding="utf-8"))
            status["match_count"] = len(report.get("matches", []))
            status["interval_count"] = len(report.get("merged_intervals", []))
            warnings = report.get("warnings") or []
            status["warning"] = warnings[0] if warnings else None
        except (OSError, json.JSONDecodeError):
            pass

    return status


def read_status(episode: dict) -> dict:
    path = status_path(episode["id"])
    if not path.exists():
        return default_status(episode)
    try:
        status = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default_status(episode)

    output_path = episode_dir(episode["id"]) / "censored.mp3"
    report_path = episode_dir(episode["id"]) / "report.json"
    if status.get("state") == "Ready":
        status["output_url"] = f"/outputs/episodes/{episode['id']}/censored.mp3"
        status["report_url"] = f"/outputs/episodes/{episode['id']}/report.json"
    elif output_path.exists() and report_path.exists():
        status = default_status(episode)
    return status


def write_status(episode_id: str, state: str, message: str, **extra: object) -> None:
    path = status_path(episode_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    current = {}
    if path.exists():
        try:
            current = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            current = {}
    current.update(
        {
            "state": state,
            "message": message,
            "updated_at": time.time(),
            **extra,
        }
    )
    path.write_text(json.dumps(current, indent=2) + "\n", encoding="utf-8")


def public_episode(episode: dict) -> dict:
    safe = {
        "id": episode["id"],
        "show": episode["show"],
        "title": episode["title"],
        "source_type": episode["source_type"],
        "clip_start_seconds": episode.get("clip_start_seconds") or 0,
        "clip_duration_seconds": episode.get("clip_duration_seconds"),
        "target_profile": episode["target_profile"],
        "chunking_enabled": bool(episode.get("chunking_enabled")),
        "status": read_status(episode),
    }
    return safe


def resolve_source(episode: dict) -> str:
    source = episode["source"]
    if episode["source_type"] == "local":
        source_path = ROOT / source
        if not source_path.exists():
            raise RuntimeError(f"Local source file is missing: {source}")
        return str(source_path)
    if episode["source_type"] == "url":
        return source
    raise RuntimeError(f"Unsupported source_type: {episode['source_type']}")


def target_words_for_episode(episode: dict) -> set[str]:
    target_profile = episode["target_profile"]
    if target_profile not in podwash.TARGET_PROFILES:
        raise RuntimeError(f"Unknown target profile: {target_profile}")
    return podwash.TARGET_PROFILES[target_profile]


def prompt_for_episode(episode: dict) -> str:
    if episode["target_profile"] == "profanity":
        return "Transcribe verbatim, preserving profanity and casual speech."
    return "Transcribe verbatim, including the words freak, freaking, ship, and shipped."


def write_cached_ready_status(episode: dict) -> None:
    episode_id = episode["id"]
    status = default_status(episode)
    write_status(
        episode_id,
        "Ready",
        "Cached output is ready.",
        match_count=status.get("match_count"),
        interval_count=status.get("interval_count"),
        warning=status.get("warning"),
        error=None,
        output_url=f"/outputs/episodes/{episode_id}/censored.mp3",
        report_url=f"/outputs/episodes/{episode_id}/report.json",
    )


def complete_status(
    episode_id: str,
    matches: list[dict],
    intervals: list[podwash.Interval],
    warnings: list[str],
    started_at: float,
) -> None:
    write_status(
        episode_id,
        "Ready",
        "Cleaned audio is ready.",
        match_count=len(matches),
        interval_count=len(intervals),
        warning=warnings[0] if warnings else None,
        error=None,
        elapsed_seconds=round(time.time() - started_at, 2),
        output_url=f"/outputs/episodes/{episode_id}/censored.mp3",
        report_url=f"/outputs/episodes/{episode_id}/report.json",
    )


def process_episode(episode: dict, force: bool = False) -> None:
    if episode.get("chunking_enabled"):
        process_chunked_episode(episode, force)
    else:
        process_one_shot_episode(episode, force)


def process_one_shot_episode(episode: dict, force: bool = False) -> None:
    started_at = time.time()
    episode_id = episode["id"]
    output_dir = episode_dir(episode_id)
    output_dir.mkdir(parents=True, exist_ok=True)

    output_path = output_dir / "censored.mp3"
    report_path = output_dir / "report.json"
    working_clip_path = output_dir / "source-clip.m4a"

    if output_path.exists() and report_path.exists() and not force:
        write_cached_ready_status(episode)
        return

    if episode.get("clip_duration_seconds") and episode["clip_duration_seconds"] > MAX_PHASE_2A_CLIP_SECONDS:
        raise RuntimeError("Non-chunked Phase 2A clips must be 3 minutes or shorter.")

    source = resolve_source(episode)
    target_words = target_words_for_episode(episode)

    write_status(episode_id, "Clipping", "Creating a small mono working clip.", error=None)
    podwash.require_processing_prerequisites()
    podwash.clip_to_working_audio(
        source,
        working_clip_path,
        float(episode.get("clip_start_seconds") or 0),
        episode.get("clip_duration_seconds"),
    )
    podwash.ensure_transcription_size(working_clip_path)

    write_status(episode_id, "Transcribing", "Requesting word-level timestamps.")
    transcript_response = podwash.transcribe_audio(working_clip_path, prompt_for_episode(episode))
    transcript = podwash.response_to_dict(transcript_response)
    words = podwash.extract_words(transcript)
    if not words:
        raise RuntimeError("Transcription returned no word timestamps.")

    matches = podwash.find_censor_matches(words, target_words)
    intervals = podwash.merge_intervals(matches)
    warnings = []
    if not matches:
        warnings.append("No target words were found in the transcript.")

    write_status(episode_id, "Censoring", "Rendering beeped audio.")
    with tempfile.TemporaryDirectory(prefix="podwash-web-") as temp_dir:
        temp_path = Path(temp_dir)
        decoded_wav = temp_path / "decoded.wav"
        censored_wav = temp_path / "censored.wav"
        podwash.decode_to_wav(working_clip_path, decoded_wav)
        podwash.apply_beeps(decoded_wav, censored_wav, intervals)
        podwash.export_to_mp3(censored_wav, output_path)

    if not output_path.exists():
        raise RuntimeError("Censored MP3 was not produced.")

    podwash.write_report(
        report_path,
        working_clip_path,
        output_path,
        target_words,
        transcript,
        words,
        matches,
        intervals,
        warnings,
    )
    complete_status(
        episode_id,
        [match.__dict__ for match in matches],
        intervals,
        warnings,
        started_at,
    )


def chunk_ranges(duration_seconds: float) -> list[tuple[int, float, float]]:
    ranges: list[tuple[int, float, float]] = []
    start = 0.0
    index = 0
    step = CHUNK_DURATION_SECONDS - CHUNK_OVERLAP_SECONDS
    while start < duration_seconds:
        end = min(duration_seconds, start + CHUNK_DURATION_SECONDS)
        if end - start < 1.0:
            break
        ranges.append((index, start, end))
        if end >= duration_seconds:
            break
        start += step
        index += 1
    return ranges


def padded_global_match(
    word: podwash.WordTimestamp,
    chunk_index: int,
    chunk_start: float,
    target_words: set[str],
) -> Optional[dict]:
    if word.normalized not in target_words:
        return None

    global_start = chunk_start + word.start
    global_end = chunk_start + word.end
    padded_start = max(0.0, global_start - podwash.START_PADDING_SECONDS)
    padded_end = global_end + podwash.END_PADDING_SECONDS
    if padded_end - padded_start < podwash.MIN_CENSOR_SECONDS:
        midpoint = (padded_start + padded_end) / 2
        half_duration = podwash.MIN_CENSOR_SECONDS / 2
        padded_start = max(0.0, midpoint - half_duration)
        padded_end = midpoint + half_duration

    return {
        "word": word.word,
        "normalized": word.normalized,
        "chunk_index": chunk_index,
        "chunk_local_start": word.start,
        "chunk_local_end": word.end,
        "original_start": global_start,
        "original_end": global_end,
        "padded_start": padded_start,
        "padded_end": padded_end,
        "dedupe_status": "kept",
    }


def duplicate_match(candidate: dict, kept: list[dict]) -> bool:
    for match in kept:
        if match["normalized"] != candidate["normalized"]:
            continue
        if abs(match["original_start"] - candidate["original_start"]) <= DEDUPE_WINDOW_SECONDS:
            return True
    return False


def write_chunked_report(
    report_path: Path,
    input_path: Path,
    output_path: Path,
    target_words: set[str],
    transcript_text: str,
    chunks: list[dict],
    words: list[dict],
    matches: list[dict],
    all_matches: list[dict],
    intervals: list[podwash.Interval],
    warnings: list[str],
) -> None:
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report = {
        "input": str(input_path),
        "output": str(output_path),
        "target_words": sorted(target_words),
        "transcript_text": transcript_text,
        "chunks": chunks,
        "words": words,
        "matches": matches,
        "all_matches": all_matches,
        "merged_intervals": [interval.__dict__ for interval in intervals],
        "warnings": warnings,
    }
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


def process_chunked_episode(episode: dict, force: bool = False) -> None:
    started_at = time.time()
    episode_id = episode["id"]
    output_dir = episode_dir(episode_id)
    output_dir.mkdir(parents=True, exist_ok=True)

    output_path = output_dir / "censored.mp3"
    report_path = output_dir / "report.json"
    working_full_path = output_dir / "working-full.m4a"
    chunks_dir = output_dir / "chunks"
    chunks_dir.mkdir(parents=True, exist_ok=True)

    if output_path.exists() and report_path.exists() and not force:
        write_cached_ready_status(episode)
        return

    clip_duration = episode.get("clip_duration_seconds")
    if not clip_duration or clip_duration > MAX_PHASE_2B_SEGMENT_SECONDS:
        raise RuntimeError("Chunked Phase 2B seeds must be 15 minutes or shorter.")

    source = resolve_source(episode)
    target_words = target_words_for_episode(episode)

    write_status(episode_id, "Clipping", "Creating one full normalized working clip.", error=None)
    podwash.require_processing_prerequisites()
    podwash.clip_to_working_audio(
        source,
        working_full_path,
        float(episode.get("clip_start_seconds") or 0),
        clip_duration,
    )

    duration = podwash.probe_audio_duration(working_full_path)
    ranges = chunk_ranges(duration)
    if not ranges:
        raise RuntimeError("No transcription chunks were generated.")

    for old_chunk in chunks_dir.glob("chunk-*.m4a"):
        old_chunk.unlink()

    chunks: list[dict] = []
    write_status(episode_id, "Clipping", f"Creating {len(ranges)} transcription chunks.")
    for index, start, end in ranges:
        chunk_path = chunks_dir / f"chunk-{index:03d}.m4a"
        podwash.clip_to_working_audio(str(working_full_path), chunk_path, start, end - start)
        podwash.ensure_transcription_size(chunk_path)
        chunks.append(
            {
                "index": index,
                "global_start": start,
                "global_end": end,
                "path": str(chunk_path),
                "file_size": chunk_path.stat().st_size,
                "match_count": 0,
                "transcription_seconds": None,
            }
        )

    prompt = prompt_for_episode(episode)
    transcript_parts: list[str] = []
    all_words: list[dict] = []
    kept_matches: list[dict] = []
    all_matches: list[dict] = []
    chunk_warnings: list[str] = []

    for chunk in chunks:
        chunk_number = chunk["index"] + 1
        total_chunks = len(chunks)
        write_status(
            episode_id,
            "Transcribing",
            f"Transcribing chunk {chunk_number} of {total_chunks}.",
            chunk_index=chunk["index"],
            chunk_count=total_chunks,
        )
        transcribe_started_at = time.time()
        transcript_response = podwash.transcribe_audio(Path(chunk["path"]), prompt)
        chunk["transcription_seconds"] = round(time.time() - transcribe_started_at, 2)
        transcript = podwash.response_to_dict(transcript_response)
        transcript_parts.append(str(transcript.get("text", "")))
        words = podwash.extract_words(transcript)
        if not words:
            warning = f"Chunk {chunk_number} returned no word timestamps."
            chunk["warning"] = warning
            chunk_warnings.append(warning)
            continue

        chunk_match_count = 0
        for word in words:
            global_word = {
                "word": word.word,
                "normalized": word.normalized,
                "chunk_index": chunk["index"],
                "chunk_local_start": word.start,
                "chunk_local_end": word.end,
                "start": chunk["global_start"] + word.start,
                "end": chunk["global_start"] + word.end,
            }
            all_words.append(global_word)

            match = padded_global_match(
                word,
                chunk["index"],
                chunk["global_start"],
                target_words,
            )
            if not match:
                continue

            chunk_match_count += 1
            if duplicate_match(match, kept_matches):
                match["dedupe_status"] = "removed_overlap_duplicate"
            else:
                kept_matches.append(match)
            all_matches.append(match)

        chunk["match_count"] = chunk_match_count

    if not all_words:
        raise RuntimeError("No chunk returned word timestamps.")

    intervals = podwash.merge_intervals(
        [
            podwash.CensorMatch(
                word=match["word"],
                normalized=match["normalized"],
                original_start=match["original_start"],
                original_end=match["original_end"],
                padded_start=match["padded_start"],
                padded_end=match["padded_end"],
            )
            for match in kept_matches
        ]
    )
    warnings = list(chunk_warnings)
    if not kept_matches:
        warnings.append("No target words were found in the transcript.")

    write_status(episode_id, "Censoring", "Rendering one continuous beeped audio file.")
    with tempfile.TemporaryDirectory(prefix="podwash-web-") as temp_dir:
        temp_path = Path(temp_dir)
        decoded_wav = temp_path / "decoded.wav"
        censored_wav = temp_path / "censored.wav"
        podwash.decode_to_wav(working_full_path, decoded_wav)
        podwash.apply_beeps(decoded_wav, censored_wav, intervals)
        podwash.export_to_mp3(censored_wav, output_path)

    if not output_path.exists():
        raise RuntimeError("Censored MP3 was not produced.")

    write_chunked_report(
        report_path,
        working_full_path,
        output_path,
        target_words,
        " ".join(part for part in transcript_parts if part),
        chunks,
        all_words,
        kept_matches,
        all_matches,
        intervals,
        warnings,
    )
    complete_status(episode_id, kept_matches, intervals, warnings, started_at)


def run_job(episode: dict, force: bool) -> None:
    episode_id = episode["id"]
    acquired = JOB_LOCK.acquire(blocking=False)
    if not acquired:
        write_status(episode_id, "Failed", "Another episode is already processing.", error="Only one preprocessing job can run at a time.")
        return

    try:
        process_episode(episode, force=force)
    except Exception as exc:
        write_status(episode_id, "Failed", str(exc), error=str(exc))
    finally:
        JOB_LOCK.release()


class PodWashHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/":
            self.serve_file(STATIC_DIR / "index.html")
            return
        if path == "/api/episodes":
            self.send_json({"episodes": [public_episode(episode) for episode in load_episodes()]})
            return
        if path.startswith("/api/episodes/") and path.endswith("/status"):
            episode_id = unquote(path.split("/")[3])
            try:
                episode = find_episode(episode_id)
            except KeyError:
                self.send_error(HTTPStatus.NOT_FOUND, "Episode not found")
                return
            self.send_json(read_status(episode))
            return
        if path.startswith("/static/"):
            self.serve_static(path)
            return
        if path.startswith("/outputs/"):
            self.serve_output(path)
            return

        self.send_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        if path.startswith("/api/episodes/") and path.endswith("/process"):
            episode_id = unquote(path.split("/")[3])
            force = parse_qs(parsed.query).get("force") == ["1"]
            try:
                episode = find_episode(episode_id)
            except KeyError:
                self.send_error(HTTPStatus.NOT_FOUND, "Episode not found")
                return
            write_status(episode_id, "Idle", "Queued for processing.", error=None)
            thread = threading.Thread(target=run_job, args=(episode, force), daemon=True)
            thread.start()
            self.send_json(read_status(episode), status=HTTPStatus.ACCEPTED)
            return

        self.send_error(HTTPStatus.NOT_FOUND, "Not found")

    def serve_output(self, request_path: str) -> None:
        requested = (ROOT / unquote(request_path.lstrip("/"))).resolve()
        output_root = (ROOT / "outputs").resolve()
        if output_root not in requested.parents and requested != output_root:
            self.send_error(HTTPStatus.FORBIDDEN, "Forbidden")
            return
        self.serve_file(requested)

    def serve_static(self, request_path: str) -> None:
        requested = (STATIC_DIR / unquote(request_path.removeprefix("/static/"))).resolve()
        static_root = STATIC_DIR.resolve()
        if static_root not in requested.parents and requested != static_root:
            self.send_error(HTTPStatus.FORBIDDEN, "Forbidden")
            return
        self.serve_file(requested)

    def serve_file(self, path: Path) -> None:
        if not path.exists() or not path.is_file():
            self.send_error(HTTPStatus.NOT_FOUND, "File not found")
            return
        content_type = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
        data = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, payload: dict, status: HTTPStatus = HTTPStatus.OK) -> None:
        data = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format: str, *args: object) -> None:
        print(f"{self.address_string()} - {format % args}")


def main() -> int:
    server = ThreadingHTTPServer((HOST, PORT), PodWashHandler)
    print(f"PodWash Lab running at http://{HOST}:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down PodWash Lab.")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
