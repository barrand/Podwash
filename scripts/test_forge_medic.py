#!/usr/bin/env python3
"""Unit tests for Forge Medic (forge_medic.py)."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from forge_medic import (
    MEDIC_CRITIC_ROLE,
    MEDIC_DIAGNOSE_ROLE,
    MEDIC_IMPLEMENT_ROLE,
    MEDIC_ROLES,
    check_diff_denylist,
    check_files_scripts_only,
    compute_halt_signature,
    deterministic_critic,
    extract_json_object,
    filter_medic_delta,
    merge_critic,
    parse_diagnose_plan,
    path_guard_violations,
    resolve_regression_unittest,
    signature_already_healed,
    append_medic_ledger,
    write_medic_report,
    DiagnosePlan,
)
from sdk_models import FORBIDDEN_MODEL_IDS, sdk_model_from_id
from slice_pipeline import ROLE_MODELS, mode_for_role, model_for_role


class HaltSignatureTests(unittest.TestCase):
    def test_stable_signature(self):
        halt = {
            "slice": 16,
            "phase": "HALT",
            "reason": "THRASH HALT: no progress",
            "failures": ["FooTests/testBar()"],
            "verify_result": {"class": "tests"},
            "extra": {"halt_kind": "no_progress"},
        }
        a = compute_halt_signature(halt)
        b = compute_halt_signature(dict(halt))
        self.assertEqual(a, b)
        self.assertEqual(len(a), 12)

    def test_different_failures_different_sig(self):
        h1 = {"slice": 1, "phase": "HALT", "reason": "x", "failures": ["A"], "extra": {}}
        h2 = {"slice": 1, "phase": "HALT", "reason": "x", "failures": ["B"], "extra": {}}
        self.assertNotEqual(compute_halt_signature(h1), compute_halt_signature(h2))


class LedgerDedupTests(unittest.TestCase):
    def test_signature_already_healed(self):
        with tempfile.TemporaryDirectory() as tmp:
            append_medic_ledger(
                tmp,
                {"signature": "abc123", "outcome": "healed", "healed": True},
            )
            self.assertTrue(signature_already_healed(tmp, "abc123"))
            self.assertFalse(signature_already_healed(tmp, "other"))

    def test_critic_blocked_counts_as_attempt(self):
        with tempfile.TemporaryDirectory() as tmp:
            append_medic_ledger(
                tmp, {"signature": "sig1", "outcome": "critic_blocked"}
            )
            self.assertTrue(signature_already_healed(tmp, "sig1"))


class DiagnoseParseTests(unittest.TestCase):
    def test_extract_json_fence(self):
        text = 'hello\n```json\n{"lane": "messaging", "x": 1}\n```\n'
        data = extract_json_object(text)
        self.assertEqual(data["lane"], "messaging")

    def test_parse_healable_plan(self):
        blob = {
            "lane": "messaging",
            "halt_signature": "abc",
            "root_cause": "stuck card printed still red: []",
            "harden_plan": ["surface real failure ids"],
            "files": ["scripts/failure_packet.py", "scripts/test_failure_packet.py"],
            "regression_test": "scripts.test_failure_packet.Foo.test_bar",
            "console_upgrade": "still red: Foo/testBar()",
            "plain_summary": {"what_broke": "opaque halt"},
        }
        text = f"## Post\n\n```json\n{json.dumps(blob)}\n```\n"
        plan = parse_diagnose_plan(text, expected_signature="abc")
        self.assertEqual(plan.lane, "messaging")
        self.assertTrue(plan.healable)
        self.assertIn("failure_packet", plan.files[0])

    def test_invalid_lane(self):
        text = '```json\n{"lane": "banana", "root_cause": "x", "regression_test": "t"}\n```'
        with self.assertRaises(ValueError):
            parse_diagnose_plan(text)

    def test_healable_requires_regression(self):
        text = (
            '```json\n{"lane": "infra", "root_cause": "bridge", '
            '"harden_plan": ["retry"], "files": ["scripts/a.py"], '
            '"regression_test": ""}\n```'
        )
        with self.assertRaises(ValueError):
            parse_diagnose_plan(text)


class CriticRubricTests(unittest.TestCase):
    def _plan(self, **kwargs) -> DiagnosePlan:
        base = dict(
            lane="messaging",
            halt_signature="x",
            root_cause="opaque still-red empty list",
            harden_plan=["print real ids"],
            files=["scripts/failure_packet.py"],
            regression_test="scripts.test_failure_packet.T.test_x",
            console_upgrade="still red: X",
        )
        base.update(kwargs)
        return DiagnosePlan(**base)

    def test_approve_good_plan(self):
        r = deterministic_critic(self._plan())
        self.assertTrue(r.approved)
        self.assertGreaterEqual(r.score, 4)

    def test_reject_test_lane(self):
        r = deterministic_critic(self._plan(lane="test"))
        self.assertFalse(r.approved)
        self.assertTrue(any("lane=test" in b for b in r.blockers))

    def test_reject_app_paths(self):
        r = deterministic_critic(
            self._plan(files=["PodWash/PodWash/Foo.swift"])
        )
        self.assertFalse(r.approved)

    def test_reject_guard_weakening_language(self):
        r = deterministic_critic(
            self._plan(harden_plan=["raise DEFAULT_MAX_MECHANIC spawns to 20"])
        )
        self.assertFalse(r.approved)

    def test_merge_llm_reject(self):
        det = deterministic_critic(self._plan())
        self.assertTrue(det.approved)
        merged = merge_critic(
            det, '```json\n{"approved": false, "blockers": ["too large"]}\n```'
        )
        self.assertFalse(merged.approved)
        self.assertIn("too large", merged.blockers)


class DenylistTests(unittest.TestCase):
    def test_raise_thrash_deletion(self):
        diff = """\
--- a/scripts/mechanic_fix.py
+++ b/scripts/mechanic_fix.py
@@ -1,3 +1,2 @@
-    raise ThrashHalt("no progress")
+    return False
"""
        hits = check_diff_denylist(diff)
        self.assertTrue(any("ThrashHalt" in h for h in hits))

    def test_constant_change(self):
        diff = """\
--- a/scripts/factory_progress.py
+++ b/scripts/factory_progress.py
@@ -1,2 +1,2 @@
-DEFAULT_MAX_MECHANIC_SPAWNS = 8
+DEFAULT_MAX_MECHANIC_SPAWNS = 99
"""
        hits = check_diff_denylist(diff)
        self.assertTrue(any("DEFAULT_MAX_MECHANIC_SPAWNS" in h for h in hits))

    def test_clean_diff(self):
        diff = """\
--- a/scripts/failure_packet.py
+++ b/scripts/failure_packet.py
@@ -1,2 +1,3 @@
 def format_stuck():
+    ids = packet.test_ids
     return ids
"""
        self.assertEqual(check_diff_denylist(diff), [])


class PathGuardTests(unittest.TestCase):
    def test_detects_app_edit(self):
        hits = path_guard_violations(
            ["scripts/a.py", "PodWash/PodWash/App.swift"],
            baseline=[],
        )
        self.assertEqual(hits, ["PodWash/PodWash/App.swift"])

    def test_ignores_baseline_dirty(self):
        hits = path_guard_violations(
            ["PodWash/PodWash/App.swift"],
            baseline=["PodWash/PodWash/App.swift"],
        )
        self.assertEqual(hits, [])

    def test_filter_medic_delta(self):
        delta = filter_medic_delta(
            ["scripts/a.py", "PodWash/PodWash/X.swift", "README.md"],
            baseline=[],
        )
        self.assertEqual(delta, ["scripts/a.py"])


class FilesScopeTests(unittest.TestCase):
    def test_scripts_ok(self):
        self.assertEqual(check_files_scripts_only(["scripts/foo.py"]), [])

    def test_docs_forge_ok(self):
        self.assertEqual(
            check_files_scripts_only(["docs/forge/medic-reports/x.md"]), []
        )


class RegressionIdTests(unittest.TestCase):
    def test_resolve(self):
        mod, qual = resolve_regression_unittest(
            "scripts.test_factory_hardening.HardTests.test_x"
        )
        self.assertEqual(mod, "scripts.test_factory_hardening")
        self.assertEqual(qual, "HardTests.test_x")


class ModelPinTests(unittest.TestCase):
    def test_medic_roles_models(self):
        self.assertEqual(model_for_role(MEDIC_DIAGNOSE_ROLE), "grok-4.5")
        self.assertEqual(model_for_role(MEDIC_CRITIC_ROLE), "composer-2.5")
        self.assertEqual(model_for_role(MEDIC_IMPLEMENT_ROLE), "grok-4.5")
        self.assertEqual(mode_for_role(MEDIC_DIAGNOSE_ROLE), "plan")
        self.assertEqual(mode_for_role(MEDIC_CRITIC_ROLE), "plan")
        self.assertEqual(mode_for_role(MEDIC_IMPLEMENT_ROLE), "agent")

    def test_no_fast_models(self):
        for role in MEDIC_ROLES:
            mid = ROLE_MODELS[role]
            self.assertNotIn(mid, FORBIDDEN_MODEL_IDS)
            sel = sdk_model_from_id(mid)
            self.assertIsInstance(sel, dict)
            self.assertEqual(sel["params"][0]["value"], "false")


class ReportTests(unittest.TestCase):
    def test_write_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            plan = DiagnosePlan(
                lane="messaging",
                halt_signature="sig",
                root_cause="opaque halt",
                harden_plan=["fix console"],
                files=["scripts/a.py"],
                regression_test="scripts.test_a.T.test_x",
                console_upgrade="MEDIC: x",
                plain_summary={"what_broke": "lied"},
            )
            path = write_medic_report(
                tmp,
                slice_id=16,
                signature="sig",
                plan=plan,
                outcome="healed",
            )
            self.assertTrue(os.path.isfile(path))
            with open(path, encoding="utf-8") as fh:
                body = fh.read()
            self.assertIn("opaque halt", body)
            self.assertIn("messaging", body)


class CanaryTests(unittest.TestCase):
    def test_canary_fail_before_pass_after(self):
        """New test fails on pre-fix production code, passes after."""
        from forge_medic import run_regression_canary

        with tempfile.TemporaryDirectory() as tmp:
            scripts = os.path.join(tmp, "scripts")
            os.makedirs(scripts)
            # Minimal package layout for unittest
            with open(os.path.join(scripts, "__init__.py"), "w") as fh:
                fh.write("")

            # Pre-fix production: returns "bad"
            prod = os.path.join(scripts, "demo_mod.py")
            with open(prod, "w") as fh:
                fh.write('VALUE = "bad"\n')

            # Init git so git show works
            subprocess_run = __import__("subprocess").run
            subprocess_run(["git", "init"], cwd=tmp, capture_output=True)
            subprocess_run(["git", "config", "user.email", "t@t"], cwd=tmp, capture_output=True)
            subprocess_run(["git", "config", "user.name", "t"], cwd=tmp, capture_output=True)
            subprocess_run(["git", "add", "scripts"], cwd=tmp, capture_output=True)
            subprocess_run(
                ["git", "commit", "-m", "base"], cwd=tmp, capture_output=True
            )
            pre = subprocess_run(
                ["git", "rev-parse", "HEAD"],
                cwd=tmp,
                capture_output=True,
                text=True,
            ).stdout.strip()

            # Post-fix: production fixed + new test
            with open(prod, "w") as fh:
                fh.write('VALUE = "good"\n')
            test_path = os.path.join(scripts, "test_demo_mod.py")
            with open(test_path, "w") as fh:
                fh.write(
                    "import unittest\n"
                    "import demo_mod\n"
                    "class T(unittest.TestCase):\n"
                    "    def test_value(self):\n"
                    "        self.assertEqual(demo_mod.VALUE, 'good')\n"
                )

            ok, msg = run_regression_canary(
                tmp,
                pre_sha=pre,
                regression_test="scripts.test_demo_mod.T.test_value",
                medic_paths=["scripts/demo_mod.py", "scripts/test_demo_mod.py"],
            )
            self.assertTrue(ok, msg)

    def test_canary_rejects_tautology(self):
        from forge_medic import run_regression_canary

        with tempfile.TemporaryDirectory() as tmp:
            scripts = os.path.join(tmp, "scripts")
            os.makedirs(scripts)
            with open(os.path.join(scripts, "__init__.py"), "w") as fh:
                fh.write("")
            with open(os.path.join(scripts, "demo_mod.py"), "w") as fh:
                fh.write('VALUE = "good"\n')
            subprocess_run = __import__("subprocess").run
            subprocess_run(["git", "init"], cwd=tmp, capture_output=True)
            subprocess_run(["git", "config", "user.email", "t@t"], cwd=tmp, capture_output=True)
            subprocess_run(["git", "config", "user.name", "t"], cwd=tmp, capture_output=True)
            subprocess_run(["git", "add", "scripts"], cwd=tmp, capture_output=True)
            subprocess_run(
                ["git", "commit", "-m", "base"], cwd=tmp, capture_output=True
            )
            pre = subprocess_run(
                ["git", "rev-parse", "HEAD"],
                cwd=tmp,
                capture_output=True,
                text=True,
            ).stdout.strip()

            # Tautological test that always passes even on "old" tree
            # (production unchanged; only add always-true test)
            test_path = os.path.join(scripts, "test_demo_mod.py")
            with open(test_path, "w") as fh:
                fh.write(
                    "import unittest\n"
                    "class T(unittest.TestCase):\n"
                    "    def test_value(self):\n"
                    "        self.assertTrue(True)\n"
                )

            ok, msg = run_regression_canary(
                tmp,
                pre_sha=pre,
                regression_test="scripts.test_demo_mod.T.test_value",
                medic_paths=["scripts/test_demo_mod.py"],
            )
            self.assertFalse(ok)
            self.assertIn("fake regression", msg)


class HealOrchestrationTests(unittest.TestCase):
    def test_lane_test_skips_implement(self):
        from forge_medic import run_medic_heal

        diagnose_json = {
            "lane": "test",
            "halt_signature": "deadbeefcafe",
            "root_cause": "real XCTest assert failure",
            "harden_plan": [],
            "files": [],
            "regression_test": "scripts.test_x.T.test_y",
            "console_upgrade": "",
            "plain_summary": {"what_broke": "slice red"},
        }

        def worker(role: str, prompt: str):
            if role == MEDIC_DIAGNOSE_ROLE:
                return True, "finished", f"```json\n{json.dumps(diagnose_json)}\n```"
            self.fail(f"unexpected role {role}")
            return False, "x", ""

        with tempfile.TemporaryDirectory() as tmp:
            # Minimal halt bundle
            bundle = os.path.join(tmp, "build", "test-results", "session-slice-07")
            os.makedirs(bundle)
            halt = {
                "slice": 7,
                "phase": "HALT",
                "reason": "thrash",
                "failures": ["Foo/testBar()"],
                "verify_result": {"class": "tests"},
                "extra": {"halt_kind": "no_progress"},
            }
            with open(os.path.join(bundle, "halt.json"), "w") as fh:
                json.dump(halt, fh)

            # Fake git rev-parse
            with mock.patch("forge_medic.subprocess.run") as run_mock:
                def _run(cmd, **kwargs):
                    m = mock.Mock()
                    m.returncode = 0
                    m.stdout = "abc123\n"
                    m.stderr = ""
                    if cmd[:2] == ["git", "rev-parse"]:
                        return m
                    if cmd[:2] == ["git", "status"]:
                        m.stdout = ""
                        return m
                    return m

                run_mock.side_effect = _run
                result = run_medic_heal(
                    repo_root=tmp,
                    exit_code=5,
                    slice_id=7,
                    worker=worker,
                    do_commit=False,
                    do_push=False,
                    log=lambda _m: None,
                )
            self.assertFalse(result.ok)
            self.assertEqual(result.outcome, "lane_test")
            self.assertTrue(result.report_path)
            self.assertTrue(os.path.isfile(result.report_path))


if __name__ == "__main__":
    unittest.main()
