#!/usr/bin/env python3
"""Offline regression tests for scripts/devicefarm-qualify.py (D-1126, D89 budget guard)."""

from __future__ import annotations

import datetime as dt
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("devicefarm_qualify", ROOT / "scripts/devicefarm-qualify.py")
assert SPEC is not None and SPEC.loader is not None
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class FakeDeviceFarm:
    def __init__(self, run_pages: list[dict], pool_pages: list[dict] | None = None) -> None:
        self.run_pages = run_pages
        self.pool_pages = pool_pages or []
        self.list_runs_calls: list[dict] = []
        self.list_pools_calls: list[dict] = []

    def list_runs(self, **kwargs) -> dict:
        self.list_runs_calls.append(dict(kwargs))
        token = kwargs.get("nextToken")
        idx = 0 if token is None else int(token)
        return self.run_pages[idx]

    def list_device_pools(self, **kwargs) -> dict:
        self.list_pools_calls.append(dict(kwargs))
        token = kwargs.get("nextToken")
        idx = 0 if token is None else int(token)
        return self.pool_pages[idx]

    def create_device_pool(self, **kwargs) -> dict:
        raise AssertionError("create_device_pool should not be called when pool exists on a later page")


class DeviceFarmBudgetGuardTests(unittest.TestCase):
    def test_budget_guard_follows_next_token_and_denies_when_later_page_crosses_limit(self) -> None:
        now = dt.datetime(2026, 11, 20, 12, 0, tzinfo=dt.timezone.utc)
        # Page 1: 100 metered min ($17.00); Page 2: 900 metered min ($153.00) -> total $170.00 >= $160.00.
        df = FakeDeviceFarm(
            run_pages=[
                {
                    "runs": [{"created": now, "deviceMinutes": {"metered": 100.0}}],
                    "nextToken": "1",
                },
                {
                    "runs": [{"created": now, "deviceMinutes": {"metered": 900.0}}],
                },
            ]
        )
        with self.assertRaises(SystemExit) as ctx:
            MOD.check_budget(df, now=now)
        self.assertIn("170.00", str(ctx.exception))
        self.assertEqual(len(df.list_runs_calls), 2)
        self.assertNotIn("nextToken", df.list_runs_calls[0])
        self.assertEqual(df.list_runs_calls[1].get("nextToken"), "1")

    def test_budget_guard_sums_current_month_across_pages_and_ignores_prior_months(self) -> None:
        now = dt.datetime(2026, 11, 20, 12, 0, tzinfo=dt.timezone.utc)
        prior_month = dt.datetime(2026, 10, 31, 23, 59, tzinfo=dt.timezone.utc)
        df = FakeDeviceFarm(
            run_pages=[
                {
                    "runs": [
                        {"created": now, "deviceMinutes": {"metered": 100.0}},
                        {"created": prior_month, "deviceMinutes": {"metered": 1000.0}},
                    ],
                    "nextToken": "1",
                },
                {
                    "runs": [
                        {"created": now, "deviceMinutes": {"metered": 200.0}},
                        {"created": now, "deviceMinutes": {"metered": None}},
                    ],
                },
            ]
        )
        spent = MOD.check_budget(df, now=now)
        self.assertAlmostEqual(spent, 300.0 * MOD.RATE_PER_MINUTE, places=6)
        self.assertEqual(len(df.list_runs_calls), 2)

    def test_budget_guard_denies_at_exact_ceiling(self) -> None:
        self.assertEqual(MOD.MONTHLY_DENY_USD, 160.0)
        now = dt.datetime(2026, 11, 20, 12, 0, tzinfo=dt.timezone.utc)
        exact_minutes = MOD.MONTHLY_DENY_USD / MOD.RATE_PER_MINUTE
        df = FakeDeviceFarm(
            run_pages=[{"runs": [{"created": now, "deviceMinutes": {"metered": exact_minutes}}]}]
        )
        with self.assertRaises(SystemExit):
            MOD.check_budget(df, now=now)

    def test_ensure_device_pool_paginates(self) -> None:
        df = FakeDeviceFarm(
            run_pages=[],
            pool_pages=[
                {"devicePools": [{"name": "other", "arn": "arn:other"}], "nextToken": "1"},
                {
                    "devicePools": [
                        {
                            "name": "target",
                            "arn": "arn:target",
                            "rules": [{"attribute": "ARN", "operator": "IN", "value": '["arn:device"]'}],
                        }
                    ]
                },
            ],
        )
        arn = MOD.ensure_device_pool(df, "target", "arn:device")
        self.assertEqual(arn, "arn:target")
        self.assertEqual(len(df.list_pools_calls), 2)

    def test_ensure_device_pool_fails_fast_on_device_arn_mismatch(self) -> None:
        df = FakeDeviceFarm(
            run_pages=[],
            pool_pages=[
                {
                    "devicePools": [
                        {
                            "name": "target",
                            "arn": "arn:target",
                            "rules": [{"attribute": "ARN", "operator": "IN", "value": '["arn:different-device"]'}],
                        }
                    ]
                }
            ],
        )
        with self.assertRaises(SystemExit) as ctx:
            MOD.ensure_device_pool(df, "target", "arn:requested-device")
        self.assertIn("arn:requested-device", str(ctx.exception))
        self.assertIn("target", str(ctx.exception))

    def test_validate_filter_rejects_long_lane_without_enable_flag(self) -> None:
        base_cfg = {
            "shortSeconds": 300,
            "longSeconds": 1800,
            "runParakeet": True,
            "runWhistle": True,
            "runLongParakeet": False,
            "runLongWhistle": False,
        }
        with self.assertRaises(SystemExit) as ctx:
            MOD.validate_filter_and_config(
                "HandsetQualificationTests/test03ThirtyMinuteContinuousParakeet",
                base_cfg,
            )
        self.assertIn("--long-parakeet", str(ctx.exception))

        with self.assertRaises(SystemExit) as ctx:
            MOD.validate_filter_and_config(
                "HandsetQualificationTests/test04ThirtyMinuteContinuousWhistle",
                base_cfg,
            )
        self.assertIn("--long-whistle", str(ctx.exception))

        both_disabled = dict(base_cfg, runParakeet=False, runWhistle=False)
        with self.assertRaises(SystemExit):
            MOD.validate_filter_and_config(
                "HandsetQualificationTests/test02PairedEquivalenceAnd5MinMetrics",
                both_disabled,
            )
        # Class selectors expand to include test02, so --no-parakeet --no-whistle must also be rejected.
        for class_filter in ("HandsetQualificationTests", "CassiniTests/HandsetQualificationTests"):
            with self.assertRaises(SystemExit) as ctx:
                MOD.validate_filter_and_config(class_filter, both_disabled)
            self.assertIn("test02PairedEquivalenceAnd5MinMetrics", str(ctx.exception))

        # Unknown / misspelled selectors must fail fast even alongside a valid contract test selector.
        with self.assertRaises(SystemExit) as typo_ctx:
            MOD.validate_filter_and_config(
                "HandsetQualificationTests/testQualificationHarnessAndTelemetryContract,"
                "HandsetQualificationTests/test03ThirtyMinuteContinuousParakeeet",
                dict(base_cfg, runLongParakeet=True),
            )
        self.assertIn("Unknown or misspelled", str(typo_ctx.exception))

    def test_verify_reports_rejects_test02_with_no_enabled_engines(self) -> None:
        both_disabled = {
            "shortSeconds": 300,
            "longSeconds": 1800,
            "runParakeet": False,
            "runWhistle": False,
            "runLongParakeet": False,
            "runLongWhistle": False,
        }
        with self.assertRaises(SystemExit):
            MOD.verify_reports(
                [{"test": "test02PairedEquivalenceAnd5MinMetrics"}],
                [("test02PairedEquivalenceAnd5MinMetrics", None)],
                both_disabled,
            )

    def test_verify_reports_fails_when_passed_run_is_missing_expected_report(self) -> None:
        cfg = {
            "shortSeconds": 300,
            "longSeconds": 1800,
            "runParakeet": True,
            "runWhistle": True,
            "runLongParakeet": True,
            "runLongWhistle": False,
        }
        expected = MOD.validate_filter_and_config(
            "HandsetQualificationTests/test03ThirtyMinuteContinuousParakeet",
            cfg,
        )
        self.assertEqual(expected, [("runThirtyMinuteContinuousCapture", "parakeet")])

        with self.assertRaises(SystemExit) as empty_ctx:
            MOD.verify_reports([], expected, cfg)
        self.assertIn("0 qualification reports", str(empty_ctx.exception))

        with self.assertRaises(SystemExit) as wrong_engine_ctx:
            MOD.verify_reports(
                [{"test": "runThirtyMinuteContinuousCapture", "engine": "whistle"}],
                expected,
                cfg,
            )
        self.assertIn("parakeet", str(wrong_engine_ctx.exception))

        # Succeeds when the expected report is present.
        MOD.verify_reports(
            [{"test": "runThirtyMinuteContinuousCapture", "engine": "parakeet"}],
            expected,
            cfg,
        )

    def test_resolve_run_output_dir_rejects_path_traversal(self) -> None:
        base_out = ROOT / "DerivedData.noindex/devicefarm-out"
        for bad_name in ("../escape", "/tmp/escape", "a/b", "a\\b", "..", ".", ""):
            with self.assertRaises(SystemExit, msg=f"Expected rejection for --name {bad_name!r}"):
                MOD.resolve_run_output_dir(base_out, bad_name)

        valid = MOD.resolve_run_output_dir(base_out, "d1126-iphone14pro-5min-v3")
        self.assertEqual(valid, (base_out.resolve() / "d1126-iphone14pro-5min-v3"))
        self.assertTrue(valid.is_relative_to(base_out.resolve()))


if __name__ == "__main__":
    unittest.main()
