#!/usr/bin/env python3
"""Local server for reviewing podcast ad goldens."""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import os
import subprocess
import tempfile
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse


ROOT = Path(__file__).resolve().parents[2]
STATIC_DIR = Path(__file__).resolve().parent / "static"
DEFAULT_WORKDIR = ROOT / "tmp" / "ad-eval"
DEFAULT_GOLDEN_DIR = ROOT / "eval" / "ad-detection" / "goldens"

ALLOWED_LABELS = {
    "paid_dai",
    "paid_baked_in",
    "paid_host_read",
    "network_promo",
    "membership_cta",
}

LABEL_METADATA = {
    "paid_dai": {
        "category": "paid_ad",
        "delivery": "dynamic",
        "deliveryConfidence": "suspected",
        "readStyle": "unknown",
    },
    "paid_baked_in": {
        "category": "paid_ad",
        "delivery": "baked_in",
        "deliveryConfidence": "suspected",
        "readStyle": "unknown",
    },
    "paid_host_read": {
        "category": "paid_ad",
        "delivery": "unknown",
        "deliveryConfidence": "unknown",
        "readStyle": "host",
    },
    "network_promo": {
        "category": "network_promo",
        "delivery": "unknown",
        "deliveryConfidence": "unknown",
        "readStyle": "unknown",
    },
    "membership_cta": {
        "category": "membership_cta",
        "delivery": "unknown",
        "deliveryConfidence": "unknown",
        "readStyle": "host",
    },
}


class ReviewError(Exception):
    def __init__(self, message: str, status: int = HTTPStatus.BAD_REQUEST):
        super().__init__(message)
        self.status = int(status)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def json_bytes(payload: Any) -> bytes:
    return (json.dumps(payload, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def atomic_json(path: Path, payload: Any) -> None:
    encoded = json_bytes(payload)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
    except BaseException:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def run_git(args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=ROOT,
        capture_output=True,
        check=False,
        text=True,
        timeout=30,
    )


def git_auto_commit_golden(path: Path, slug: str) -> dict[str, Any]:
    """Best-effort commit/push for one approved golden file.

    This is intentionally narrow: approval should never accidentally commit
    unrelated local work. Git failures are reported to the UI but do not undo
    the saved human-approved golden.
    """

    try:
        relative = path.resolve().relative_to(ROOT)
    except ValueError:
        return {
            "attempted": False,
            "success": False,
            "message": "Golden is outside the repository; git auto-commit skipped.",
        }

    if relative.parts[:3] != ("eval", "ad-detection", "goldens"):
        return {
            "attempted": False,
            "success": False,
            "message": f"Golden path {relative} is outside eval/ad-detection/goldens; git auto-commit skipped.",
        }

    status = run_git(["status", "--porcelain", "--", str(relative)])
    if status.returncode != 0:
        return {
            "attempted": True,
            "success": False,
            "message": (status.stderr or status.stdout or "git status failed").strip(),
        }
    if not status.stdout.strip():
        return {
            "attempted": True,
            "success": True,
            "message": "Golden already matched git; no commit needed.",
        }

    add = run_git(["add", "--", str(relative)])
    if add.returncode != 0:
        return {
            "attempted": True,
            "success": False,
            "message": (add.stderr or add.stdout or "git add failed").strip(),
        }

    commit = run_git(
        [
            "commit",
            "--only",
            "-m",
            f"golden: approve {slug} ad spans",
            "--",
            str(relative),
        ]
    )
    if commit.returncode != 0:
        return {
            "attempted": True,
            "success": False,
            "message": (commit.stderr or commit.stdout or "git commit failed").strip(),
        }

    push = run_git(["push"])
    if push.returncode != 0:
        return {
            "attempted": True,
            "success": False,
            "message": (push.stderr or push.stdout or "git push failed").strip(),
            "commitOutput": commit.stdout.strip(),
        }

    return {
        "attempted": True,
        "success": True,
        "message": "Golden committed and pushed.",
        "commitOutput": commit.stdout.strip(),
        "pushOutput": push.stdout.strip() or push.stderr.strip(),
    }


def normalized_span(raw: dict[str, Any], word_count: int) -> dict[str, Any]:
    try:
        start = int(raw["startWord"])
        end = int(raw["endWord"])
    except (KeyError, TypeError, ValueError) as exc:
        raise ReviewError("every span needs integer startWord/endWord") from exc
    if start < 0 or end <= start or end > word_count:
        raise ReviewError(f"invalid span range {start}..{end} for {word_count} words")

    label = str(raw.get("label") or "")
    if label not in ALLOWED_LABELS:
        raise ReviewError(f"invalid span label {label!r}")
    span_id = str(raw.get("id") or "").strip()
    if not span_id:
        raise ReviewError("every span needs an id")

    return {
        "id": span_id,
        "startWord": start,
        "endWord": end,
        "label": label,
        "advertiser": str(raw.get("advertiser") or "").strip(),
        "note": str(raw.get("note") or "").strip(),
        "origin": str(raw.get("origin") or "human-added"),
        "proposalId": str(raw.get("proposalId") or "").strip() or None,
    }


def validate_spans(raw_spans: Any, word_count: int) -> list[dict[str, Any]]:
    if not isinstance(raw_spans, list):
        raise ReviewError("spans must be an array")
    spans = [normalized_span(raw, word_count) for raw in raw_spans]
    ids = [span["id"] for span in spans]
    if len(ids) != len(set(ids)):
        raise ReviewError("span ids must be unique")
    spans.sort(key=lambda span: (span["startWord"], span["endWord"], span["id"]))
    for left, right in zip(spans, spans[1:]):
        if left["endWord"] > right["startWord"]:
            raise ReviewError(
                f"spans {left['id']} and {right['id']} overlap at word "
                f"{right['startWord']}"
            )
    return spans


@dataclass
class EpisodeFiles:
    slug: str
    directory: Path
    meta: Path
    transcript: Path
    transcript_source: Path
    proposal: Path
    review: Path
    golden: Path


class ReviewStore:
    def __init__(
        self,
        workdir: Path = DEFAULT_WORKDIR,
        golden_dir: Path = DEFAULT_GOLDEN_DIR,
        slugs: tuple[str, ...] | None = None,
    ):
        self.workdir = workdir.resolve()
        self.golden_dir = golden_dir.resolve()
        self.slugs = slugs
        self._write_lock = threading.Lock()

    def episode_slugs(self) -> tuple[str, ...]:
        if self.slugs is not None:
            return self.slugs
        if not self.workdir.exists():
            return ()
        return tuple(
            path.name
            for path in sorted(self.workdir.iterdir())
            if path.is_dir() and not path.name.startswith(".")
        )

    def files(self, slug: str) -> EpisodeFiles:
        if slug not in self.episode_slugs():
            raise ReviewError("unknown review episode", HTTPStatus.NOT_FOUND)
        directory = self.workdir / slug
        return EpisodeFiles(
            slug=slug,
            directory=directory,
            meta=directory / "meta.json",
            transcript=directory / "transcript.json",
            transcript_source=directory / "transcript_source.json",
            proposal=directory / "proposal.json",
            review=directory / "review.json",
            golden=self.golden_dir / f"{slug}.json",
        )

    def transcript_hash(self, files: EpisodeFiles) -> str:
        return file_sha256(files.transcript)

    def proposal_hash(self, files: EpisodeFiles) -> str:
        return file_sha256(files.proposal) if files.proposal.exists() else ""

    def load_proposal(self, files: EpisodeFiles, transcript_hash: str) -> dict[str, Any]:
        if not files.proposal.exists():
            return {
                "schemaVersion": 1,
                "showSlug": files.slug,
                "transcriptSha256": transcript_hash,
                "sources": {},
                "spans": [],
                "auditItems": [],
            }
        proposal = load_json(files.proposal)
        if str(proposal.get("showSlug") or "") != files.slug:
            raise ReviewError("proposal show slug does not match episode")
        if str(proposal.get("transcriptSha256") or "") != transcript_hash:
            raise ReviewError("proposal is stale for the current transcript")
        return proposal

    def fresh_review(
        self,
        files: EpisodeFiles,
        words: list[dict[str, Any]],
        proposal: dict[str, Any],
        transcript_hash: str,
    ) -> dict[str, Any]:
        proposed_spans = validate_spans(proposal.get("spans") or [], len(words))
        spans: list[dict[str, Any]] = []
        for index, span in enumerate(proposed_spans, 1):
            proposal_id = span["id"]
            spans.append(
                {
                    **span,
                    "id": f"span-{index}",
                    "proposalId": proposal_id,
                    "origin": "ai-proposal",
                }
            )
        return {
            "schemaVersion": 1,
            "showSlug": files.slug,
            "status": "in_review",
            "revision": 0,
            "transcriptSha256": transcript_hash,
            "proposalSha256": self.proposal_hash(files),
            "reviewedThroughWord": 0,
            "resumeWord": 0,
            "spans": spans,
            "auditDecisions": {},
            "attested": False,
            "reviewer": "Brian",
            "createdAt": utc_now(),
            "updatedAt": utc_now(),
        }

    def load_episode(self, slug: str) -> dict[str, Any]:
        files = self.files(slug)
        if not files.meta.exists():
            raise ReviewError("episode metadata is missing", HTTPStatus.NOT_FOUND)
        if not files.transcript.exists():
            raise ReviewError("episode transcript is not ready", HTTPStatus.CONFLICT)

        meta = load_json(files.meta)
        words = load_json(files.transcript)
        if not isinstance(words, list) or not words:
            raise ReviewError("episode transcript is empty")
        transcript_hash = self.transcript_hash(files)
        source = load_json(files.transcript_source) if files.transcript_source.exists() else {}
        recorded_hash = str(source.get("transcriptSha256") or "")
        if recorded_hash and recorded_hash != transcript_hash:
            raise ReviewError("transcript provenance hash does not match transcript.json")
        proposal = self.load_proposal(files, transcript_hash)

        if files.review.exists():
            review = load_json(files.review)
            if str(review.get("transcriptSha256") or "") != transcript_hash:
                raise ReviewError("saved review is stale for the current transcript")
            if str(review.get("proposalSha256") or "") != self.proposal_hash(files):
                raise ReviewError("saved review is stale for the current proposal")
            review["spans"] = validate_spans(review.get("spans") or [], len(words))
        else:
            review = self.fresh_review(files, words, proposal, transcript_hash)

        return {
            "slug": slug,
            "title": str(meta.get("episodeTitle") or slug),
            "showName": str(meta.get("showName") or slug),
            "words": words,
            "transcriptSource": source,
            "proposal": proposal,
            "review": review,
            "approvedGoldenExists": files.golden.exists(),
        }

    def list_episodes(self) -> list[dict[str, Any]]:
        episodes: list[dict[str, Any]] = []
        for slug in self.episode_slugs():
            files = self.files(slug)
            title = slug
            show_name = slug
            if files.meta.exists():
                meta = load_json(files.meta)
                title = str(meta.get("episodeTitle") or meta.get("title") or slug)
                show_name = str(meta.get("showName") or meta.get("showTitle") or slug)
            status = "transcript_missing"
            progress = 0.0
            word_count = 0
            if files.transcript.exists():
                status = "not_started"
                words = load_json(files.transcript)
                word_count = len(words) if isinstance(words, list) else 0
                if files.review.exists():
                    review = load_json(files.review)
                    status = str(review.get("status") or "in_review")
                    progress = (
                        min(1.0, int(review.get("reviewedThroughWord") or 0) / word_count)
                        if word_count
                        else 0.0
                    )
                elif files.golden.exists():
                    status = "approved"
                    progress = 1.0
            episodes.append(
                {
                    "slug": slug,
                    "title": title,
                    "showName": show_name,
                    "status": status,
                    "progress": progress,
                    "wordCount": word_count,
                    "transcriptReady": files.transcript.exists(),
                    "proposalReady": files.proposal.exists(),
                    "reviewExists": files.review.exists(),
                    "goldenExists": files.golden.exists(),
                }
            )
        return episodes

    def save_review(self, slug: str, submitted: dict[str, Any]) -> dict[str, Any]:
        with self._write_lock:
            return self._save_review(slug, submitted)

    def _save_review(self, slug: str, submitted: dict[str, Any]) -> dict[str, Any]:
        files = self.files(slug)
        episode = self.load_episode(slug)
        current = episode["review"]
        expected_revision = int(submitted.get("revision", -1))
        current_revision = int(current.get("revision", 0))
        if expected_revision != current_revision:
            raise ReviewError(
                f"review revision conflict: expected {current_revision}, got "
                f"{expected_revision}",
                HTTPStatus.CONFLICT,
            )

        word_count = len(episode["words"])
        reviewed = int(submitted.get("reviewedThroughWord") or 0)
        resume = int(submitted.get("resumeWord") or 0)
        if reviewed < 0 or reviewed > word_count:
            raise ReviewError("reviewedThroughWord is out of range")
        if resume < 0 or resume >= word_count:
            resume = 0

        audit_ids = {
            str(item.get("id") or "")
            for item in episode["proposal"].get("auditItems") or []
            if str(item.get("id") or "")
        }
        raw_decisions = submitted.get("auditDecisions") or {}
        if not isinstance(raw_decisions, dict):
            raise ReviewError("auditDecisions must be an object")
        audit_decisions = {
            str(key): bool(value)
            for key, value in raw_decisions.items()
            if str(key) in audit_ids
        }

        normalized_spans = validate_spans(submitted.get("spans") or [], word_count)
        reviewer = str(submitted.get("reviewer") or "Brian").strip() or "Brian"
        attested = bool(submitted.get("attested"))
        meaningful_change = any(
            (
                normalized_spans != current.get("spans", []),
                reviewed != int(current.get("reviewedThroughWord") or 0),
                audit_decisions != current.get("auditDecisions", {}),
                attested != bool(current.get("attested")),
                reviewer != str(current.get("reviewer") or "Brian"),
            )
        )
        keep_approved = (
            str(current.get("status") or "") == "approved" and not meaningful_change
        )

        saved = {
            **current,
            "status": "approved" if keep_approved else "in_review",
            "revision": current_revision + 1,
            "reviewedThroughWord": reviewed,
            "resumeWord": resume,
            "spans": normalized_spans,
            "auditDecisions": audit_decisions,
            "attested": attested,
            "reviewer": reviewer,
            "updatedAt": utc_now(),
        }
        if (
            str(current.get("status") or "") == "approved"
            and meaningful_change
            and files.golden.exists()
        ):
            files.golden.unlink()
            saved.pop("approvedAt", None)
        atomic_json(files.review, saved)
        return saved

    def approve(self, slug: str, submitted: dict[str, Any]) -> dict[str, Any]:
        with self._write_lock:
            return self._approve(slug, submitted)

    def _approve(self, slug: str, submitted: dict[str, Any]) -> dict[str, Any]:
        files = self.files(slug)
        episode = self.load_episode(slug)
        word_count = len(episode["words"])
        if int(submitted.get("reviewedThroughWord") or 0) != word_count:
            raise ReviewError("review cursor must reach the final word before approval")

        raw_decisions = submitted.get("auditDecisions") or {}
        if not isinstance(raw_decisions, dict):
            raise ReviewError("auditDecisions must be an object")
        audit_items = episode["proposal"].get("auditItems") or []
        if not bool(submitted.get("attested")):
            raise ReviewError("end-to-end review attestation is required")

        saved = self._save_review(slug, submitted)
        episode = self.load_episode(slug)
        words = episode["words"]
        golden_spans: list[dict[str, Any]] = []
        for span in saved["spans"]:
            start_word = int(span["startWord"])
            end_word = int(span["endWord"])
            label = str(span["label"])
            metadata = LABEL_METADATA[label]
            golden_span = {
                "id": span["id"],
                "startWord": start_word,
                "endWord": end_word,
                "start": round(float(words[start_word]["start"]), 3),
                "end": round(float(words[end_word - 1]["end"]), 3),
                "label": label,
                **metadata,
                "origin": span["origin"],
            }
            if span.get("advertiser"):
                golden_span["advertiser"] = span["advertiser"]
            if span.get("note"):
                golden_span["note"] = span["note"]
            golden_spans.append(golden_span)

        source = episode["transcriptSource"]
        approved_at = utc_now()
        golden = {
            "schemaVersion": 1,
            "annotationPolicy": "ads-only-v1",
            "status": "human-approved",
            "showSlug": slug,
            "audioSha256": str(source.get("audioSha256") or ""),
            "transcriptSha256": saved["transcriptSha256"],
            "asr": {
                "engine": str(source.get("engine") or ""),
                "engineVersion": str(source.get("engineVersion") or ""),
                "model": str(source.get("model") or ""),
                "modelRevision": str(source.get("modelRevision") or ""),
                "wordCount": word_count,
            },
            "review": {
                "reviewer": saved["reviewer"],
                "reviewedAt": approved_at,
                "reviewedThroughWord": word_count,
                "proposalSha256": saved["proposalSha256"],
                "optionalModelNotesCount": len(audit_items),
            },
            "spans": golden_spans,
        }
        atomic_json(files.golden, golden)
        saved["status"] = "approved"
        saved["approvedAt"] = approved_at
        saved["revision"] = int(saved["revision"]) + 1
        atomic_json(files.review, saved)
        git_result = git_auto_commit_golden(files.golden, slug)
        return {"review": saved, "golden": golden, "git": git_result}


class ReviewHandler(BaseHTTPRequestHandler):
    server_version = "PodWashAdGoldenReviewer/1.0"
    store: ReviewStore

    def log_message(self, format: str, *args: Any) -> None:
        print(f"[reviewer] {self.address_string()} {format % args}")

    def send_json(self, payload: Any, status: int = HTTPStatus.OK) -> None:
        encoded = json_bytes(payload)
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)

    def send_error_json(self, message: str, status: int) -> None:
        self.send_json({"error": message}, status)

    def read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > 8 * 1024 * 1024:
            raise ReviewError("invalid request body size")
        try:
            payload = json.loads(self.rfile.read(length))
        except json.JSONDecodeError as exc:
            raise ReviewError("request body is not valid JSON") from exc
        if not isinstance(payload, dict):
            raise ReviewError("request body must be a JSON object")
        return payload

    def check_write_origin(self) -> None:
        origin = self.headers.get("Origin")
        if not origin:
            return
        parsed = urlparse(origin)
        if parsed.hostname not in {"127.0.0.1", "localhost"}:
            raise ReviewError("cross-origin writes are not allowed", HTTPStatus.FORBIDDEN)

    def route(self) -> tuple[list[str], str]:
        parsed = urlparse(self.path)
        parts = [unquote(part) for part in parsed.path.split("/") if part]
        return parts, parsed.path

    def do_GET(self) -> None:
        try:
            parts, raw_path = self.route()
            if parts == ["api", "episodes"]:
                self.send_json({"episodes": self.store.list_episodes()})
                return
            if len(parts) == 3 and parts[:2] == ["api", "episodes"]:
                self.send_json(self.store.load_episode(parts[2]))
                return
            self.send_static(raw_path)
        except ReviewError as exc:
            self.send_error_json(str(exc), exc.status)
        except Exception as exc:
            self.send_error_json(str(exc), HTTPStatus.INTERNAL_SERVER_ERROR)

    def do_PUT(self) -> None:
        try:
            self.check_write_origin()
            parts, _ = self.route()
            if len(parts) != 4 or parts[:2] != ["api", "episodes"] or parts[3] != "review":
                raise ReviewError("unknown endpoint", HTTPStatus.NOT_FOUND)
            self.send_json({"review": self.store.save_review(parts[2], self.read_json())})
        except ReviewError as exc:
            self.send_error_json(str(exc), exc.status)
        except Exception as exc:
            self.send_error_json(str(exc), HTTPStatus.INTERNAL_SERVER_ERROR)

    def do_POST(self) -> None:
        try:
            self.check_write_origin()
            parts, _ = self.route()
            if len(parts) != 4 or parts[:2] != ["api", "episodes"] or parts[3] != "approve":
                raise ReviewError("unknown endpoint", HTTPStatus.NOT_FOUND)
            self.send_json(self.store.approve(parts[2], self.read_json()))
        except ReviewError as exc:
            self.send_error_json(str(exc), exc.status)
        except Exception as exc:
            self.send_error_json(str(exc), HTTPStatus.INTERNAL_SERVER_ERROR)

    def send_static(self, raw_path: str) -> None:
        relative = "index.html" if raw_path in {"", "/"} else raw_path.lstrip("/")
        candidate = (STATIC_DIR / relative).resolve()
        if STATIC_DIR.resolve() not in candidate.parents and candidate != STATIC_DIR.resolve():
            raise ReviewError("invalid static path", HTTPStatus.NOT_FOUND)
        if not candidate.is_file():
            candidate = STATIC_DIR / "index.html"
        data = candidate.read_bytes()
        media_type = mimetypes.guess_type(candidate.name)[0] or "application/octet-stream"
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", f"{media_type}; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self'; style-src 'self'; "
            "img-src 'self' data:; connect-src 'self'",
        )
        self.end_headers()
        self.wfile.write(data)


def make_handler(store: ReviewStore) -> type[ReviewHandler]:
    class ConfiguredHandler(ReviewHandler):
        pass

    ConfiguredHandler.store = store
    return ConfiguredHandler


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--workdir", type=Path, default=DEFAULT_WORKDIR)
    parser.add_argument("--golden-dir", type=Path, default=DEFAULT_GOLDEN_DIR)
    args = parser.parse_args()

    if args.host not in {"127.0.0.1", "localhost"}:
        raise SystemExit("reviewer may only bind to localhost")
    store = ReviewStore(args.workdir, args.golden_dir)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(store))
    print(f"PodWash Golden Retriever: http://{args.host}:{server.server_port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
