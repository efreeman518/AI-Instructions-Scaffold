#!/usr/bin/env python3
"""
Self-tests for the author-side Python tooling (stdlib only, never shipped).

Covers the three scripts everything else trusts:
  - scripts/install-to-project.py  - merge/copy/verify logic
  - scripts/validate-instructions.py - pure helpers + mutation tests proving the
    validator actually FAILS on bad input (its real job)
  - tests/golden-path/run-golden-path.py - fixture/prompt extraction, YAML
    transform, and the phase-3 gate

Usage:
    py -3 tests/tooling/run-tooling-tests.py           # full run
    py -3 tests/tooling/run-tooling-tests.py --fast    # skip slow mutation tests

Exit code 0 when all tests pass, 1 otherwise.
"""

from __future__ import annotations

import importlib.util
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

REPO_ROOT = Path(__file__).resolve().parents[2]
FAST = "--fast" in sys.argv
if FAST:
    sys.argv.remove("--fast")


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


installer = load_module("installer", REPO_ROOT / "scripts" / "install-to-project.py")
validator = load_module("validator", REPO_ROOT / "scripts" / "validate-instructions.py")
reference_validator = load_module("reference_validator", REPO_ROOT / "scripts" / "validate-reference.py")
goldenpath = load_module("goldenpath", REPO_ROOT / "tests" / "golden-path" / "run-golden-path.py")


class InstallerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="tooling-inst-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def _planner(self):
        return installer.Planner(dry_run=False)

    def test_should_skip_excluded_parts(self):
        p = self._planner()
        self.assertTrue(p._should_skip(Path("__pycache__/x.pyc")))
        self.assertTrue(p._should_skip(Path("sub/tests/x.md")))
        self.assertFalse(p._should_skip(Path("skills/api.md")))

    def test_copy_file_unchanged_overwrite_and_fresh(self):
        src = self.tmp / "src.md"
        dst = self.tmp / "dst.md"
        src.write_text("same\n", encoding="utf-8")

        p = self._planner()
        p.copy_file(src, dst, "dst.md")  # fresh copy
        self.assertEqual(p.copied, 1)
        self.assertEqual(p.overwritten, [])

        p.copy_file(src, dst, "dst.md")  # identical -> skipped
        self.assertEqual(p.unchanged, 1)
        self.assertEqual(p.copied, 1)

        dst.write_text("edited in target\n", encoding="utf-8")
        p.copy_file(src, dst, "dst.md")  # differs -> overwritten + listed
        self.assertEqual(p.overwritten, ["dst.md"])
        self.assertEqual(dst.read_text(encoding="utf-8"), "same\n")

    def test_merge_file_is_idempotent(self):
        src = self.tmp / "notes.md"
        dst = self.tmp / "target-notes.md"
        src.write_text("# Managed\nmanaged body\n", encoding="utf-8")

        self._planner().merge_file(src, dst, "notes.md")
        first = dst.read_text(encoding="utf-8")
        self.assertIn(installer.MERGE_SENTINEL_START, first)
        self.assertIn("managed body", first)

        self._planner().merge_file(src, dst, "notes.md")
        second = dst.read_text(encoding="utf-8")
        self.assertEqual(first.strip(), second.strip())

    def test_merge_file_preserves_content_outside_sentinels(self):
        src = self.tmp / "notes.md"
        dst = self.tmp / "target-notes.md"
        src.write_text("new managed body\n", encoding="utf-8")
        dst.write_text(
            "user header\n\n"
            + installer.MERGE_SENTINEL_START
            + "\nold managed body\n"
            + installer.MERGE_SENTINEL_END
            + "\n\nuser footer\n",
            encoding="utf-8",
        )
        self._planner().merge_file(src, dst, "notes.md")
        merged = dst.read_text(encoding="utf-8")
        self.assertIn("user header", merged)
        self.assertIn("user footer", merged)
        self.assertIn("new managed body", merged)
        self.assertNotIn("old managed body", merged)

    def test_merge_file_appends_block_to_unmarked_existing_file(self):
        src = self.tmp / "notes.md"
        dst = self.tmp / "target-notes.md"
        src.write_text("managed body\n", encoding="utf-8")
        dst.write_text("pre-existing app instructions\n", encoding="utf-8")
        self._planner().merge_file(src, dst, "notes.md")
        merged = dst.read_text(encoding="utf-8")
        self.assertTrue(merged.startswith("pre-existing app instructions"))
        self.assertIn(installer.MERGE_SENTINEL_START, merged)

    def test_adapt_installed_entrypoint_links(self):
        adapted = installer.adapt_installed_entrypoint_links(
            Path("AGENTS.md"), "see [README.md](README.md) for detail"
        )
        self.assertIn("[.instructions/README.md](.instructions/README.md)", adapted)
        untouched = installer.adapt_installed_entrypoint_links(
            Path("skills/api.md"), "see [README.md](README.md)"
        )
        self.assertIn("[README.md](README.md)", untouched)

    def _make_complete_install(self, root: Path, scope: str = "full") -> None:
        managed_files: dict[str, str] = {}
        managed_blocks: dict[str, str] = {}
        merge_targets = {
            dst_rel for _src, dst_rel, kind in installer.AGENT_COPIES if kind == "merge"
        }
        expected = list(installer.SMOKE_CHECK_PAYLOAD)
        if scope == "full":
            expected += installer.SMOKE_CHECK_HARNESS_ENTRYPOINTS
        for rel in expected:
            p = root / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("x\n", encoding="utf-8")
            if rel not in merge_targets:
                managed_files[rel] = installer.hash_file(p)
        if scope == "full":
            for _src, dst_rel, kind in installer.AGENT_COPIES:
                if kind == "merge":
                    (root / dst_rel).write_text(
                        installer.MERGE_SENTINEL_START + "\nx\n" + installer.MERGE_SENTINEL_END + "\n",
                        encoding="utf-8",
                    )
                    managed_blocks[dst_rel] = installer.hash_bytes(b"x")
        manifest = {
            "format": installer.MANIFEST_FORMAT,
            "scope": scope,
            "sourceRepository": "https://example.test/scaffold",
            "managedFiles": managed_files,
            "managedBlocks": managed_blocks,
        }
        manifest_path = root / installer.MANIFEST_REL
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

    def test_verify_install_passes_then_detects_missing_file(self):
        root = self.tmp / "app"
        self._make_complete_install(root)
        self.assertEqual(installer.verify_install(root, instructions_only=False), 0)
        (root / ".instructions" / "START-AI.md").unlink()
        self.assertEqual(installer.verify_install(root, instructions_only=False), 1)

    def test_verify_install_detects_tampered_file(self):
        root = self.tmp / "app"
        self._make_complete_install(root)
        (root / ".instructions" / "START-AI.md").write_text("tampered\n", encoding="utf-8")
        self.assertEqual(installer.verify_install(root, instructions_only=False), 1)

    def test_verify_install_detects_missing_sentinels(self):
        root = self.tmp / "app"
        self._make_complete_install(root)
        (root / "AGENTS.md").write_text("no markers here\n", encoding="utf-8")
        self.assertEqual(installer.verify_install(root, instructions_only=False), 1)

    def test_verify_install_detects_tampered_managed_block(self):
        root = self.tmp / "app"
        self._make_complete_install(root)
        (root / "AGENTS.md").write_text(
            installer.MERGE_SENTINEL_START
            + "\ntampered\n"
            + installer.MERGE_SENTINEL_END
            + "\n",
            encoding="utf-8",
        )
        self.assertEqual(installer.verify_install(root, instructions_only=False), 1)

    def test_verify_install_ignores_user_content_and_warns_on_extra_file(self):
        root = self.tmp / "app"
        self._make_complete_install(root)
        harness = root / "AGENTS.md"
        harness.write_text("user content\n\n" + harness.read_text(encoding="utf-8"), encoding="utf-8")
        extra = root / ".instructions" / "consumer-note.md"
        extra.write_text("consumer-owned\n", encoding="utf-8")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = installer.verify_install(root, instructions_only=False)
        self.assertEqual(result, 0)
        self.assertIn("[warn]", output.getvalue())
        self.assertIn("consumer-note.md", output.getvalue())

    def test_load_manifest_rejects_unsafe_path(self):
        root = self.tmp / "app"
        manifest_path = root / installer.MANIFEST_REL
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(
            json.dumps({
                "format": installer.MANIFEST_FORMAT,
                "scope": "full",
                "sourceRepository": "https://example.test/scaffold",
                "managedFiles": {"../outside.md": "0" * 64},
                "managedBlocks": {},
            }),
            encoding="utf-8",
        )
        manifest, error = installer.load_manifest(root)
        self.assertIsNone(manifest)
        self.assertIn("invalid entry", error)

    def test_verify_install_warns_on_unmanifested_legacy_file(self):
        root = self.tmp / "app"
        self._make_complete_install(root)
        legacy = root / ".instructions" / "CLAUDE.md"
        legacy.write_text("locally owned legacy content\n", encoding="utf-8")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(installer.verify_install(root, instructions_only=False), 0)
        self.assertIn("unmanifested file(s) left untouched", output.getvalue())
        self.assertEqual(legacy.read_text(encoding="utf-8"), "locally owned legacy content\n")

    def test_plan_pruning_removes_unchanged_and_rejects_changed_file(self):
        root = self.tmp / "app"
        old = root / ".instructions" / "old.md"
        old.parent.mkdir(parents=True, exist_ok=True)
        old.write_text("old managed content\n", encoding="utf-8")
        previous = {
            "managedFiles": {".instructions/old.md": installer.hash_file(old)},
            "managedBlocks": {},
        }
        expected = {"managedFiles": {}, "managedBlocks": {}}

        removed, blocks, conflicts = installer.plan_pruning(
            root, previous, expected, instructions_only=False
        )
        self.assertEqual(removed, [".instructions/old.md"])
        self.assertEqual(blocks, [])
        self.assertEqual(conflicts, [])

        old.write_text("local edit\n", encoding="utf-8")
        removed, _blocks, conflicts = installer.plan_pruning(
            root, previous, expected, instructions_only=False
        )
        self.assertEqual(removed, [])
        self.assertEqual(conflicts, [".instructions/old.md"])

    def test_plan_pruning_handles_removed_managed_block_safely(self):
        root = self.tmp / "app"
        harness = root / "AGENTS.md"
        harness.parent.mkdir(parents=True, exist_ok=True)
        harness.write_text(
            "user content\n\n"
            + installer.MERGE_SENTINEL_START
            + "\nmanaged\n"
            + installer.MERGE_SENTINEL_END
            + "\n",
            encoding="utf-8",
        )
        previous = {
            "managedFiles": {},
            "managedBlocks": {"AGENTS.md": installer.hash_bytes(b"managed")},
        }
        expected = {"managedFiles": {}, "managedBlocks": {}}

        files, blocks, conflicts = installer.plan_pruning(
            root, previous, expected, instructions_only=False
        )
        self.assertEqual(files, [])
        self.assertEqual(blocks, ["AGENTS.md"])
        self.assertEqual(conflicts, [])

        harness.write_text(harness.read_text(encoding="utf-8").replace("managed", "local edit"), encoding="utf-8")
        _files, blocks, conflicts = installer.plan_pruning(
            root, previous, expected, instructions_only=False
        )
        self.assertEqual(blocks, [])
        self.assertEqual(conflicts, ["AGENTS.md (managed block)"])

    def test_fresh_install_passes_full_verification(self):
        app = self.tmp / "fresh"
        app.mkdir()
        with (
            mock.patch.object(
                sys,
                "argv",
                ["install-to-project.py", "--target", str(app), "--verify"],
            ),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(installer.main(), 0)

    def test_install_prunes_only_hash_matching_removed_file(self):
        app = self.tmp / "update"
        app.mkdir()
        with (
            mock.patch.object(sys, "argv", ["install-to-project.py", "--target", str(app)]),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(installer.main(), 0)

        manifest_path = app / installer.MANIFEST_REL
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        removed_rel = ".instructions/upstream-removed.md"
        removed = app / removed_rel
        removed.write_text("prior managed content\n", encoding="utf-8")
        manifest["managedFiles"][removed_rel] = installer.hash_file(removed)
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        with (
            mock.patch.object(sys, "argv", ["install-to-project.py", "--target", str(app)]),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(installer.main(), 0)
        self.assertFalse(removed.exists())

        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        conflict_rel = ".instructions/locally-changed-removed.md"
        conflict = app / conflict_rel
        conflict.write_text("prior managed content\n", encoding="utf-8")
        manifest["managedFiles"][conflict_rel] = installer.hash_file(conflict)
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        conflict.write_text("local edit\n", encoding="utf-8")
        with (
            mock.patch.object(sys, "argv", ["install-to-project.py", "--target", str(app)]),
            contextlib.redirect_stdout(io.StringIO()),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            self.assertEqual(installer.main(), 1)
        self.assertEqual(conflict.read_text(encoding="utf-8"), "local edit\n")

    def test_pre_manifest_install_creates_manifest_and_dry_run_does_not(self):
        app = self.tmp / "app"
        app.mkdir()
        legacy = app / ".instructions" / "CLAUDE.md"
        legacy.parent.mkdir()
        legacy.write_text("locally owned legacy content\n", encoding="utf-8")
        with (
            mock.patch.object(sys, "argv", ["install-to-project.py", "--target", str(app)]),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(installer.main(), 0)
        manifest, error = installer.load_manifest(app)
        self.assertIsNone(error)
        self.assertIsNotNone(manifest)
        self.assertIn(".instructions/START-AI.md", manifest["managedFiles"])
        self.assertEqual(legacy.read_text(encoding="utf-8"), "locally owned legacy content\n")

        dry = self.tmp / "dry"
        dry.mkdir()
        with (
            mock.patch.object(
                sys,
                "argv",
                ["install-to-project.py", "--target", str(dry), "--dry-run"],
            ),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(installer.main(), 0)
        self.assertFalse((dry / installer.MANIFEST_REL).exists())

    def test_verify_install_honors_manifest_scope(self):
        root = self.tmp / "scoped"
        self._make_complete_install(root, scope="instructions-only")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(installer.verify_install(root, False), 0)

    def test_instructions_only_reinstall_preserves_full_scope_records(self):
        app = self.tmp / "rescoped"
        app.mkdir()
        with (
            mock.patch.object(sys, "argv", ["install-to-project.py", "--target", str(app)]),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(installer.main(), 0)
        with (
            mock.patch.object(
                sys,
                "argv",
                ["install-to-project.py", "--target", str(app), "--instructions-only"],
            ),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(installer.main(), 0)
        manifest, error = installer.load_manifest(app)
        self.assertIsNone(error)
        self.assertEqual(manifest["scope"], "full")
        self.assertTrue(manifest["managedBlocks"])
        self.assertTrue(any(not rel.startswith(".instructions/") for rel in manifest["managedFiles"]))
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(installer.verify_install(app, False), 0)


class WorkflowStateContractTests(unittest.TestCase):
    def test_handoff_template_uses_explicit_active_terminal_contract(self):
        handoff = (REPO_ROOT / "support" / "HANDOFF.md").read_text(encoding="utf-8")
        self.assertIn("workflowStatus: active", handoff)
        self.assertIn("currentSubPhase: complete", handoff)
        self.assertNotIn("instructionVersion:", handoff)

    def test_router_checks_workflow_status_before_phase_fields(self):
        router = (REPO_ROOT / "START-AI.md").read_text(encoding="utf-8")
        status_index = router.index("Read workflowStatus first")
        phase_index = router.index("Resume from currentPhase/currentSubPhase")
        self.assertLess(status_index, phase_index)
        self.assertIn("complete -> Scaffold workflow is terminal", router)
        self.assertIn("ordinary repository maintenance", router)

    def test_golden_path_fixture_starts_active(self):
        self.assertIn("workflowStatus: active", goldenpath.HANDOFF_FIXTURE)
        self.assertNotIn("instructionVersion:", goldenpath.HANDOFF_FIXTURE)


class ReferenceValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="tooling-reference-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def _make_always_evidence(self) -> None:
        (self.tmp / "HANDOFF.md").write_text("workflowStatus: complete\n", encoding="utf-8")
        status = self.tmp / ".scaffold" / "REFERENCE-STATUS.md"
        status.parent.mkdir(parents=True, exist_ok=True)
        status.write_text(
            "- `proven`:\n- `deployment-only`:\n- `documented-only`:\n- `not enabled`:\n",
            encoding="utf-8",
        )
        for rel in reference_validator.ALWAYS_PATHS:
            p = self.tmp / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text("x", encoding="utf-8")

    def test_declared_evidence_is_flag_conditional(self):
        self._make_always_evidence()
        # Undeclared capabilities require nothing beyond the always set.
        self.assertEqual(reference_validator.check_declared_evidence(self.tmp, {}), [])
        # A declared capability without its wiring evidence is an error.
        errors = reference_validator.check_declared_evidence(
            self.tmp, {"includeKeyVault": True, "useAspire": True}
        )
        self.assertTrue(any("missing sentinel file: src/Host/Aspire/AppHost/AppHost.cs" in error for error in errors))
        apphost = self.tmp / "src" / "Host" / "Aspire" / "AppHost" / "AppHost.cs"
        apphost.parent.mkdir(parents=True, exist_ok=True)
        apphost.write_text("// no key vault wiring", encoding="utf-8")
        errors = reference_validator.check_declared_evidence(
            self.tmp, {"includeKeyVault": True, "useAspire": True}
        )
        self.assertTrue(any("AddAzureKeyVault" in error for error in errors))
        # Turning the capability off removes the requirement - no scaffold edit needed.
        self.assertEqual(
            reference_validator.check_declared_evidence(self.tmp, {"includeKeyVault": False, "useAspire": True}),
            [],
        )
        # Declared-config self-consistency is retained.
        errors = reference_validator.check_declared_evidence(
            self.tmp, {"includeNotifications": False, "notifications": [{"name": "x"}]}
        )
        self.assertTrue(any("notification entries" in error for error in errors))

    def test_markdown_links_detect_missing_tracked_target(self):
        docs = self.tmp / "docs"
        docs.mkdir()
        (docs / "ok.md").write_text("ok\n", encoding="utf-8")
        readme = self.tmp / "README.md"
        readme.write_text("[good](docs/ok.md)\n[bad](docs/missing.md)\n", encoding="utf-8")
        errors = reference_validator.check_markdown_links(self.tmp)
        self.assertEqual(len(errors), 1)
        self.assertIn("docs/missing.md", errors[0])

    def test_action_refs_require_full_sha(self):
        workflows = self.tmp / ".github" / "workflows"
        workflows.mkdir(parents=True)
        workflow = workflows / "ci.yml"
        workflow.write_text("steps:\n  - uses: actions/checkout@v7\n", encoding="utf-8")
        self.assertEqual(len(reference_validator.check_action_refs(self.tmp)), 1)
        workflow.write_text(
            "steps:\n  - uses: actions/checkout@" + "a" * 40 + " # latest stable\n",
            encoding="utf-8",
        )
        self.assertEqual(reference_validator.check_action_refs(self.tmp), [])

    def test_dependabot_config_requires_manifests_and_registries(self):
        # No config file: nothing to check (dormant guard).
        self.assertEqual(reference_validator.check_dependabot(self.tmp), [])
        gh = self.tmp / ".github"
        gh.mkdir(parents=True)
        config = gh / "dependabot.yml"
        config.write_text(
            "version: 2\n"
            "updates:\n"
            "  - package-ecosystem: npm\n"
            "    directory: /web\n"
            '  - package-ecosystem: "nuget"\n'
            '    directory: "/"\n',
            encoding="utf-8",
        )
        (self.tmp / "nuget.config").write_text(
            '<add key="private" value="https://nuget.pkg.github.com/x/index.json" />',
            encoding="utf-8",
        )
        errors = reference_validator.check_dependabot(self.tmp)
        self.assertTrue(any("no package.json" in error for error in errors))
        self.assertTrue(any("no project or packages file" in error for error in errors))
        self.assertTrue(any("registries block" in error for error in errors))

        web = self.tmp / "web"
        web.mkdir()
        (web / "package.json").write_text("{}", encoding="utf-8")
        (self.tmp / "Directory.Packages.props").write_text("<Project/>", encoding="utf-8")
        config.write_text(
            "version: 2\n"
            "registries:\n"
            "  private-feed:\n"
            "    type: nuget-feed\n"
            "updates:\n"
            "  - package-ecosystem: npm\n"
            "    directory: /web\n"
            "  - package-ecosystem: nuget\n"
            "    directory: /\n",
            encoding="utf-8",
        )
        self.assertEqual(reference_validator.check_dependabot(self.tmp), [])

    def test_proof_path_extraction_ignores_identifiers(self):
        proof = self.tmp / "proof.md"
        proof.write_text(
            "`src/Host/App`, `tests/Test.Unit/Test.Unit.csproj`, `ApplicationStyleResolver`\n",
            encoding="utf-8",
        )
        self.assertEqual(
            reference_validator.proof_paths(proof),
            ["src/Host/App", "tests/Test.Unit/Test.Unit.csproj"],
        )


class ValidatorHelperTests(unittest.TestCase):
    def _make_optional_ai_contract_root(self, root: Path) -> None:
        for rel, required in validator.OPTIONAL_AI_CONTRACT_REQUIREMENTS.items():
            path = root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            if rel == "templates/test-templates-aspire.md":
                text = (
                    "### Optional Azure LiveAI eligibility before host creation\n"
                    "var unavailable = AzureFoundryTestEligibility.GetUnavailableReason();\n"
                    "await AspireTestHost.EnsureStartedAsync(context);\n"
                    "same pure Azure-selection predicate\n\n---\n"
                )
            else:
                text = "\n".join(required) + "\n"
            path.write_text(text, encoding="utf-8")

    def _make_deployment_hardening_contract_root(self, root: Path) -> None:
        for rel, required in validator.DEPLOYMENT_HARDENING_CONTRACT_REQUIREMENTS.items():
            path = root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("\n".join(required) + "\n", encoding="utf-8")
        for rel in validator.DEPLOYMENT_HARDENING_FORBIDDEN_CLAIMS:
            path = root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            if not path.exists():
                path.write_text("current policy\n", encoding="utf-8")

    def test_optional_ai_contract_guard_requires_owner_policy_and_prehost_order(self):
        with tempfile.TemporaryDirectory(prefix="tooling-optional-ai-") as tmp:
            root = Path(tmp)
            self._make_optional_ai_contract_root(root)
            with mock.patch.object(validator, "INSTRUCTIONS_ROOT", root):
                findings = validator.Findings()
                validator.check_optional_ai_contract(findings)
                self.assertEqual(findings.errors, [])

                owner = root / "skills" / "ai-integration.md"
                owner.write_text(
                    owner.read_text(encoding="utf-8").replace(
                        "machine capacity, not a contract failure",
                        "capacity issue",
                    ),
                    encoding="utf-8",
                )
                findings = validator.Findings()
                validator.check_optional_ai_contract(findings)

            self.assertTrue(any("machine capacity" in message for _, message in findings.errors))

    def test_optional_ai_contract_guard_rejects_deprecated_failure_claim(self):
        with tempfile.TemporaryDirectory(prefix="tooling-optional-ai-") as tmp:
            root = Path(tmp)
            self._make_optional_ai_contract_root(root)
            testing = root / "skills" / "testing.md"
            testing.write_text(
                testing.read_text(encoding="utf-8")
                + "\nMissing AI configuration, runtime, or model timeout must fail red.\n",
                encoding="utf-8",
            )
            with mock.patch.object(validator, "INSTRUCTIONS_ROOT", root):
                findings = validator.Findings()
                validator.check_optional_ai_contract(findings)

            self.assertTrue(any("deprecated failure claim" in message for _, message in findings.errors))

    def test_deployment_hardening_guard_requires_wasm_interactive_policy(self):
        with tempfile.TemporaryDirectory(prefix="tooling-deployment-hardening-") as tmp:
            root = Path(tmp)
            self._make_deployment_hardening_contract_root(root)
            with mock.patch.object(validator, "INSTRUCTIONS_ROOT", root):
                findings = validator.Findings()
                validator.check_deployment_hardening_contract(findings)
                self.assertEqual(findings.errors, [])

                uno = root / "skills" / "ui-uno-mvux.md"
                uno.write_text(
                    uno.read_text(encoding="utf-8").replace(
                        "`Cross-Origin-Opener-Policy`",
                        "popup header",
                    ),
                    encoding="utf-8",
                )
                findings = validator.Findings()
                validator.check_deployment_hardening_contract(findings)

            self.assertTrue(any("Cross-Origin-Opener-Policy" in message for _, message in findings.errors))

    def test_deployment_hardening_guard_requires_release_cold_start_policy(self):
        with tempfile.TemporaryDirectory(prefix="tooling-deployment-hardening-") as tmp:
            root = Path(tmp)
            self._make_deployment_hardening_contract_root(root)
            platform = root / "skills" / "ui-uno-platforms.md"
            platform.write_text(
                platform.read_text(encoding="utf-8").replace(
                    "`BrowserRenderer.requestRender`",
                    "renderer callback",
                ),
                encoding="utf-8",
            )
            with mock.patch.object(validator, "INSTRUCTIONS_ROOT", root):
                findings = validator.Findings()
                validator.check_deployment_hardening_contract(findings)

            self.assertTrue(any("BrowserRenderer.requestRender" in message for _, message in findings.errors))

    def test_deployment_hardening_guard_rejects_ungated_local_login_claim(self):
        with tempfile.TemporaryDirectory(prefix="tooling-deployment-hardening-") as tmp:
            root = Path(tmp)
            self._make_deployment_hardening_contract_root(root)
            platform = root / "skills" / "ui-uno-platforms.md"
            platform.write_text("The development login is intentionally ungated.\n", encoding="utf-8")
            with mock.patch.object(validator, "INSTRUCTIONS_ROOT", root):
                findings = validator.Findings()
                validator.check_deployment_hardening_contract(findings)

            self.assertTrue(any("forbidden claim" in message for _, message in findings.errors))

    def test_deployment_hardening_guard_requires_deterministic_paging_policy(self):
        with tempfile.TemporaryDirectory(prefix="tooling-deployment-hardening-") as tmp:
            root = Path(tmp)
            self._make_deployment_hardening_contract_root(root)
            repository = root / "templates" / "repository-template.md"
            repository.write_text(
                repository.read_text(encoding="utf-8").replace(
                    "### Paged queries require a deterministic total order",
                    "### Paging",
                ),
                encoding="utf-8",
            )
            with mock.patch.object(validator, "INSTRUCTIONS_ROOT", root):
                findings = validator.Findings()
                validator.check_deployment_hardening_contract(findings)

            self.assertTrue(any("deterministic total order" in message for _, message in findings.errors))

    def test_deployment_hardening_guard_requires_optional_tool_policy(self):
        with tempfile.TemporaryDirectory(prefix="tooling-deployment-hardening-") as tmp:
            root = Path(tmp)
            self._make_deployment_hardening_contract_root(root)
            context = root / "support" / "context-tooling.md"
            context.write_text(
                context.read_text(encoding="utf-8").replace(
                    "never installs, enables, or requires RTK",
                    "installs RTK",
                ),
                encoding="utf-8",
            )
            with mock.patch.object(validator, "INSTRUCTIONS_ROOT", root):
                findings = validator.Findings()
                validator.check_deployment_hardening_contract(findings)

            self.assertTrue(any("never installs" in message for _, message in findings.errors))

    def test_estimate_unique_tokens_deduplicates_across_loadset_groups(self):
        with tempfile.TemporaryDirectory(prefix="tooling-loadset-") as tmp:
            base = Path(tmp) / "base.md"
            conditional = Path(tmp) / "conditional.md"
            base.write_text("x" * 40, encoding="utf-8")
            conditional.write_text("x" * 40, encoding="utf-8")

            self.assertEqual(validator._estimate_unique_tokens([base], [base]), 10)
            self.assertEqual(
                validator._estimate_unique_tokens([base], {conditional: None}, {conditional: None}),
                20,
            )

    def test_loadset_budget_deduplicates_base_required_and_on_demand(self):
        with tempfile.TemporaryDirectory(prefix="tooling-loadset-") as tmp:
            root = Path(tmp)
            skill = root / "ai" / "SKILL.md"
            shared = root / "shared" / "item.md"
            skill.parent.mkdir(parents=True)
            shared.parent.mkdir(parents=True)
            skill.write_text(
                "## Phase 5 file table\n"
                "Base context: `ai/SKILL.md`\n"
                "| Sub-phase | Skills | Templates | Load on demand |\n"
                "|---|---|---|---|\n"
                "| **5a** | `shared/item` | | `shared/item` |\n",
                encoding="utf-8",
            )
            shared.write_text("x" * 40, encoding="utf-8")
            unique_total = validator._estimate_unique_tokens([skill, shared])

            with (
                mock.patch.object(validator, "INSTRUCTIONS_ROOT", root),
                mock.patch.object(validator, "LOADSET_SESSION_BASE", ["ai/SKILL.md"]),
                mock.patch.object(validator, "LOADSET_REQUIRED_CEILINGS", {"5a": unique_total}),
                mock.patch.object(validator, "LOADSET_FULL_CEILING", unique_total),
            ):
                findings = validator.Findings()
                validator.check_loadset_token_budget(findings)

            self.assertEqual(findings.errors, [])

    def test_strip_fenced_code_blocks_preserves_line_numbers(self):
        text = "before\n```python\ncode [link](x.md)\n```\nafter\n"
        stripped = validator.strip_fenced_code_blocks(text)
        self.assertNotIn("[link](x.md)", stripped)
        self.assertEqual(text.count("\n"), stripped.count("\n"))
        self.assertIn("after", stripped)

    def test_normalize_text(self):
        self.assertEqual(validator.normalize_text("  Foo\t Bar  "), "foo bar")

    def test_action_reference_policy_rejects_mutable_ref(self):
        temp_root = Path(tempfile.mkdtemp(prefix="tooling-action-policy-"))
        self.addCleanup(shutil.rmtree, temp_root, ignore_errors=True)
        path = temp_root / "action-policy.md"
        path.write_text("- uses: actions/checkout@v7\n", encoding="utf-8")
        findings = validator.Findings()
        validator.check_action_reference_policy(path, findings)
        self.assertEqual(len(findings.errors), 1)

        path.write_text("- uses: actions/checkout@<latest-stable-sha>\n", encoding="utf-8")
        findings = validator.Findings()
        validator.check_action_reference_policy(path, findings)
        self.assertEqual(findings.errors, [])

        # Owner-agnostic: any uses: ref is checked, and concrete refs in
        # backticked prose are rejected while <...> placeholders pass.
        path.write_text(
            "- uses: google-github-actions/auth@v3\n"
            "Pin `some-owner/some-action@v2` in prose.\n",
            encoding="utf-8",
        )
        findings = validator.Findings()
        validator.check_action_reference_policy(path, findings)
        self.assertEqual(len(findings.errors), 2)

        path.write_text(
            "- uses: ./.github/actions/local@v1\n"
            "Write `owner/action@<resolved-commit-sha> # <stable-release-tag>` into the workflow.\n"
            "See `azure/login@<latest-stable-sha>` for OIDC.\n",
            encoding="utf-8",
        )
        findings = validator.Findings()
        validator.check_action_reference_policy(path, findings)
        self.assertEqual(findings.errors, [])

    def test_heading_matches_section(self):
        headings = ["Menu Navigation: Always Land On Top Page", "5a - Foundation (TDD)", "Aspire AppHost"]
        self.assertTrue(validator.heading_matches_section(headings, "Menu Navigation"))
        self.assertTrue(validator.heading_matches_section(headings, "5a"))
        self.assertTrue(validator.heading_matches_section(headings, "aspire apphost"))
        self.assertFalse(validator.heading_matches_section(headings, "Nonexistent Section"))
        self.assertFalse(validator.heading_matches_section(headings, ""))

    def test_deprecated_layout_guard_matches_legacy_paths_only(self):
        with tempfile.TemporaryDirectory(prefix="tooling-layout-") as tmp:
            path = Path(tmp) / "paths.md"
            path.write_text(
                "\n".join([
                    "src/Test/Test.Unit/Test.Unit.csproj",
                    r"src\Test\Test.Unit\Test.Unit.csproj",
                    "Test/Test.Endpoints/EndpointsTests.cs",
                    r"Test\Test.Endpoints\EndpointsTests.cs",
                    "src/{SolutionName}.slnx",
                    r"src\TaskFlow.slnx",
                    "src/{SolutionName}.sln",
                    r"src\TaskFlow.sln",
                    "App.sln",
                    "./Test/Test.Unit/Test.Unit.csproj",
                    r"repo\Test\Test.Unit\Test.Unit.csproj",
                    "`Test.Support/Builders/EntityBuilder.cs`",
                    "src/Directory.Build.props",
                    r"src\Directory.Packages.props",
                    "src/global.json",
                    r"src\nuget.config",
                ]),
                encoding="utf-8",
            )
            findings = validator.Findings()
            validator.check_deprecated_layout(path, findings)
            self.assertEqual(len(findings.errors), 16)

            path.write_text(
                "tests/Test.Unit/Test.Unit.csproj\n"
                r"tests\Test.Endpoints\Test.Endpoints.csproj" "\n"
                "TaskFlow.slnx\nDirectory.Build.props\nDirectory.Packages.props\nglobal.json\nnuget.config\n"
                "mysrc/Test.Unit/Test.Unit.csproj\nmy-src/Testing/Test.Unit/Test.Unit.csproj\n"
                "my.src/Testing/Test.Unit/Test.Unit.csproj\nsrc/App.slnx.backup\nmysrc/global.json\n"
                "`tests/Test.Support/Builders/EntityBuilder.cs`\n"
                r"`..\Test.Support\Test.Support.csproj`" "\n"
                "Use legacy `.sln` or `*.sln` only during adoption.\n",
                encoding="utf-8",
            )
            findings = validator.Findings()
            validator.check_deprecated_layout(path, findings)
            self.assertEqual(findings.errors, [])

    def test_test_project_templates_reference_production_under_src(self):
        templates = (
            "test-templates-aspire.md",
            "test-templates-integration.md",
            "test-templates-presentation.md",
            "test-templates-quality.md",
        )
        production_layers = ("Application", "Domain", "Host", "Infrastructure", "UI")
        for name in templates:
            text = (REPO_ROOT / "templates" / name).read_text(encoding="utf-8")
            self.assertIn("..\\..\\src\\", text, name)
            for layer in production_layers:
                self.assertNotIn(f"..\\..\\{layer}\\", text, name)
                self.assertNotIn(f"../../{layer}/", text, name)


# Module-level: a function stored as a class attribute would bind as a method
# and receive self as an extra argument inside copytree.
MUTATION_IGNORE = shutil.ignore_patterns(
    ".git", ".venv", ".tmp", "__pycache__", "tests", ".vs", "node_modules", "bin", "obj"
)


@unittest.skipIf(FAST, "--fast: skipping slow validator mutation tests")
class ValidatorMutationTests(unittest.TestCase):
    """Copy the repo to a temp dir, break one thing, prove the validator fails.

    A validator that silently passes on bad input green-lights drift; these are
    the tests that catch that failure mode.
    """

    def _copy_repo(self) -> Path:
        tmp = Path(tempfile.mkdtemp(prefix="tooling-mut-"))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        dest = tmp / "repo"
        shutil.copytree(REPO_ROOT, dest, ignore=MUTATION_IGNORE)
        return dest

    def _run_validator(self, root: Path) -> int:
        proc = subprocess.run(
            [sys.executable, str(root / "scripts" / "validate-instructions.py")],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
        )
        return proc.returncode

    def test_baseline_copy_passes(self):
        repo = self._copy_repo()
        self.assertEqual(self._run_validator(repo), 0)

    def test_dangling_link_fails(self):
        repo = self._copy_repo()
        target = repo / "skills" / "api.md"
        target.write_text(
            target.read_text(encoding="utf-8") + "\nSee [missing](does-not-exist-xyz.md).\n",
            encoding="utf-8",
        )
        self.assertEqual(self._run_validator(repo), 1)

    def test_bare_version_prose_fails(self):
        repo = self._copy_repo()
        target = repo / "patterns" / "api-host-wiring.md"
        target.write_text(
            target.read_text(encoding="utf-8") + "\nPin the package to 9.9.9 for stability.\n",
            encoding="utf-8",
        )
        self.assertEqual(self._run_validator(repo), 1)

    def test_deleted_template_fails(self):
        repo = self._copy_repo()
        (repo / "templates" / "endpoint-template.md").unlink()
        self.assertEqual(self._run_validator(repo), 1)

    def test_deprecated_layout_prose_fails(self):
        repo = self._copy_repo()
        target = repo / "patterns" / "api-host-wiring.md"
        target.write_text(
            target.read_text(encoding="utf-8") + "\nBuild src/{SolutionName}.slnx.\n",
            encoding="utf-8",
        )
        self.assertEqual(self._run_validator(repo), 1)


class GoldenPathTests(unittest.TestCase):
    def test_extract_fenced_block_found_and_missing(self):
        doc = "## Head\n\n```yaml\nkey: value\n```\n"
        self.assertEqual(goldenpath.extract_fenced_block(doc, "## Head", "yaml"), "key: value")
        with self.assertRaises(SystemExit):
            goldenpath.extract_fenced_block(doc, "## Nope", "yaml")

    def test_transform_resource_yaml_feed_replaces_placeholder(self):
        block = f"packageStrategy: feed\ncustomNugetFeeds:\n  - {goldenpath.FEED_PLACEHOLDER}\n"
        out = goldenpath.transform_resource_yaml(block, "feed", "https://example.test/index.json", "EF")
        self.assertIn("https://example.test/index.json", out)
        self.assertNotIn("{owner}", out)

    def test_transform_resource_yaml_local_swaps_strategy_and_layers(self):
        block = (
            "packageStrategy: feed\n"
            "packagePrefix: EF\n"
            "customNugetFeeds:\n"
            "  - https://nuget.pkg.github.com/someone/index.json\n"
            "otherKey: kept\n"
        )
        out = goldenpath.transform_resource_yaml(block, "local", None, "Package")
        self.assertIn("packageStrategy: local", out)
        self.assertIn("packagePrefix: Package", out)
        self.assertNotIn("customNugetFeeds", out)
        self.assertNotIn("nuget.pkg.github.com", out)
        self.assertIn("localPackageLayers:", out)
        self.assertIn("  - Domain", out)
        self.assertIn("otherKey: kept", out)

    def test_real_fixture_extracts_transforms_and_passes_sanity(self):
        doc = goldenpath.GOLDEN_PATH_DOC.read_text(encoding="utf-8")
        block = goldenpath.extract_fenced_block(doc, "## Expected Phase 2 Output", "yaml")
        for strategy in ("feed", "local"):
            transformed = goldenpath.transform_resource_yaml(
                block, strategy, "https://example.test/index.json", "Package"
            )
            goldenpath.sanity_check_resource_yaml(transformed)  # fails via SystemExit on drift

    def test_sanity_check_rejects_missing_required_key(self):
        with self.assertRaises(SystemExit):
            goldenpath.sanity_check_resource_yaml("unknownKey: 1\n")

    def test_find_solution_prefers_root_slnx(self):
        tmp = Path(tempfile.mkdtemp(prefix="tooling-solution-"))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / "src").mkdir()
        root_solution = tmp / goldenpath.GOLDEN_SOLUTION
        root_solution.write_text("<Solution />\n", encoding="utf-8")
        (tmp / "App.slnx").write_text("<Solution />\n", encoding="utf-8")
        (tmp / "src" / "Legacy.slnx").write_text("<Solution />\n", encoding="utf-8")
        self.assertEqual(goldenpath.find_solution(tmp), root_solution)

    def test_gate_phase4_rejects_legacy_layout(self):
        tmp = Path(tempfile.mkdtemp(prefix="tooling-layout-gate-"))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        solution_xml = (
            '<Solution>\n'
            '  <Project Path="src/Product/Product.csproj" />\n'
            '  <Project Path="tests/Test.Unit/Test.Unit.csproj" />\n'
            '</Solution>\n'
        )
        root_solution = tmp / goldenpath.GOLDEN_SOLUTION
        root_solution.write_text(solution_xml, encoding="utf-8")
        (tmp / "HANDOFF.md").write_text("contractsScaffolded: true\n", encoding="utf-8")
        for name in ("Directory.Build.props", "Directory.Packages.props", "global.json"):
            (tmp / name).write_text("test\n", encoding="utf-8")
        (tmp / "src" / "Test").mkdir(parents=True)
        (tmp / "src" / "Product").mkdir()
        production_project = tmp / "src" / "Product" / "Product.csproj"
        production_project.write_text("<Project />\n", encoding="utf-8")
        (tmp / "tests" / "Test.Unit").mkdir(parents=True)
        test_project = tmp / "tests" / "Test.Unit" / "Test.Unit.csproj"
        test_project.write_text("<Project />\n", encoding="utf-8")
        legacy_solution = tmp / "src" / "Legacy.slnx"
        legacy_solution.write_text("<Solution />\n", encoding="utf-8")
        root_legacy_solution = tmp / "Legacy.sln"
        root_legacy_solution.write_text("Microsoft Visual Studio Solution File\n", encoding="utf-8")
        legacy_config = tmp / "src" / "global.json"
        legacy_config.write_text("test\n", encoding="utf-8")

        with mock.patch.object(goldenpath, "run_gate_cmd", return_value=(True, "")):
            ok, notes = goldenpath.gate("4", tmp)
        self.assertFalse(ok)
        self.assertTrue(any("LEGACY nested solution" in note for note in notes))
        self.assertTrue(any("LEGACY root .sln" in note for note in notes))
        self.assertTrue(any("LEGACY root configuration" in note for note in notes))
        self.assertTrue(any("LEGACY test tree" in note for note in notes))

        legacy_solution.unlink()
        root_legacy_solution.unlink()
        legacy_config.unlink()
        shutil.rmtree(tmp / "src" / "Test")
        self.assertFalse((tmp / "nuget.config").exists())
        with mock.patch.object(goldenpath, "run_gate_cmd", return_value=(True, "")):
            ok, notes = goldenpath.gate("4", tmp)
        self.assertTrue(ok, notes)

        shutil.rmtree(tmp / "tests")
        with mock.patch.object(goldenpath, "run_gate_cmd", return_value=(True, "")):
            ok, notes = goldenpath.gate("4", tmp)
        self.assertFalse(ok)
        self.assertIn("MISSING test tree tests/", notes)

        (tmp / "tests").mkdir()
        with mock.patch.object(goldenpath, "run_gate_cmd", return_value=(True, "")):
            ok, notes = goldenpath.gate("4", tmp)
        self.assertFalse(ok)
        self.assertIn("MISSING test project under tests/", notes)

        (tmp / "tests" / "Test.Unit").mkdir()
        test_project.write_text("<Project />\n", encoding="utf-8")
        (tmp / "global.json").unlink()
        with mock.patch.object(goldenpath, "run_gate_cmd", return_value=(True, "")):
            ok, notes = goldenpath.gate("4", tmp)
        self.assertFalse(ok)
        self.assertIn("MISSING root global.json", notes)

        (tmp / "global.json").write_text("test\n", encoding="utf-8")
        root_solution.unlink()
        with mock.patch.object(goldenpath, "run_gate_cmd", return_value=(True, "")):
            ok, notes = goldenpath.gate("4", tmp)
        self.assertFalse(ok)
        self.assertIn(f"MISSING root {goldenpath.GOLDEN_SOLUTION}", notes)

        root_solution.write_text(solution_xml, encoding="utf-8")
        extra_solution = tmp / "Extra.slnx"
        extra_solution.write_text("<Solution />\n", encoding="utf-8")
        with mock.patch.object(goldenpath, "run_gate_cmd", return_value=(True, "")):
            ok, notes = goldenpath.gate("4", tmp)
        self.assertFalse(ok)
        self.assertIn("UNEXPECTED root .slnx: Extra.slnx", notes)
        extra_solution.unlink()

        nested_solution = tmp / "tests" / "Legacy.slnx"
        nested_solution.write_text("<Solution />\n", encoding="utf-8")
        with mock.patch.object(goldenpath, "run_gate_cmd", return_value=(True, "")):
            ok, notes = goldenpath.gate("4", tmp)
        self.assertFalse(ok)
        self.assertTrue(any("LEGACY nested solution" in note for note in notes))
        nested_solution.unlink()

        root_solution.write_text(
            solution_xml.replace("tests/Test.Unit/Test.Unit.csproj", "Test/Test.Unit/Test.Unit.csproj"),
            encoding="utf-8",
        )
        with mock.patch.object(goldenpath, "run_gate_cmd", return_value=(True, "")):
            ok, notes = goldenpath.gate("4", tmp)
        self.assertFalse(ok)
        self.assertTrue(any("NONCANONICAL project path" in note for note in notes))
        root_solution.write_text(solution_xml, encoding="utf-8")

        (tmp / "tools").mkdir()
        misplaced_project = tmp / "tools" / "Tool.csproj"
        misplaced_project.write_text("<Project />\n", encoding="utf-8")
        with mock.patch.object(goldenpath, "run_gate_cmd", return_value=(True, "")):
            ok, notes = goldenpath.gate("4", tmp)
        self.assertFalse(ok)
        self.assertTrue(any("MISPLACED project" in note for note in notes))
        shutil.rmtree(tmp / "tools")

        production_project.unlink()
        with mock.patch.object(goldenpath, "run_gate_cmd", return_value=(True, "")):
            ok, notes = goldenpath.gate("4", tmp)
        self.assertFalse(ok)
        self.assertIn("MISSING production project under src/", notes)
        production_project.write_text("<Project />\n", encoding="utf-8")

        (tmp / "Test").mkdir()
        with mock.patch.object(goldenpath, "run_gate_cmd", return_value=(True, "")):
            ok, notes = goldenpath.gate("4", tmp)
        self.assertFalse(ok)
        self.assertIn("LEGACY test tree Test/ exists; use tests/", notes)
        shutil.rmtree(tmp / "Test")

        shutil.rmtree(tmp / "src")
        with mock.patch.object(goldenpath, "run_gate_cmd", return_value=(True, "")):
            ok, notes = goldenpath.gate("4", tmp)
        self.assertFalse(ok)
        self.assertIn("MISSING production tree src/", notes)

    def test_gate_phase3(self):
        tmp = Path(tempfile.mkdtemp(prefix="tooling-gate-"))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / ".scaffold").mkdir(parents=True)
        (tmp / "HANDOFF.md").write_text('currentPhase: "4"\n', encoding="utf-8")

        ok, _notes = goldenpath.gate("3", tmp)
        self.assertFalse(ok)  # implementation-plan.md missing

        (tmp / ".scaffold" / "implementation-plan.md").write_text("# Plan\n", encoding="utf-8")
        ok, _notes = goldenpath.gate("3", tmp)
        self.assertTrue(ok)

        (tmp / "HANDOFF.md").write_text('currentPhase: "3"\n', encoding="utf-8")
        ok, _notes = goldenpath.gate("3", tmp)
        self.assertFalse(ok)  # HANDOFF did not advance


if __name__ == "__main__":
    os.chdir(REPO_ROOT)
    unittest.main(verbosity=2)
