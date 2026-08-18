#!/usr/bin/env python3
"""Validate the TaskFlow proof repository against this scaffold checkout."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote


SCAFFOLD_ROOT = Path(__file__).resolve().parent.parent
MARKDOWN_LINK_RE = re.compile(r"!?(?:\[[^\]]*\])\(([^)]+)\)")
CODE_SPAN_RE = re.compile(r"`([^`]+)`")
ACTION_REF_RE = re.compile(r"\buses:\s*([^\s@]+)@([^\s#]+)")
SHA_REF_RE = re.compile(r"^[0-9a-f]{40}$")
PROOF_ROOTS = (".scaffold/", ".github/", "src/", "tests/", "infra/")

EXPECTED_FLAGS: dict[str, object] = {
    "scaffoldMode": "full",
    "testingProfile": "comprehensive",
    "applicationStyle": "switch",
    "includeApi": True,
    "includeGateway": True,
    "includeFunctionApp": True,
    "includeScheduler": True,
    "includeUnoUI": True,
    "includeBlazorUI": True,
    "includeReactUI": True,
    "includeNotifications": False,
    "includeFlowEngine": True,
    "flowEngineDbStrategy": "same-db-separate-schema",
    "includeIaC": True,
    "includeGitHubActions": True,
    "includeAzd": False,
    "includeAiServices": True,
    "includeKeyVault": True,
    "useAspire": True,
    "migrationLifecycle": "preserved-append-only",
    "databaseProviders": ["SqlServer"],
    "includeArchitectureTests": True,
    "includeE2ETests": True,
    "includeLoadTests": True,
    "includeBenchmarkTests": True,
    "includeMutationTests": True,
    "includeAspireTests": True,
    "includePlaywrightUITests": True,
    "includeMobileTests": True,
}

SENTINELS: tuple[tuple[str, str], ...] = (
    ("src/Application/TaskFlow.Application.Contracts/ApplicationStyle.cs", "TASKFLOW_APPLICATION_STYLE"),
    ("src/Host/TaskFlow.Api/WebApplicationBuilderExtensions.cs", "ApplicationStyleResolver"),
    ("src/Host/TaskFlow.Bootstrapper/Registration/RegisterServices.FlowEngine.cs", "AddFlowEngine"),
    ("src/Host/TaskFlow.Api/WebApplicationBuilderExtensions.cs", "MapFlowEngineAdmin"),
    ("src/Host/Aspire/AppHost/AppHost.cs", "AddAzureKeyVault"),
    ("src/Host/TaskFlow.Functions/FunctionServiceBusTrigger.cs", "IWorkflowTrigger"),
    (".github/workflows/ci.yml", "Test.Integration.FlowEngine"),
    (".github/workflows/ci.yml", "Test.Aspire"),
    (".github/workflows/ci.yml", "Test.PlaywrightUI"),
    ("HANDOFF.md", "workflowStatus: complete"),
    (".scaffold/REFERENCE-STATUS.md", "- `proven`:"),
    (".scaffold/REFERENCE-STATUS.md", "- `deployment-only`:"),
    (".scaffold/REFERENCE-STATUS.md", "- `documented-only`:"),
    (".scaffold/REFERENCE-STATUS.md", "- `not enabled`:"),
)

REQUIRED_PATHS: tuple[str, ...] = (
    "src/Host/TaskFlow.Api/Workflows/ai-task-triage.json",
    "src/Host/TaskFlow.Api/Workflows/ai-task-decomposer.json",
    "src/Host/TaskFlow.Api/Workflows/compliance-check.json",
    "src/Infrastructure/TaskFlow.Infrastructure.Data/Migrations/FlowEngine",
    "tests/Test.Unit/Test.Unit.csproj",
    "tests/Test.Architecture/Test.Architecture.csproj",
    "tests/Test.Endpoints/Test.Endpoints.csproj",
    "tests/Test.E2E/Test.E2E.csproj",
    "tests/Test.Integration/Test.Integration.csproj",
    "tests/Test.Integration.FlowEngine/Test.Integration.FlowEngine.csproj",
    "tests/Test.Aspire/Test.Aspire.csproj",
    "tests/Test.FoundryLocal/Test.FoundryLocal.csproj",
    "tests/Test.PlaywrightUI/Test.PlaywrightUI.csproj",
    "tests/Test.UI/Test.UI.csproj",
    "tests/Test.Mobile/Test.Mobile.csproj",
    "tests/Test.Load/Test.Load.csproj",
    "tests/Test.Mutation/Test.Mutation.csproj",
    "tests/Test.Benchmarks/Test.Benchmarks.csproj",
)


def tracked_markdown_files(root: Path) -> list[Path]:
    proc = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--", "*.md"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if proc.returncode == 0:
        return [root / line for line in proc.stdout.splitlines() if line]
    return sorted(path for path in root.rglob("*.md") if ".git" not in path.parts)


def link_target(raw: str) -> str:
    raw = raw.strip()
    if raw.startswith("<") and ">" in raw:
        return raw[1:raw.index(">")]
    return raw.split(maxsplit=1)[0]


def check_markdown_links(root: Path) -> list[str]:
    errors: list[str] = []
    for markdown in tracked_markdown_files(root):
        text = markdown.read_text(encoding="utf-8")
        for line_no, line in enumerate(text.splitlines(), start=1):
            for match in MARKDOWN_LINK_RE.finditer(line):
                target = unquote(link_target(match.group(1)))
                path_part = target.split("#", 1)[0].split("?", 1)[0]
                if not path_part or re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", path_part):
                    continue
                resolved = (root / path_part.lstrip("/")) if path_part.startswith("/") else (markdown.parent / path_part)
                if not resolved.resolve().exists():
                    rel = markdown.relative_to(root).as_posix()
                    errors.append(f"{rel}:{line_no}: broken Markdown link '{target}'")
    return errors


def load_and_validate_yaml(reference_root: Path) -> tuple[dict, list[str]]:
    errors: list[str] = []
    try:
        import jsonschema  # type: ignore
        import yaml  # type: ignore
    except ImportError:
        return {}, ["PyYAML and jsonschema are required; install their latest stable releases"]

    resource: dict = {}
    contracts = (
        (".scaffold/domain-specification.yaml", "schemas/domain-specification.schema.json"),
        (".scaffold/resource-implementation.yaml", "schemas/resource-implementation.schema.json"),
    )
    for data_rel, schema_rel in contracts:
        data_path = reference_root / data_rel
        schema_path = SCAFFOLD_ROOT / schema_rel
        if not data_path.is_file():
            errors.append(f"missing contract: {data_rel}")
            continue
        try:
            data = yaml.safe_load(data_path.read_text(encoding="utf-8"))
            schema = json.loads(schema_path.read_text(encoding="utf-8"))
            jsonschema.validate(data, schema)
            if data_rel.endswith("resource-implementation.yaml"):
                resource = data
        except (OSError, json.JSONDecodeError, yaml.YAMLError) as exc:
            errors.append(f"{data_rel}: cannot load contract: {exc}")
        except jsonschema.ValidationError as exc:
            location = "/".join(str(part) for part in exc.absolute_path) or "<root>"
            errors.append(f"{data_rel}: schema violation at {location}: {exc.message}")
    return resource, errors


def check_flags(resource: dict) -> list[str]:
    errors: list[str] = []
    for key, expected in EXPECTED_FLAGS.items():
        if key not in resource:
            errors.append(f".scaffold/resource-implementation.yaml: explicit flag '{key}' is missing")
        elif resource[key] != expected:
            errors.append(
                f".scaffold/resource-implementation.yaml: {key}={resource[key]!r}, expected {expected!r}"
            )
    if resource.get("includeNotifications") is False and resource.get("notifications"):
        errors.append(".scaffold/resource-implementation.yaml: disabled notifications must not define notification entries")
    return errors


def check_sentinels(reference_root: Path) -> list[str]:
    errors: list[str] = []
    for rel in REQUIRED_PATHS:
        if not (reference_root / rel).exists():
            errors.append(f"missing reference proof path: {rel}")
    for rel, expected in SENTINELS:
        path = reference_root / rel
        if not path.is_file():
            errors.append(f"missing sentinel file: {rel}")
        elif expected not in path.read_text(encoding="utf-8"):
            errors.append(f"{rel}: missing feature sentinel '{expected}'")
    return errors


def proof_paths(proof_map: Path) -> list[str]:
    paths: list[str] = []
    for span in CODE_SPAN_RE.findall(proof_map.read_text(encoding="utf-8")):
        for part in re.split(r",\s+|\s+\+\s+", span):
            candidate = part.strip().rstrip(".;:")
            if candidate.startswith(PROOF_ROOTS):
                paths.append(candidate)
    return paths


def check_proof_map(reference_root: Path) -> list[str]:
    proof_map = SCAFFOLD_ROOT / "support" / "taskflow-proof-map.md"
    errors: list[str] = []
    if not proof_map.is_file():
        return ["support/taskflow-proof-map.md is missing"]
    for rel in proof_paths(proof_map):
        if "*" in rel:
            if not list(reference_root.glob(rel)):
                errors.append(f"proof map glob matches nothing: {rel}")
        elif not (reference_root / rel).exists():
            errors.append(f"proof map path does not exist: {rel}")
    return errors


def check_action_refs(reference_root: Path) -> list[str]:
    errors: list[str] = []
    workflows = reference_root / ".github" / "workflows"
    for path in sorted(workflows.glob("*.y*ml")):
        for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            match = ACTION_REF_RE.search(line)
            if not match or match.group(1).startswith("./"):
                continue
            if not SHA_REF_RE.fullmatch(match.group(2)):
                rel = path.relative_to(reference_root).as_posix()
                errors.append(
                    f"{rel}:{line_no}: action '{match.group(1)}' must use an immutable 40-character SHA"
                )
    return errors


def validate_reference(reference_root: Path) -> list[str]:
    if not reference_root.is_dir():
        return [f"reference root is not a directory: {reference_root}"]
    resource, errors = load_and_validate_yaml(reference_root)
    errors.extend(check_markdown_links(reference_root))
    errors.extend(check_proof_map(reference_root))
    errors.extend(check_flags(resource))
    errors.extend(check_sentinels(reference_root))
    errors.extend(check_action_refs(reference_root))
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate TaskFlow against the current scaffold checkout.")
    parser.add_argument("--reference-root", required=True, type=Path)
    args = parser.parse_args()
    root = args.reference_root.resolve()
    errors = validate_reference(root)
    if errors:
        for error in errors:
            print(f"[fail] {error}")
        print(f"\n[fail] reference validation found {len(errors)} issue(s)")
        return 1
    print(f"[ok] reference contracts, links, proof paths, feature sentinels, and action refs match {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
