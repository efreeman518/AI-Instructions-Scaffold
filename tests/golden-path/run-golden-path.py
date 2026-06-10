#!/usr/bin/env python3
"""
Local golden-path regression harness (author-side, never shipped to apps).

Proves the instruction set still produces a building, testing app by driving
one fresh headless agent session per phase (3 -> 4 -> 5a -> 5b) against the
WorkBoard golden-path fixture, with this harness - not the agent - running the
deterministic gates (dotnet build / dotnet test) between phases.

No API key required: the claude driver uses the subscription OAuth login from
`claude /login`; the codex driver uses `codex login` (ChatGPT plan).

Fixtures (Phase 1/2 artifacts) are extracted at runtime from
support/golden-path-sample.md - the doc stays the single source of truth and
scripts/validate-instructions.py keeps it schema-true. Phase prompts are
extracted at runtime from support/prompt-catalog.md.

Usage:
    py -3 tests/golden-path/run-golden-path.py [--dry-run] [options]

Typical flow:
    1. py -3 tests/golden-path/run-golden-path.py --dry-run   # inspect first
    2. py -3 tests/golden-path/run-golden-path.py             # full run
    3. On a failed gate: fix instructions, then re-run the failed phase onward:
       py -3 tests/golden-path/run-golden-path.py --target <kept-workspace> --phases 5a,5b

Exit code 0 when every requested phase passes its gate, 1 otherwise.
The workspace is always kept so failures can be inspected and resumed.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

REPO_ROOT = Path(__file__).resolve().parents[2]
GOLDEN_PATH_DOC = REPO_ROOT / "support" / "golden-path-sample.md"
PROMPT_CATALOG = REPO_ROOT / "support" / "prompt-catalog.md"
INSTALLER = REPO_ROOT / "scripts" / "install-to-project.py"
RESOURCE_SCHEMA = REPO_ROOT / "schemas" / "resource-implementation.schema.json"
REPORT_ROOT = REPO_ROOT / ".tmp" / "golden-path-runs"

PHASE_ORDER = ["3", "4", "5a", "5b"]
DEFAULT_MAX_TURNS = {"3": 60, "4": 200, "5a": 250, "5b": 300}

# Layer set for the local-strategy bypass, derived from
# support/ef-packages-reference.md section Phase Usage (5a/5b) plus test layers.
LOCAL_PACKAGE_LAYERS = [
    "Common", "Common.Contracts", "Domain", "Domain.Contracts",
    "Data", "Data.Contracts", "AspNetCore", "Host", "FilterBuilder",
    "Cache", "Auth", "Test.Unit", "Test.Integration",
]

FEED_PLACEHOLDER = "https://nuget.pkg.github.com/{owner}/index.json"

# Fixture blocks in golden-path-sample.md: heading -> (fence language, output file).
FIXTURE_BLOCKS = [
    ("### `.scaffold/domain-specification.yaml`", "yaml", ".scaffold/domain-specification.yaml"),
    ("### `.scaffold/UBIQUITOUS-LANGUAGE.md`", "markdown", ".scaffold/UBIQUITOUS-LANGUAGE.md"),
    ("### `.scaffold/DESIGN-DECISIONS.md`", "markdown", ".scaffold/DESIGN-DECISIONS.md"),
    ("## Expected Phase 2 Output", "yaml", ".scaffold/resource-implementation.yaml"),
]

# Prompt blocks in prompt-catalog.md: phase key -> list of heading prefixes whose
# first ```text block is concatenated to form the session prompt.
PROMPT_HEADINGS = {
    "3": ["## Phase 3 - Implementation Plan"],
    "4": ["## Phase 4 - Contract Scaffolding"],
    "5a": ["## Phase 5 - Session Start", "### 5a - Foundation (TDD)"],
    "5b": ["## Phase 5 - Session Start", "### 5b - App Core + Runtime/Edge"],
}

# Gateway is off in the golden-path fixture; the other runtime concerns are on.
RUNTIME_CONCERNS_5B = "aspire/caching/observability/security/multi-tenant"
RUNTIME_PLACEHOLDER_5B = "{gateway/aspire/caching/observability/security/multi-tenant}"

HANDOFF_FIXTURE = """instructionVersion: ""
currentPhase: "3"
currentSubPhase: ""
scaffoldMode: full
testingProfile: balanced
contractsScaffolded: false
enabledFeatures:
  includeApi: true
  useAspire: true
  includeGateway: false
  includeScheduler: false
  includeFunctionApp: false
  includeUnoUI: false
  includeBlazorUI: false
  includeReactUI: false
  includeNotifications: false
  includeIaC: true
  includeGitHubActions: false
  includeAzd: false
  includeAiServices: false
testStatus:
  unitTests: not-started
  endpointTests: not-started
  integrationTests: not-started
resumeCommand: "Load .instructions/START-AI.md and HANDOFF.md, resume at Phase 3."
instructionGapsPath: ".scaffold/INSTRUCTION-GAPS.md"

## Completed

- Phases 1-2 supplied from the golden-path fixture by tests/golden-path/run-golden-path.py.

## Blockers

- None
"""


def fail(msg: str) -> None:
    print(f"[fail] {msg}")
    sys.exit(1)


def log(msg: str) -> None:
    print(f"[golden-path] {msg}", flush=True)


# --- extraction ---------------------------------------------------------------

def extract_fenced_block(text: str, heading: str, lang: str) -> str:
    idx = text.find(heading)
    if idx == -1:
        fail(f"heading not found in source doc: {heading}")
    pattern = re.compile(r"```" + re.escape(lang) + r"\r?\n(.*?)\r?\n```", re.DOTALL)
    match = pattern.search(text, idx)
    if not match:
        fail(f"no ```{lang} block found after heading: {heading}")
    return match.group(1)


def extract_prompts() -> dict[str, str]:
    text = PROMPT_CATALOG.read_text(encoding="utf-8")
    prompts: dict[str, str] = {}
    for phase, headings in PROMPT_HEADINGS.items():
        parts = [extract_fenced_block(text, h, "text") for h in headings]
        prompt = "\n".join(parts)
        if phase == "5b":
            if RUNTIME_PLACEHOLDER_5B not in prompt:
                fail("5b runtime-concern placeholder missing from prompt-catalog.md - update RUNTIME_PLACEHOLDER_5B")
            prompt = prompt.replace(RUNTIME_PLACEHOLDER_5B, RUNTIME_CONCERNS_5B)
        prompts[phase] = prompt
    return prompts


# --- package strategy ---------------------------------------------------------

def detect_global_feed(feed_url_flag: str | None) -> str | None:
    if feed_url_flag:
        return feed_url_flag
    proc = subprocess.run(
        ["dotnet", "nuget", "list", "source"],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    if proc.returncode != 0:
        return None
    for line in proc.stdout.splitlines():
        url = line.strip()
        if url.startswith("https://nuget.pkg.github.com/"):
            return url
    return None


def transform_resource_yaml(block: str, strategy: str, feed_url: str | None, prefix: str) -> str:
    lines = block.splitlines()
    out: list[str] = []
    if strategy == "feed":
        for line in lines:
            out.append(line.replace(FEED_PLACEHOLDER, feed_url or FEED_PLACEHOLDER))
        return "\n".join(out)

    # local bypass: swap strategy + prefix, drop customNugetFeeds, add localPackageLayers.
    skip_feed_items = False
    for line in lines:
        if line.startswith("packageStrategy:"):
            out.append("packageStrategy: local")
            continue
        if line.startswith("packagePrefix:"):
            out.append(f"packagePrefix: {prefix}")
            continue
        if line.startswith("customNugetFeeds:"):
            skip_feed_items = True
            out.append("localPackageLayers:")
            for layer in LOCAL_PACKAGE_LAYERS:
                out.append(f"  - {layer}")
            continue
        if skip_feed_items:
            if line.startswith("  ") or line.startswith("\t"):
                continue  # drop the feed list items
            skip_feed_items = False
        out.append(line)
    return "\n".join(out)


def sanity_check_resource_yaml(block: str) -> None:
    """Structural check mirroring validate-instructions.py (stdlib only)."""
    schema = json.loads(RESOURCE_SCHEMA.read_text(encoding="utf-8"))
    props = schema.get("properties", {})
    top_keys = re.findall(r"^([A-Za-z][A-Za-z0-9]*):", block, re.MULTILINE)
    for req in schema.get("required", []):
        if req not in top_keys:
            fail(f"transformed resource YAML is missing required key '{req}'")
    for key in top_keys:
        if key not in props:
            fail(f"transformed resource YAML has undeclared key '{key}'")
    m = re.search(r"^packageStrategy:\s*(\S+)", block, re.MULTILINE)
    if not m or m.group(1) not in props["packageStrategy"]["enum"]:
        fail("transformed resource YAML has an invalid packageStrategy value")


# --- agent drivers ------------------------------------------------------------

def run_claude(prompt: str, target: Path, args: argparse.Namespace, phase: str, log_dir: Path) -> tuple[int, dict]:
    exe = shutil.which("claude")
    max_turns = getattr(args, f"max_turns_p{phase}", None) or DEFAULT_MAX_TURNS[phase]
    cmd = [exe, "-p", prompt,
           "--permission-mode", "bypassPermissions",
           "--setting-sources", "project",
           "--max-turns", str(max_turns),
           "--output-format", "json"]
    if args.model:
        cmd += ["--model", args.model]
    env = dict(os.environ, CLAUDE_CODE_DISABLE_AUTO_MEMORY="1")
    proc = _run_with_timeout(cmd, cwd=target, env=env, timeout_min=args.timeout_minutes, log_dir=log_dir, phase=phase)
    meta: dict = {}
    if proc is not None and proc.stdout:
        try:
            payload = json.loads(proc.stdout.strip().splitlines()[-1])
            meta = {k: payload.get(k) for k in ("session_id", "total_cost_usd", "num_turns", "is_error") if k in payload}
        except (json.JSONDecodeError, IndexError):
            meta = {"raw_tail": proc.stdout[-500:]}
    return (proc.returncode if proc is not None else 1), meta


def run_codex(prompt: str, target: Path, args: argparse.Namespace, phase: str, log_dir: Path) -> tuple[int, dict]:
    exe = shutil.which("codex")
    last_msg = log_dir / f"phase-{phase}-last-message.txt"
    cmd = [exe, "exec", prompt,
           "--cd", str(target),
           "--dangerously-bypass-approvals-and-sandbox",
           "--ignore-user-config",
           "--json",
           "-o", str(last_msg)]
    if args.model:
        cmd += ["-m", args.model]
    env = dict(os.environ)
    proc = _run_with_timeout(cmd, cwd=target, env=env, timeout_min=args.timeout_minutes, log_dir=log_dir, phase=phase)
    meta: dict = {"last_message_file": str(last_msg)}
    return (proc.returncode if proc is not None else 1), meta


DRIVERS = {"claude": run_claude, "codex": run_codex}


def _run_with_timeout(cmd: list, cwd: Path, env: dict, timeout_min: int, log_dir: Path, phase: str):
    log_file = log_dir / f"phase-{phase}-agent.log"
    try:
        proc = subprocess.run(
            cmd, cwd=str(cwd), env=env,
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            timeout=timeout_min * 60,
        )
    except subprocess.TimeoutExpired:
        log_file.write_text(f"TIMEOUT after {timeout_min} minutes\ncmd: {cmd[:2]}...\n", encoding="utf-8")
        log(f"phase {phase}: agent timed out after {timeout_min} minutes")
        return None
    log_file.write_text(
        f"exit: {proc.returncode}\n--- stdout ---\n{proc.stdout}\n--- stderr ---\n{proc.stderr}\n",
        encoding="utf-8",
    )
    return proc


# --- gates --------------------------------------------------------------------

def run_gate_cmd(cmd: list[str], cwd: Path) -> tuple[bool, str]:
    proc = subprocess.run(cmd, cwd=str(cwd), capture_output=True, text=True, encoding="utf-8", errors="replace")
    tail = "\n".join((proc.stdout + "\n" + proc.stderr).splitlines()[-50:])
    return proc.returncode == 0, tail


def find_solution(target: Path) -> Path | None:
    """Find .slnx or .sln; solution lives under src/ (canonical) with root as fallback."""
    for search_root in [target / "src", target]:
        for pattern in ["*.slnx", "*.sln"]:
            matches = sorted(search_root.glob(pattern))
            if matches:
                return matches[0]
    return None


def gate(phase: str, target: Path) -> tuple[bool, list[str]]:
    notes: list[str] = []
    ok = True
    handoff = (target / "HANDOFF.md").read_text(encoding="utf-8", errors="replace") if (target / "HANDOFF.md").exists() else ""

    if phase == "3":
        if not (target / ".scaffold" / "implementation-plan.md").exists():
            ok = False
            notes.append("MISSING .scaffold/implementation-plan.md")
        if not re.search(r"currentPhase:\s*[\"']?4", handoff):
            ok = False
            notes.append("HANDOFF currentPhase did not advance to 4")
        notes.append("plan exists + HANDOFF advanced" if ok else "phase 3 gate failed")
        return ok, notes

    slnx = find_solution(target)
    build_cmd = ["dotnet", "build"] + ([str(slnx)] if slnx else [])
    build_ok, build_tail = run_gate_cmd(build_cmd, target)
    notes.append(f"dotnet build: {'PASS' if build_ok else 'FAIL'}\n{build_tail if not build_ok else ''}")
    ok = build_ok

    if phase == "4":
        if not re.search(r"contractsScaffolded:\s*true", handoff):
            ok = False
            notes.append("HANDOFF contractsScaffolded is not true")
        return ok, notes

    test_filter = "TestCategory=Unit" if phase == "5a" else "TestCategory=Unit|TestCategory=Endpoint"
    if build_ok:
        test_cmd = ["dotnet", "test", "--filter", test_filter] + ([str(slnx)] if slnx else [])
        test_ok, test_tail = run_gate_cmd(test_cmd, target)
        notes.append(f"dotnet test --filter \"{test_filter}\": {'PASS' if test_ok else 'FAIL'}\n{test_tail if not test_ok else ''}")
        ok = ok and test_ok
    return ok, notes


# --- main ---------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Local golden-path regression harness (no API key).")
    p.add_argument("--agent", choices=sorted(DRIVERS), default="claude")
    p.add_argument("--target", type=Path, default=None, help="workspace dir; default %%TEMP%%/workboard-gp-<timestamp>")
    p.add_argument("--phases", default="3,4,5a,5b", help="comma list from: 3,4,5a,5b")
    p.add_argument("--package-strategy", choices=["feed", "local"], default="feed")
    p.add_argument("--package-prefix", default="Package", help="local mode only; default Package")
    p.add_argument("--feed-url", default=None, help="feed mode: real feed URL; default auto-detect")
    p.add_argument("--model", default=None)
    p.add_argument("--max-turns-p3", type=int, dest="max_turns_p3")
    p.add_argument("--max-turns-p4", type=int, dest="max_turns_p4")
    p.add_argument("--max-turns-p5a", type=int, dest="max_turns_p5a")
    p.add_argument("--max-turns-p5b", type=int, dest="max_turns_p5b")
    p.add_argument("--timeout-minutes", type=int, default=60)
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--gate-only", action="store_true",
                   help="skip agent sessions; re-run only the gate checks against an existing --target workspace")
    return p.parse_args()


def preflight(args: argparse.Namespace) -> str | None:
    """Returns the resolved feed URL (feed mode) or None (local mode)."""
    for tool, probe in [(args.agent, ["--version"]), ("dotnet", ["--version"]), ("git", ["--version"])]:
        exe = shutil.which(tool)
        if not exe:
            fail(f"required CLI not found on PATH: {tool}")
        if subprocess.run([exe, *probe], capture_output=True).returncode != 0:
            fail(f"{tool} {probe[0]} failed - broken install?")
    docker = shutil.which("docker")
    if not docker or subprocess.run([docker, "info"], capture_output=True).returncode != 0:
        fail("Docker is not running - the full golden-path profile needs it (Aspire/5b). Start Docker and retry.")

    if args.package_strategy == "local":
        log(f"package strategy: local (explicit bypass) - Phase 4 generates src/Packages/{args.package_prefix}.*")
        return None
    feed_url = detect_global_feed(args.feed_url)
    if not feed_url:
        fail("no machine/user-level package feed configured; set one up per "
             "support/operator-setup.md Shared Base-Type Readiness, or bypass with --package-strategy local")
    log(f"package strategy: feed - using {feed_url}")
    return feed_url


def main() -> int:
    args = parse_args()
    phases = [p.strip() for p in args.phases.split(",") if p.strip()]
    for p in phases:
        if p not in PHASE_ORDER:
            fail(f"unknown phase '{p}' (valid: {', '.join(PHASE_ORDER)})")
    phases.sort(key=PHASE_ORDER.index)

    feed_url = preflight(args) if not args.dry_run else (
        detect_global_feed(args.feed_url) if args.package_strategy == "feed" else None)

    doc = GOLDEN_PATH_DOC.read_text(encoding="utf-8")
    fixtures: dict[str, str] = {}
    for heading, lang, rel in FIXTURE_BLOCKS:
        fixtures[rel] = extract_fenced_block(doc, heading, lang)
    fixtures[".scaffold/resource-implementation.yaml"] = transform_resource_yaml(
        fixtures[".scaffold/resource-implementation.yaml"], args.package_strategy, feed_url, args.package_prefix)
    sanity_check_resource_yaml(fixtures[".scaffold/resource-implementation.yaml"])
    prompts = extract_prompts()

    timestamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    target = args.target or Path(tempfile.gettempdir()) / f"workboard-gp-{timestamp}"
    report_dir = REPORT_ROOT / timestamp

    if args.dry_run:
        print(f"\n=== DRY RUN (agent: {args.agent}, strategy: {args.package_strategy}"
              f"{', feed ' + feed_url if feed_url else ''}) ===")
        print(f"workspace would be: {target}")
        print(f"report would be:    {report_dir / 'report.md'}")
        print("\n--- transformed .scaffold/resource-implementation.yaml ---")
        print(fixtures[".scaffold/resource-implementation.yaml"])
        print("\n--- HANDOFF.md fixture ---")
        print(HANDOFF_FIXTURE)
        for phase in phases:
            print(f"\n--- phase {phase} prompt ({args.agent}, max-turns "
                  f"{DEFAULT_MAX_TURNS[phase]}, timeout {args.timeout_minutes}m) ---")
            print(prompts[phase])
        print("\n--- gates ---")
        print("3: implementation-plan.md exists + HANDOFF currentPhase=4")
        print("4: dotnet build + HANDOFF contractsScaffolded=true")
        print("5a: dotnet build + dotnet test --filter TestCategory=Unit")
        print('5b: dotnet build + dotnet test --filter "TestCategory=Unit|TestCategory=Endpoint"')
        return 0

    fresh_workspace = not (target / ".instructions").exists()
    if fresh_workspace:
        log(f"workspace: {target}")
        target.mkdir(parents=True, exist_ok=True)
        install = subprocess.run([sys.executable, str(INSTALLER), "--target", str(target), "--verify"],
                                 capture_output=True, text=True, encoding="utf-8", errors="replace")
        if install.returncode != 0:
            fail(f"installer failed:\n{install.stdout}\n{install.stderr}")
        for rel, content in fixtures.items():
            dest = target / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(content + "\n", encoding="utf-8")
        (target / "HANDOFF.md").write_text(HANDOFF_FIXTURE, encoding="utf-8")
        for cmd in (["git", "init"], ["git", "add", "."], ["git", "commit", "-m", "golden-path fixture baseline"]):
            subprocess.run(cmd, cwd=str(target), capture_output=True)
    else:
        log(f"resuming existing workspace: {target}")

    report_dir.mkdir(parents=True, exist_ok=True)
    report_lines = [f"# Golden-path regression run {timestamp}",
                    f"- agent: {args.agent} (model: {args.model or 'cli default'})",
                    f"- packageStrategy: {args.package_strategy}"
                    + (f" ({feed_url})" if feed_url else f" (prefix {args.package_prefix})"),
                    f"- workspace: {target}", ""]
    overall_ok = True

    for phase in phases:
        if args.gate_only:
            started = time.monotonic()
            gate_ok, gate_notes = gate(phase, target)
            duration = int(time.monotonic() - started)
            status = "PASS" if gate_ok else "FAIL"
            exit_code = 0 if gate_ok else 1
            meta = {"gate_only": True}
            log(f"phase {phase}: gate-only {'PASS' if gate_ok else 'FAIL'} ({duration}s)")
        else:
            log(f"phase {phase}: starting {args.agent} session")
            started = time.monotonic()
            exit_code, meta = DRIVERS[args.agent](prompts[phase], target, args, phase, report_dir)
            duration = int(time.monotonic() - started)
            gate_ok, gate_notes = gate(phase, target)
            status = "PASS" if (exit_code == 0 and gate_ok) else "FAIL"
            log(f"phase {phase}: agent exit {exit_code}, gate {'PASS' if gate_ok else 'FAIL'} ({duration}s)")
        report_lines += [f"## Phase {phase} - {status}",
                         f"- agent exit code: {exit_code}, duration: {duration}s",
                         f"- metadata: {json.dumps(meta, default=str)}",
                         *[f"- gate: {n}" for n in gate_notes], ""]
        if status == "FAIL":
            overall_ok = False
            break

    for artifact in ("HANDOFF.md", ".scaffold/INSTRUCTION-GAPS.md"):
        src = target / artifact
        if src.exists():
            shutil.copy2(src, report_dir / src.name)

    report_lines += ["## Result", f"- {'PASS' if overall_ok else 'FAIL'}",
                     f"- workspace kept at: {target}",
                     "- manual follow-up (not gated here): dotnet run --project src/Host/Aspire/AppHost", ""]
    report_path = report_dir / "report.md"
    report_path.write_text("\n".join(report_lines), encoding="utf-8")
    log(f"report: {report_path}")
    log(f"{'PASS' if overall_ok else 'FAIL'} - workspace kept at {target}")
    return 0 if overall_ok else 1


if __name__ == "__main__":
    sys.exit(main())
