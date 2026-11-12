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
        self.assertEqual([(wf, job) for wf, job, _ in seen], [("ci.yml", "harness"), ("ci.yml", "fast-and-build"), ("daily-testflight.yml", "testflight"), ("simulator-gate.yml", "simulator-gate")])
        for wf, job, value in seen:
            with self.subTest(workflow=wf, job=job):
                if (wf, job) == ("daily-testflight.yml", "testflight"):
                    self.assertEqual(value, "[self-hosted, macOS, ARM64, cassini-ios-release-drmeyers]")
                elif (wf, job) == ("simulator-gate.yml", "simulator-gate"):
                    self.assertEqual(value, "[self-hosted, macOS, ARM64, cm-mac-m4]")
                else:
                    self.assertTrue(HOSTED_IMAGE.match(value) or RUNNER_SELECTOR.match(value), value)
                self.assertNotIn("fromJSON(vars", value)

    def test_simulator_job_rejects_forks_and_untrusted_events_before_checkout(self):
        text = (WORKFLOWS / "simulator-gate.yml").read_text()
        guard = re.search(r"(?m)^    if: (.+)$", text).group(1).replace("&&", " and ").replace("||", " or ")
        self.assertNotIn("pull_request_target:", text)
        for event in ["push", "workflow_dispatch", "pull_request", "schedule", "pull_request_target", "workflow_run", "issue_comment"]:
            for repo in ["codemyriad/cassini-ios", "fork/cassini-ios"]:
                for head in ["codemyriad/cassini-ios", "fork/cassini-ios", "", None]:
                    for ref in ["refs/heads/main", "refs/heads/feature", "refs/pull/123/merge"]:
                        metadata = _NULL if head is None else SimpleNamespace(full_name=head)
                        payload = SimpleNamespace(pull_request=SimpleNamespace(head=SimpleNamespace(repo=metadata)))
                        github = SimpleNamespace(event_name=event, repository=repo, ref=ref,
                                                 event=payload if event in ("pull_request", "pull_request_target") else _NULL)
                        expected = repo == "codemyriad/cassini-ios" and (
                            (event == "pull_request" and head == repo) or
                            (event in ("push", "workflow_dispatch") and ref == "refs/heads/main"))
                        with self.subTest(event=event, repo=repo, head=head, ref=ref):
                            self.assertEqual(bool(eval(guard, {"__builtins__": {}}, {"github": github})), expected)

    def test_simulator_gate_keeps_coverage_and_has_no_release_or_status_privileges(self):
        text = (WORKFLOWS / "simulator-gate.yml").read_text()
        self.assertRegex(text, r"(?m)^permissions:\n  contents: read\n")
        for prohibited in ["secrets.", "GH_TOKEN:", "GITHUB_TOKEN:", "statuses: write", "id-token:",
                           "altool", "testflight.py", "archive.py", "-allowProvisioningUpdates", "security ", "sudo "]:
            self.assertNotIn(prohibited, text)
        for line in ["CASSINI_POST_STATUS: '0'", "CASSINI_CONFORMANCE_REQUIRED: '1'", "CASSINI_IOS18: full",
                     "CASSINI_UI_IPAD: '1'", "CASSINI_KEEP_SIMS: '0'", "fetch-depth: 0"]:
            self.assertIn(line, text)
        self.assertEqual(text.count("persist-credentials: false"), 2)
        self.assertIn("github.event.pull_request.head.sha || github.sha", text)
        self.assertIn("CASSINI_SIM_PREFIX: ci-ios-${{ github.run_id }}-${{ github.run_attempt }}", text)
        self.assertIn("scripts/test.sh all", text)
        self.assertNotIn("-only-testing", text)
        self.assertNotIn("CASSINI_IOS18_RUNTIME:", text)
        self.assertRegex(text, r"(?s)Remove only this run's simulator clones\n        if: always\(\).*?scripts/test.sh clean")
        self.assertRegex(text, r"(?s)actions/upload-artifact@v5\n        if: always\(\).*?test-logs\*")

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
                continue  # Dedicated signing workflow has its stricter event/ref/repository check below.
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


if __name__ == "__main__":
    unittest.main()
