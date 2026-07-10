#!/usr/bin/env python3
"""Unit tests for slice-loop bridge timeout / retry helpers (no SDK / Xcode)."""

import os
import sys
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from slice_loop import (  # noqa: E402
    build_prompt,
    resolve_stream_timeout,
    retry_sleep_secs,
    should_retry_bridge_error,
    slice_status,
)
from cursor_bridge import (  # noqa: E402
    bridge_safe_auth_token,
    is_dash_prefixed_token_argv_error,
)


class _FakeErr(Exception):
    def __init__(self, *, is_retryable=False, retry_after=None):
        super().__init__("fake")
        self.is_retryable = is_retryable
        self.retry_after = retry_after


class BridgeTimeoutHelpersTests(unittest.TestCase):
    def test_resolve_stream_timeout_zero_disables(self):
        self.assertIsNone(resolve_stream_timeout(0))
        self.assertIsNone(resolve_stream_timeout(0.0))
        self.assertIsNone(resolve_stream_timeout(None))
        self.assertIsNone(resolve_stream_timeout(-1))

    def test_resolve_stream_timeout_positive(self):
        self.assertEqual(resolve_stream_timeout(600), 600.0)
        self.assertEqual(resolve_stream_timeout(3600.5), 3600.5)

    def test_should_retry_respects_flag_and_budget(self):
        err = _FakeErr(is_retryable=True)
        self.assertTrue(should_retry_bridge_error(err, attempt=1, max_retries=3))
        self.assertTrue(should_retry_bridge_error(err, attempt=2, max_retries=3))
        self.assertFalse(should_retry_bridge_error(err, attempt=3, max_retries=3))
        self.assertFalse(
            should_retry_bridge_error(_FakeErr(is_retryable=False), attempt=1, max_retries=3)
        )

    def test_retry_sleep_honors_retry_after_and_backoff(self):
        self.assertEqual(retry_sleep_secs(_FakeErr(retry_after="12"), attempt=1), 12.0)
        self.assertEqual(retry_sleep_secs(_FakeErr(retry_after="nope"), attempt=1), 5.0)
        self.assertEqual(retry_sleep_secs(_FakeErr(), attempt=1), 5.0)
        self.assertEqual(retry_sleep_secs(_FakeErr(), attempt=2), 10.0)
        self.assertEqual(retry_sleep_secs(_FakeErr(), attempt=3), 20.0)

    def test_should_retry_dash_prefixed_token_argv_error(self):
        err = Exception(
            "Bridge exited before discovery with status 1: "
            "Missing value for --tool-callback-auth-token"
        )
        self.assertTrue(is_dash_prefixed_token_argv_error(err))
        self.assertTrue(should_retry_bridge_error(err, attempt=1, max_retries=3))
        self.assertFalse(should_retry_bridge_error(err, attempt=3, max_retries=3))

    def test_bridge_safe_auth_token_never_starts_with_dash(self):
        for _ in range(200):
            self.assertFalse(bridge_safe_auth_token().startswith("-"))

    def test_slice_status_and_resume_prompt(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "slice-09-analysis-ui.md")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(
                    "# Slice 09 — Analysis\n\n"
                    "| Field | Value |\n"
                    "|-------|-------|\n"
                    "| **Status** | In Progress |\n"
                )
            self.assertEqual(slice_status(path, tmp), "In Progress")
            prompt = build_prompt(9, path)
            self.assertIn("RESUME", prompt)
            self.assertIn("do NOT restart from scratch", prompt)
            self.assertIn("Skip completed gates", prompt)
            self.assertIn("HANDOFF CONTRACT", prompt)
            self.assertIn("Do NOT run", prompt)
            self.assertIn("verify.sh", prompt)
            self.assertIn("authoring gates only", prompt)

            ready = os.path.join(tmp, "slice-10.md")
            with open(ready, "w", encoding="utf-8") as fh:
                fh.write("| **Status** | Ready |\n")
            self.assertNotIn("RESUME", build_prompt(10, ready))
            ready_prompt = build_prompt(10, ready)
            self.assertIn("HANDOFF CONTRACT", ready_prompt)
            self.assertIn("Do NOT run", ready_prompt)


if __name__ == "__main__":
    unittest.main()
