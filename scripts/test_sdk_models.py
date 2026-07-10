#!/usr/bin/env python3
"""Tests for SDK model selection (fast=false)."""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from sdk_models import (
    COMPOSER_MODEL,
    FORBIDDEN_MODEL_IDS,
    GROK_MODEL,
    format_sdk_model,
    sdk_model_for_role,
    sdk_model_from_id,
)


class SdkModelSelectionTests(unittest.TestCase):
    def test_composer_gets_fast_false(self):
        sel = sdk_model_from_id(COMPOSER_MODEL)
        self.assertEqual(sel["id"], COMPOSER_MODEL)
        self.assertEqual(len(sel["params"]), 1)
        self.assertEqual(sel["params"][0]["id"], "fast")
        self.assertEqual(sel["params"][0]["value"], "false")

    def test_grok_gets_fast_false_and_effort_high(self):
        sel = sdk_model_from_id(GROK_MODEL)
        self.assertEqual(sel["id"], GROK_MODEL)
        by_id = {p["id"]: p["value"] for p in sel["params"]}
        self.assertEqual(by_id["fast"], "false")
        self.assertEqual(by_id["effort"], "high")

    def test_forbidden_fast_ids_rejected(self):
        for mid in FORBIDDEN_MODEL_IDS:
            with self.subTest(mid=mid):
                with self.assertRaises(ValueError):
                    sdk_model_from_id(mid)

    def test_auto_passthrough(self):
        self.assertEqual(sdk_model_from_id("auto"), "auto")

    def test_format_sdk_model(self):
        label = format_sdk_model(sdk_model_for_role(GROK_MODEL))
        self.assertIn("grok-4.5", label)
        self.assertIn("fast=false", label)
        self.assertIn("effort=high", label)


if __name__ == "__main__":
    unittest.main()
