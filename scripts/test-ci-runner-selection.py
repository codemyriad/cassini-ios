#!/usr/bin/env python3
"""Verify CI self-hosted macOS runner selection enforces the 4-event trusted allow-list."""

from __future__ import annotations

import json
import pathlib
import re
import unittest
from types import SimpleNamespace

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github/workflows"
CM_MAC_M4 = ["self-hosted", "macOS", "ARM64", "cm-mac-m4"]
EVENT_ALLOWLIST = (
    r"\(github\.event_name == 'push' \|\| github\.event_name == 'schedule' \|\| "
    r"github\.event_name == 'workflow_dispatch' \|\| "
    r"\(github\.event_name == 'pull_request' && "
    r"github\.event\.pull_request\.head\.repo\.full_name == github\.repository\)\)"
)
RUNNER_SELECTOR = re.compile(
    rf"^\$\{{\{{ {EVENT_ALLOWLIST} && vars\.CM_MAC_RUNNER == 'cm-mac-m4' && "
    r"fromJSON\('(?P<labels>\[\"self-hosted\",\"macOS\",\"ARM64\",\"cm-mac-m4\"\])'\) \|\| "
    r"'(?P<default>xcode-27)' \}\}$"
)
HOSTED_IMAGE = re.compile(r"^(?:ubuntu|macos|windows|xcode)-[0-9a-z.-]+$")


class _CIString(str):
    """GitHub Actions string comparison (`==` / `!=`) is case-insensitive."""

    def __eq__(self, other: object) -> bool:
        return isinstance(other, str) and self.casefold() == other.casefold()

    def __ne__(self, other: object) -> bool:
        return not self.__eq__(other)


class _NullContext:
    """GitHub Actions dereferences missing/null context properties to null instead of raising."""

    def __getattr__(self, _name: str) -> _NullContext:
        return self

    def __bool__(self) -> bool:
        return False


_NULL = _NullContext()


def job_runs_on_values():
    for workflow in sorted(WORKFLOWS.glob("*.yml")):
        text = workflow.read_text(encoding="utf-8")
        if "\njobs:\n" not in text:
            continue
        body = text.split("\njobs:\n", 1)[1]
        for block in re.split(r"\n(?=  [A-Za-z0-9_-]+:\n)", "\n" + body):
            job_match = re.match(r"\s*([A-Za-z0-9_-]+):\n", block)
            if not job_match:
                continue
            lines = block.splitlines()
            for i, line in enumerate(lines):
                if match := re.match(r"^    runs-on:(.*)$", line):
                    value = [match.group(1).strip()]
                    for following in lines[i + 1 :]:
                        if not following.startswith("      "):
                            break
                        value.append(following.strip())
                    yield workflow.name, job_match.group(1), "\n".join(v for v in value if v)


def select_runner(
    runs_on: str,
    variables: dict[str, str],
    *,
    event_name: str = "push",
    head_repo: str | None = "codemyriad/cassini-ios",
    repository: str = "codemyriad/cassini-ios",
):
    if not (runs_on.startswith("${{") and runs_on.endswith("}}")):
        return runs_on
    expr = runs_on.removeprefix("${{").removesuffix("}}").strip()
    expr = expr.replace("&&", " and ").replace("||", " or ")
    repo_obj = _NULL if head_repo is None else SimpleNamespace(full_name=_CIString(head_repo))
    event = SimpleNamespace(pull_request=SimpleNamespace(head=SimpleNamespace(repo=repo_obj)))
    github = SimpleNamespace(
        event_name=_CIString(event_name),
        repository=_CIString(repository),
        event=event if event_name in ("pull_request", "pull_request_target") else _NULL,
    )
    vars_ns = SimpleNamespace(CM_MAC_RUNNER=_CIString(variables.get("CM_MAC_RUNNER") or ""))
    return eval(expr, {"__builtins__": {}}, {"github": github, "vars": vars_ns, "fromJSON": json.loads})


class CiRunnerSelectionTests(unittest.TestCase):
    def test_every_runs_on_is_a_hosted_image_or_the_guarded_selector(self):
        seen = list(job_runs_on_values())
        self.assertEqual(
            [(wf, job) for wf, job, _ in seen],
            [
                ("ci.yml", "harness"),
                ("ci.yml", "fast-and-build"),
                ("daily-testflight.yml", "testflight"),
            ],
        )
        for wf, job, value in seen:
            with self.subTest(workflow=wf, job=job):
                if (wf, job) == ("daily-testflight.yml", "testflight"):
                    self.assertEqual(value, "[self-hosted, macOS, ARM64, cassini-ios-release-drmeyers]")
                else:
                    self.assertTrue(HOSTED_IMAGE.match(value) or RUNNER_SELECTOR.match(value), value)
                self.assertNotIn("fromJSON(vars", value)

    def test_signing_job_only_accepts_main_manual_dispatch_in_the_canonical_repository(self):
        text = (WORKFLOWS / "daily-testflight.yml").read_text()
        self.assertRegex(text, r"(?m)^on:\n  workflow_dispatch:\n")
        guard = re.search(r"(?m)^    if: (.+)$", text).group(1).replace("&&", " and ")
        for event in ["workflow_dispatch", "push", "schedule", "pull_request", "pull_request_target", "workflow_run"]:
            for ref in ["refs/heads/main", "refs/heads/feature", "refs/pull/123/merge"]:
                for repository in ["codemyriad/cassini-ios", "fork/cassini-ios"]:
                    github = SimpleNamespace(event_name=event, ref=ref, repository=repository)
                    actual = eval(guard, {"__builtins__": {}}, {"github": github})
                    self.assertEqual(actual, event == "workflow_dispatch" and ref == "refs/heads/main"
                                     and repository == "codemyriad/cassini-ios")

    def test_selector_routes_only_allowlisted_trusted_events_to_self_hosted(self):
        for wf, job, value in job_runs_on_values():
            if wf != "ci.yml":
                continue  # Dedicated signing workflow is checked above.
            where = f"{wf}:{job}"
            for event_name, head_repo in (
                ("push", None),
                ("schedule", None),
                ("workflow_dispatch", None),
                ("pull_request", "codemyriad/cassini-ios"),
            ):
                for setting in (
                    None,
                    "",
                    " ",
                    "garbage{",
                    '["self-hosted","macOS","ARM64","cm-mac-m4"]',
                    "cm-mac-m4-typo",
                    "github",
                    "xcode-27",
                ):
                    variables = {} if setting is None else {"CM_MAC_RUNNER": setting}
                    with self.subTest(where=where, event=event_name, value=setting):
                        self.assertEqual(
                            select_runner(value, variables, event_name=event_name, head_repo=head_repo),
                            "xcode-27",
                        )
                for setting in ("cm-mac-m4", "CM-MAC-M4"):
                    with self.subTest(where=where, event=event_name, value=setting):
                        self.assertEqual(
                            select_runner(value, {"CM_MAC_RUNNER": setting}, event_name=event_name, head_repo=head_repo),
                            CM_MAC_M4,
                        )
            for untrusted_head in ("fork/cassini-ios", "codemyriad/other-repo", "", None):
                with self.subTest(where=where, untrusted_head=untrusted_head):
                    self.assertEqual(
                        select_runner(
                            value,
                            {"CM_MAC_RUNNER": "cm-mac-m4"},
                            event_name="pull_request",
                            head_repo=untrusted_head,
                        ),
                        "xcode-27",
                    )
            for prohibited_event in (
                "pull_request_target",
                "workflow_run",
                "issue_comment",
                "pull_request_review",
                "pull_request_review_comment",
                "discussion_comment",
                "release",
                "merge_group",
            ):
                with self.subTest(where=where, event=prohibited_event):
                    self.assertEqual(
                        select_runner(
                            value,
                            {"CM_MAC_RUNNER": "cm-mac-m4"},
                            event_name=prohibited_event,
                            head_repo="codemyriad/cassini-ios",
                        ),
                        "xcode-27",
                    )

    def test_perf_gate_schedule_and_labeled_isolation_contract(self):
        ci_text = (WORKFLOWS / "ci.yml").read_text(encoding="utf-8")
        self.assertIn("cron: '53 2 * * *'", ci_text)
        self.assertIn("types: [opened, synchronize, reopened, labeled]", ci_text)
        self.assertNotIn("label-gate", ci_text)
        self.assertFalse((ROOT / "scripts/ci-label-gate.py").exists())
        self.assertIn("scripts/test.sh app", ci_text)
        self.assertNotIn('"$HOME/bin/heavy-run"', ci_text)
        self.assertIn("CASSINI_LOCK_MINUTES: '15'", ci_text)
        self.assertIn('(CASSINI_PERF_GATE=1)" DerivedData.noindex/test-logs/hosted.log', ci_text)
        self.assertLess(
            ci_text.index("uses: actions/upload-artifact@v5"),
            ci_text.index("- name: Remove only this run's simulator clones"),
        )

        test_sh = (ROOT / "scripts/test.sh").read_text(encoding="utf-8")
        self.assertIn('export TEST_RUNNER_CASSINI_PERF_GATE="$CASSINI_PERF_GATE"', test_sh)
        self.assertIn("unset TEST_RUNNER_CASSINI_PERF_GATE", test_sh)

        group_expr = re.search(r"(?m)^  group: ci-\$\{\{ (.+) \}\}$", ci_text).group(1)
        cancel_expr = re.search(r"(?m)^  cancel-in-progress: \$\{\{ (.+) \}\}$", ci_text).group(1)
        perf_expr = re.search(r"(?m)^  CASSINI_PERF_GATE: \$\{\{ (.+) \}\}$", ci_text).group(1)

        def parse_jobs(text: str) -> dict[str, tuple[list[str], str]]:
            body = text.split("\njobs:\n", 1)[1]
            jobs: dict[str, tuple[list[str], str]] = {}
            for block in re.split(r"\n(?=  [A-Za-z0-9_-]+:\n)", "\n" + body):
                job_match = re.match(r"\s*([A-Za-z0-9_-]+):\n", block)
                if not job_match:
                    continue
                needs: list[str] = []
                if needs_match := re.search(r"(?m)^    needs:\s*(.+)$", block):
                    raw = needs_match.group(1).strip()
                    if raw.startswith("[") and raw.endswith("]"):
                        needs = [item.strip() for item in raw[1:-1].split(",") if item.strip()]
                    else:
                        needs = [raw]
                cond = "success()"
                if if_match := re.search(r"(?m)^    if:\s*(.+)$", block):
                    raw_if = if_match.group(1).strip().removeprefix("${{").removesuffix("}}").strip()
                    has_status_fn = bool(re.search(r"\b(?:always|cancelled|failure|success)\s*\(", raw_if))
                    cond = raw_if if has_status_fn else f"success() && ({raw_if})"
                jobs[job_match.group(1)] = (needs, cond)
            return jobs

        def eval_gha(expr: str, *, event_name: str, action: str = "", added_label: str = "",
                     labels: tuple[str, ...] = (), pr_number: int = 123, run_id: int = 999,
                     needs_results: dict[str, str] | None = None):
            py_expr = expr.replace("&&", " and ").replace("||", " or ")
            py_expr = re.sub(r"!(?!=)", "not ", py_expr)
            py_expr = py_expr.replace("github.event.pull_request.labels.*.name", "pr_label_names")
            pr = (
                SimpleNamespace(number=pr_number)
                if event_name == "pull_request"
                else _NULL
            )
            label_obj = SimpleNamespace(name=_CIString(added_label)) if added_label else _NULL
            event = SimpleNamespace(
                action=_CIString(action) if action else _NULL,
                label=label_obj,
                pull_request=pr,
            )
            github = SimpleNamespace(
                event_name=_CIString(event_name),
                run_id=run_id,
                event=event if event_name == "pull_request" else _NULL,
            )
            needs_ns = SimpleNamespace(
                **{k.replace("-", "_"): SimpleNamespace(result=_CIString(v)) for k, v in (needs_results or {}).items()}
            )
            py_expr = re.sub(
                r"needs\.([A-Za-z0-9_-]+)\.result",
                lambda m: f"needs.{m.group(1).replace('-', '_')}.result",
                py_expr,
            )

            def contains(haystack, needle):
                if haystack is _NULL:
                    return False
                return any(_CIString(item) == needle for item in haystack)

            env = {
                "github": github,
                "needs": needs_ns,
                "pr_label_names": tuple(_CIString(lbl) for lbl in labels) if event_name == "pull_request" else _NULL,
                "contains": contains,
                "format": lambda fmt, *args: fmt.format(*args),
                "always": lambda: True,
                "cancelled": lambda: False,
                "failure": lambda: any(v == "failure" for v in (needs_results or {}).values()),
                "success": lambda: all(v == "success" for v in (needs_results or {}).values()),
            }
            return eval(py_expr, {"__builtins__": {}}, env)

        def simulate_dag(jobs: dict[str, tuple[list[str], str]], **ctx) -> set[str]:
            results: dict[str, str] = {}
            for job_id, (needs, cond) in jobs.items():
                need_map = {n: results[n] for n in needs}
                active = bool(eval_gha(cond, needs_results=need_map, **ctx))
                results[job_id] = "success" if active else "skipped"
            return {job_id for job_id, res in results.items() if res == "success"}

        ci_jobs = parse_jobs(ci_text)
        self.assertEqual(set(ci_jobs), {"harness", "fast-and-build"})

        # Regression: prove the simulator catches skipped-ancestor bugs (Android #192 class).
        broken_dag = {
            "gate": ([], "success() && (github.event_name == 'pull_request' && github.event.action == 'labeled')"),
            "downstream": (["gate"], "success() && (github.event_name == 'push' || github.event_name == 'pull_request')"),
        }
        self.assertEqual(simulate_dag(broken_dag, event_name="push"), set())

        # 1. Unlabeled PR (opened / synchronize / reopened)
        for action in ("opened", "synchronize", "reopened"):
            self.assertEqual(
                simulate_dag(ci_jobs, event_name="pull_request", action=action),
                {"harness", "fast-and-build"},
            )
            self.assertEqual("ci-" + eval_gha(group_expr, event_name="pull_request", action=action), "ci-pr-123")
            self.assertTrue(bool(eval_gha(cancel_expr, event_name="pull_request", action=action)))
            self.assertEqual(eval_gha(perf_expr, event_name="pull_request", action=action), "")

        # 2. Labeled PR with full-ci: isolated non-cancelling group, full DAG runs, CASSINI_PERF_GATE == '1'
        self.assertEqual(
            simulate_dag(
                ci_jobs,
                event_name="pull_request",
                action="labeled",
                added_label="full-ci",
                labels=("full-ci",),
            ),
            {"harness", "fast-and-build"},
        )
        self.assertEqual(
            "ci-" + eval_gha(group_expr, event_name="pull_request", action="labeled", added_label="full-ci", run_id=777),
            "ci-pr-123-label-777",
        )
        self.assertFalse(bool(eval_gha(cancel_expr, event_name="pull_request", action="labeled", added_label="full-ci")))
        self.assertEqual(
            eval_gha(perf_expr, event_name="pull_request", action="labeled", added_label="full-ci", labels=("full-ci",)),
            "1",
        )

        # 3. Labeled PR with unrelated label: isolated non-cancelling group, zero jobs run
        self.assertEqual(
            simulate_dag(
                ci_jobs,
                event_name="pull_request",
                action="labeled",
                added_label="docs",
                labels=("docs",),
            ),
            set(),
        )
        self.assertFalse(bool(eval_gha(cancel_expr, event_name="pull_request", action="labeled", added_label="docs")))

        # 4. Push to main, nightly schedule, and workflow_dispatch: full DAG runs, never cancelled
        for event_name, expected_perf in (("push", ""), ("schedule", "1"), ("workflow_dispatch", "1")):
            self.assertEqual(simulate_dag(ci_jobs, event_name=event_name), {"harness", "fast-and-build"})
            self.assertEqual("ci-" + eval_gha(group_expr, event_name=event_name, run_id=555), "ci-run-555")
            self.assertFalse(bool(eval_gha(cancel_expr, event_name=event_name)))
            self.assertEqual(eval_gha(perf_expr, event_name=event_name), expected_perf)


if __name__ == "__main__":
    unittest.main()
