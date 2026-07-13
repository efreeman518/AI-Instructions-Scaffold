#!/usr/bin/env python3
"""
Author-side sanity check for the AI-Instructions-Scaffold repo.

Catches drift before it reaches a consumer app. Run from the repo root:

    python scripts/validate-instructions.py
    py -3 scripts/validate-instructions.py        # Windows fallback

Checks:
  - Relative-link integrity in every Markdown file (no broken `../` paths).
  - Phase labels in instruction prose match the canonical set
    (Phase 1, Phase 2, Phase 3, Phase 4, Phase 5, 5a, 5b, 5c, 5d, 5e).
  - Each .claude/commands/*.md and .github/agents/*.md has the expected sections.
  - Each scaffold command/agent carries the maintenance-repo guard that stops
    accidental generation when `.instructions/` is missing.
  - The payload shape declared in install-to-project.py covers every top-level
    runtime directory present in this repo (catches "added skills/foo, forgot
    to wire it into the installer" mistakes).
  - Installer smoke checks cover every first-class harness entrypoint.
  - README install-table parity: every file in the installer's INSTRUCTIONS_FILES
    and every dir in INSTRUCTIONS_DIRS appears in README.md's "What it places"
    table (catches "installer copies GROUND-RULES.md, README table forgot it").
  - Bare-version prose guard (GR-08): no unallowlisted semver-looking string
    (x.y.z) in payload markdown. IP addresses are excluded; the quarantined
    version-pin owner (skills/ai-integration.md) and reasoned constraints are
    allowlisted in VERSION_PROSE_ALLOWLIST.
  - Section-anchor existence: when prose says ``[label](file.md) section Section Name``
    or ``file.md -> Section Name`` (with the path in backticks), verify the named
    section exists as a heading in the target file. Catches refs left dangling
    after file splits.
  - Phase 5 load-set integrity: every skill/template/pattern named in the
    ai/SKILL.md "Phase 5 file table" (and its base-context line) resolves to a
    real file. The table references targets by backtick short-name, not by
    markdown link, so check_links does not cover them - a renamed or deleted
    skill/template would otherwise drift silently.
  - Whole-file Markdown fence guard: no instruction file may wrap itself in a
    top-level code fence, because that hides headings and links from renderers
    and from the link/anchor checks below.
  - Golden-path schema integrity: the expected Phase 1 / Phase 2 YAML blocks in
    support/golden-path-sample.md stay consistent with schemas/*.schema.json
    (required keys, declared keys, enum values). Structural line-parse checks
    run with stdlib only; when pyyaml + jsonschema are installed (e.g. in CI),
    full schema validation runs as well.
  - EF package API integrity: the types and members documented in
    support/ef-packages-reference.md exist in the installed NuGet package
    assemblies. Catches docs/package drift before a golden-path run surfaces it
    as a build failure. Skips gracefully when dotnet is not on PATH or when the
    packages are not in the local NuGet cache (expected in CI without feed).

Exit code 0 if all checks pass, 1 otherwise. Output groups failures by file.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Iterable
from pathlib import Path

# Force UTF-8 stdout/stderr so ASCII-converted diagnostics stay stable on
# Windows consoles that default to cp1252.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

INSTRUCTIONS_ROOT = Path(__file__).resolve().parent.parent
APP_ROOT = INSTRUCTIONS_ROOT.parent if INSTRUCTIONS_ROOT.name == ".instructions" else INSTRUCTIONS_ROOT
REPO_ROOT = INSTRUCTIONS_ROOT

# Directories the runtime payload should ship. Must match install-to-project.py.
EXPECTED_RUNTIME_DIRS = {"ai", "patterns", "profiles", "schemas", "skills", "support", "templates", "scripts"}

# GR-08 bare-version prose guard. Semver-looking string (x.y.z) allowed only when
# listed here. Value None allowlists the whole file (quarantined version-pin owner);
# a set allowlists exact version strings (each must carry an inline reason in the file).
VERSION_PROSE_ALLOWLIST: dict[str, set[str] | None] = {
    "skills/ai-integration.md": None,  # quarantined preview-pin owner (canary-guarded)
    "skills/package-dependencies.md": {"9.2.0", "1.0.104", "0.1.0"},  # GR-08 rule's own counter-examples + packable default
    "skills/azure-data-storage.md": {"1.12.0", "10.0.2"},  # minimum-version constraints with inline reasons
    "skills/ui-uno-platforms.md": {"1.12.1"},  # upstream Resizetizer bug citation
    "ai/implementation-plan.md": {"0.1.0"},  # packable project default version
    "GROUND-RULES.md": {"1.0.104"},  # GR-08 rule's own counter-example
    "support/tech-design-diagrams.md": {"10.9.1"},  # mermaid-cli pin for deterministic SVG rendering (inline reason)
    "templates/local-test-stack-template.md": {"2.0.0"},  # JSON manifest format version, not a package version
}

# Author-side directories that must NOT be in the runtime payload.
AUTHOR_ONLY_DIRS = {"tests", ".github/workflows", ".githooks", ".vscode", ".venv", ".tmp"}

# Markdown roots to walk. Skip vendored/temporary trees.
RUNTIME_SCAN_ROOTS = ["ai", "patterns", "profiles", "schemas", "skills", "support", "templates"]
HARNESS_SCAN_ROOTS = [".claude", ".github"]
INSTRUCTIONS_TOP_LEVEL_MD = ["README.md", "START-AI.md", "AGENTS.md", "GROUND-RULES.md"]
APP_TOP_LEVEL_MD = ["AGENTS.md", "CLAUDE.md"]

EXCLUDE_PARTS = {"__pycache__", ".git", ".venv", ".tmp", ".vscode", ".githooks", "tests", "bin", "obj", "node_modules"}

# Recognized phase tokens. Anything matching the pattern but not on this list is flagged.
CANONICAL_PHASES = {"Phase 1", "Phase 2", "Phase 3", "Phase 4", "Phase 5", "Phase 5a", "Phase 5b", "Phase 5c", "Phase 5d", "Phase 5e"}
PHASE_PATTERN = re.compile(r"\bPhase\s+(\d+[a-z]?)\b")

# Inline link pattern: [text](target). Skip absolute URLs and anchors-only.
LINK_PATTERN = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")

# Fenced code blocks can contain scaffold examples with placeholder links.
FENCED_CODE_PATTERN = re.compile(r"(^|\n)[ \t]{0,3}(`{3,}|~{3,})[^\n]*\n.*?\n[ \t]{0,3}\2[ \t]*(?=\n|$)", re.DOTALL)

# A whole instruction file wrapped in a fence renders as one code block, not as
# documentation. This also makes the link/anchor checks below strip the file.
WHOLE_FILE_FENCE_PATTERN = re.compile(r"^\s*(`{3,}|~{3,})[A-Za-z0-9_-]*\s*\n.*\n\s*\1\s*$", re.DOTALL)

# Markdown headings (ATX style) for the section-anchor check.
HEADING_PATTERN = re.compile(r"^#{1,6}\s+(.+?)\s*$", re.MULTILINE)

# Prose pattern: `[label](file.md) section Section`, `[label](file.md) -> *Section*`,
# or the same with a backtick-wrapped path instead of a link. Captures:
#   group "linkpath": path inside (...) - None for backtick form
#   group "tickpath": path inside `...` - None for link form
#   group "section":  raw section text (may include leading/trailing `*`)
SECTION_REF_PATTERN = re.compile(
    r"(?:\[[^\]]+\]\((?P<linkpath>[^)]+?\.md)(?:#[^)]*)?\)|`(?P<tickpath>[^`]+?\.md)`)"
    r"\s*(?:section|->)\s*"
    r"(?P<section>(?:\*[^*\n]{1,80}\*|[^\n.|,)(`*]{1,80}))"
)

# Connectors that end a section name when used like `... see X.md section Foo and bar baz`.
SECTION_TAIL_CONNECTOR = re.compile(
    r"\s+(and|or|see|for|in|of|on|via|when|to|with|before|after|then)\b.*$",
    re.IGNORECASE,
)

# Required section headings in harness command/agent files.
REQUIRED_COMMAND_HEADINGS = {
    ".claude/commands/scaffold.md": ["Instructions", "Rules"],
    ".claude/commands/vertical-slice.md": ["Instructions", "Pre-Flight", "Rules"],
    ".claude/commands/scaffold-adopt.md": ["Instructions", "Pre-Flight", "Rules"],
    ".github/agents/dotnet-scaffold.agent.md": ["Bootstrap", "Core Rules"],
    ".github/agents/vertical-slice.agent.md": ["Bootstrap", "Pre-Flight", "Constraints"],
    ".github/agents/scaffold-adopt.agent.md": ["Bootstrap", "Pre-Flight", "Constraints"],
}

MAINTENANCE_GUARD_PHRASES = ["Maintenance-repo note", "If `.instructions/` is missing"]

EXPECTED_SMOKE_CHECK_HARNESS_ENTRYPOINTS = {
    "AGENTS.md",
    "CLAUDE.md",
    ".github/copilot-instructions.md",
    ".claude/commands/scaffold.md",
    ".claude/commands/vertical-slice.md",
    ".claude/commands/scaffold-adopt.md",
    ".github/agents/dotnet-scaffold.agent.md",
    ".github/agents/vertical-slice.agent.md",
    ".github/agents/scaffold-adopt.agent.md",
}


class Findings:
    def __init__(self) -> None:
        self.errors: list[tuple[Path, str]] = []
        self.warnings: list[tuple[Path, str]] = []

    def err(self, path: Path, msg: str) -> None:
        self.errors.append((path, msg))

    def warn(self, path: Path, msg: str) -> None:
        self.warnings.append((path, msg))

    def report(self) -> int:
        if not self.errors and not self.warnings:
            print("[ok] all checks passed")
            return 0

        if self.errors:
            print(f"[fail] {len(self.errors)} error(s):")
            grouped: dict[Path, list[str]] = {}
            for path, msg in self.errors:
                grouped.setdefault(path, []).append(msg)
            for path in sorted(grouped, key=lambda p: str(p)):
                print(f"  {display_path(path)}")
                for msg in grouped[path]:
                    print(f"    - {msg}")

        if self.warnings:
            print()
            print(f"[warn] {len(self.warnings)} warning(s):")
            grouped_w: dict[Path, list[str]] = {}
            for path, msg in self.warnings:
                grouped_w.setdefault(path, []).append(msg)
            for path in sorted(grouped_w, key=lambda p: str(p)):
                print(f"  {display_path(path)}")
                for msg in grouped_w[path]:
                    print(f"    - {msg}")

        return 1 if self.errors else 0


def display_path(path: Path) -> str:
    for root in (INSTRUCTIONS_ROOT, APP_ROOT):
        try:
            return path.relative_to(root).as_posix()
        except ValueError:
            continue
    return str(path)


def strip_fenced_code_blocks(text: str) -> str:
    """Remove fenced code while preserving line numbers for diagnostics."""

    def replace_with_blank_lines(match: re.Match[str]) -> str:
        return "\n" * match.group(0).count("\n")

    return FENCED_CODE_PATTERN.sub(replace_with_blank_lines, text)


def iter_markdown_files() -> list[Path]:
    files_by_path: dict[Path, None] = {}
    for top in INSTRUCTIONS_TOP_LEVEL_MD:
        p = INSTRUCTIONS_ROOT / top
        if p.exists():
            files_by_path[p] = None
    for top in APP_TOP_LEVEL_MD:
        p = APP_ROOT / top
        if p.exists():
            files_by_path[p] = None
    for root in RUNTIME_SCAN_ROOTS:
        base = INSTRUCTIONS_ROOT / root
        if not base.exists():
            continue
        for path in base.rglob("*.md"):
            if any(part in EXCLUDE_PARTS for part in path.relative_to(INSTRUCTIONS_ROOT).parts):
                continue
            files_by_path[path] = None
    for root in HARNESS_SCAN_ROOTS:
        base = APP_ROOT / root
        if not base.exists():
            continue
        for path in base.rglob("*.md"):
            if any(part in EXCLUDE_PARTS for part in path.relative_to(APP_ROOT).parts):
                continue
            files_by_path[path] = None
    return list(files_by_path.keys())


def check_links(path: Path, findings: Findings) -> None:
    text = strip_fenced_code_blocks(path.read_text(encoding="utf-8"))
    # Adjacent-duplicate detection: same [label](target) appearing twice in the
    # same line (the drift pattern we want to catch - copy/paste with no edit).
    for line_no, line in enumerate(text.splitlines(), start=1):
        line_seen: dict[tuple[str, str], int] = {}
        for match in LINK_PATTERN.finditer(line):
            key = (match.group(1), match.group(2).strip())
            if key in line_seen:
                findings.warn(path, f"line {line_no}: link [{key[0]}]({key[1]}) appears twice on the same line")
            line_seen[key] = match.start()

    for match in LINK_PATTERN.finditer(text):
        label, target = match.group(1), match.group(2).strip()
        if target.startswith(("http://", "https://", "mailto:", "#")):
            continue
        # Strip anchor.
        link_path = target.split("#", 1)[0]
        if not link_path:
            continue
        # Resolve relative to the file's parent.
        candidate = (path.parent / link_path).resolve()
        if not candidate.exists():
            findings.err(path, f"broken link: [{label}]({target}) -> {candidate}")


def check_phase_labels(path: Path, findings: Findings) -> None:
    text = path.read_text(encoding="utf-8")
    for match in PHASE_PATTERN.finditer(text):
        token = "Phase " + match.group(1)
        if token not in CANONICAL_PHASES:
            line_no = text.count("\n", 0, match.start()) + 1
            findings.err(path, f"line {line_no}: unrecognized phase token '{token}' (canonical: 1-5, 5a-5e)")


def check_whole_file_fence(path: Path, findings: Findings) -> None:
    text = path.read_text(encoding="utf-8")
    if WHOLE_FILE_FENCE_PATTERN.match(text):
        findings.err(path, "whole file is wrapped in a Markdown code fence; remove the outer fence so headings and links render")


def collect_headings(path: Path, cache: dict[Path, list[str]]) -> list[str]:
    if path in cache:
        return cache[path]
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        cache[path] = []
        return cache[path]
    cache[path] = [m.group(1).strip() for m in HEADING_PATTERN.finditer(text)]
    return cache[path]


def normalize_text(s: str) -> str:
    return re.sub(r"\s+", " ", s).strip().lower()


def heading_matches_section(headings: list[str], target: str) -> bool:
    if not target:
        return False
    target_n = normalize_text(target)
    for h in headings:
        h_n = normalize_text(h)
        if h_n == target_n:
            return True
        # Prefix match for headings like "Menu Navigation: Always Land On Top Page"
        # vs reference "Menu Navigation".
        if h_n.startswith(target_n + " ") or h_n.startswith(target_n + ":") or h_n.startswith(target_n + " -"):
            return True
        # Substring fallback for short identifiers like "5a" -> "5a - Foundation (TDD)".
        if len(target_n) <= 6 and target_n in h_n:
            return True
    return False


def check_section_anchors(path: Path, findings: Findings, headings_cache: dict[Path, list[str]]) -> None:
    text = strip_fenced_code_blocks(path.read_text(encoding="utf-8"))
    for line_no, line in enumerate(text.splitlines(), start=1):
        for match in SECTION_REF_PATTERN.finditer(line):
            target_link = match.group("linkpath") or match.group("tickpath")
            section = match.group("section").strip().strip("*").strip()
            section = re.sub(r"\s+-\s+.*$", "", section)
            section = SECTION_TAIL_CONNECTOR.sub("", section)
            section = section.rstrip(".,;:")
            if not section or len(section) < 2:
                continue
            link_path = target_link.split("#", 1)[0]
            try:
                candidate = (path.parent / link_path).resolve()
            except (OSError, ValueError):
                continue
            if not candidate.exists() or not candidate.is_file() or candidate.suffix != ".md":
                # Broken file path - handled by check_links.
                continue
            headings = collect_headings(candidate, headings_cache)
            if not heading_matches_section(headings, section):
                rel = display_path(candidate)
                findings.err(
                    path,
                    f"line {line_no}: section anchor not found - {rel} has no heading matching '{section}'",
                )


REFAPP_COUNT_PATTERNS = [
    re.compile(r"reported\s+\d+\s+passed", re.IGNORECASE),
    re.compile(r"\d+\s+passed,\s*\d+\s+warning", re.IGNORECASE),
    re.compile(r"\b\d+\s+tests?\s+(?:passed|passing|green)\b", re.IGNORECASE),
]


def check_refapp_count_claims(path: Path, findings: Findings) -> None:
    """Reference-app build/test counts drift the moment the app changes. They
    belong only in the reference app's .scaffold/REFERENCE-STATUS.md (the SSOT);
    the instruction set must link to it, not restate a number. Flag the drift
    signatures (e.g. 'reported 410 passed, 0 warnings')."""
    text = path.read_text(encoding="utf-8")
    for line_no, line in enumerate(text.splitlines(), start=1):
        for pat in REFAPP_COUNT_PATTERNS:
            match = pat.search(line)
            if match:
                findings.err(
                    path,
                    f"line {line_no}: hard-coded reference-app count ({match.group(0)!r}); "
                    "state build/test counts only in the reference app's "
                    ".scaffold/REFERENCE-STATUS.md and link to it",
                )


def check_command_shape(findings: Findings) -> None:
    for rel, required_headings in REQUIRED_COMMAND_HEADINGS.items():
        path = APP_ROOT / rel
        if not path.exists():
            findings.err(path, "expected command/agent file is missing")
            continue
        text = path.read_text(encoding="utf-8")
        for heading in required_headings:
            # Match `## Heading` or `## Heading ...` exactly at line start.
            pattern = re.compile(rf"^##\s+{re.escape(heading)}\b", re.MULTILINE)
            if not pattern.search(text):
                findings.err(path, f"missing required heading '## {heading}'")


def check_maintenance_guards(findings: Findings) -> None:
    for rel in REQUIRED_COMMAND_HEADINGS:
        path = APP_ROOT / rel
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        for phrase in MAINTENANCE_GUARD_PHRASES:
            if phrase not in text:
                findings.err(path, f"missing maintenance-repo guard phrase: {phrase}")


def check_payload_shape(findings: Findings) -> None:
    """Compare what install-to-project.py copies vs what's actually present at the repo root."""
    installer = INSTRUCTIONS_ROOT / "scripts" / "install-to-project.py"
    if not installer.exists():
        findings.err(installer, "install-to-project.py is missing - payload shape unverifiable")
        return
    text = installer.read_text(encoding="utf-8")
    # Extract the INSTRUCTIONS_DIRS list literal.
    match = re.search(r"INSTRUCTIONS_DIRS\s*=\s*\[(.*?)\]", text, re.DOTALL)
    if not match:
        findings.err(installer, "could not parse INSTRUCTIONS_DIRS list")
        return
    declared = set(re.findall(r'"([^"]+)"', match.group(1)))

    if declared != EXPECTED_RUNTIME_DIRS:
        missing = EXPECTED_RUNTIME_DIRS - declared
        extra = declared - EXPECTED_RUNTIME_DIRS
        if missing:
            findings.err(installer, f"INSTRUCTIONS_DIRS missing dirs the validator expects: {sorted(missing)}")
        if extra:
            findings.err(installer, f"INSTRUCTIONS_DIRS contains unexpected dirs: {sorted(extra)} (update validator if intentional)")

    # Each declared dir must exist in the repo with at least one file.
    for d in declared:
        target = INSTRUCTIONS_ROOT / d
        if not target.exists() or not target.is_dir():
            findings.err(installer, f"declared payload dir '{d}/' missing or not a directory")
        elif not any(target.iterdir()):
            findings.warn(installer, f"declared payload dir '{d}/' is empty")

    smoke_match = re.search(r"SMOKE_CHECK_HARNESS_ENTRYPOINTS\s*=\s*\[(.*?)\]", text, re.DOTALL)
    if not smoke_match:
        findings.err(installer, "could not parse SMOKE_CHECK_HARNESS_ENTRYPOINTS list")
        return
    smoke_declared = set(re.findall(r'"([^"]+)"', smoke_match.group(1)))
    if smoke_declared != EXPECTED_SMOKE_CHECK_HARNESS_ENTRYPOINTS:
        missing = EXPECTED_SMOKE_CHECK_HARNESS_ENTRYPOINTS - smoke_declared
        extra = smoke_declared - EXPECTED_SMOKE_CHECK_HARNESS_ENTRYPOINTS
        if missing:
            findings.err(installer, f"SMOKE_CHECK_HARNESS_ENTRYPOINTS missing first-class entrypoints: {sorted(missing)}")
        if extra:
            findings.err(installer, f"SMOKE_CHECK_HARNESS_ENTRYPOINTS contains unexpected entries: {sorted(extra)}")


def check_readme_install_table(findings: Findings) -> None:
    """README's 'What it places' table must name every INSTRUCTIONS_FILES file and INSTRUCTIONS_DIRS dir."""
    installer = INSTRUCTIONS_ROOT / "scripts" / "install-to-project.py"
    readme = INSTRUCTIONS_ROOT / "README.md"
    if not installer.exists() or not readme.exists():
        return  # missing files reported elsewhere
    text = installer.read_text(encoding="utf-8")
    files_match = re.search(r"INSTRUCTIONS_FILES\s*=\s*\[(.*?)\]", text, re.DOTALL)
    dirs_match = re.search(r"INSTRUCTIONS_DIRS\s*=\s*\[(.*?)\]", text, re.DOTALL)
    if not files_match or not dirs_match:
        findings.err(installer, "could not parse INSTRUCTIONS_FILES/INSTRUCTIONS_DIRS for README table parity")
        return
    payload_files = set(re.findall(r'"([^"]+)"', files_match.group(1)))
    payload_dirs = set(re.findall(r'"([^"]+)"', dirs_match.group(1)))

    readme_lines = readme.read_text(encoding="utf-8").splitlines()
    table: list[str] = []
    in_region = False
    for line in readme_lines:
        if line.strip() == "What it places:":
            in_region = True
            continue
        if in_region:
            if line.startswith("|"):
                table.append(line)
            elif table:
                break  # table ended
    if not table:
        findings.err(readme, "could not find the 'What it places' table for install-manifest parity check")
        return
    table_text = "\n".join(table)
    for f in sorted(payload_files):
        if f"`{f}`" not in table_text:
            findings.err(readme, f"'What it places' table omits `{f}` (installer INSTRUCTIONS_FILES copies it)")
    for d in sorted(payload_dirs):
        if f"`{d}/`" not in table_text:
            findings.err(readme, f"'What it places' table omits `{d}/` (installer INSTRUCTIONS_DIRS copies it)")


# Matches x.y.z(-suffix) but not segments of 4-part dotted quads (IP addresses).
BARE_VERSION_PATTERN = re.compile(r"(?<![\d.])\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?(?![.\d])")


def check_version_prose(path: Path, findings: Findings) -> None:
    """GR-08 guard: bare semver-looking strings in payload markdown must be allowlisted."""
    try:
        rel = path.relative_to(INSTRUCTIONS_ROOT).as_posix()
    except ValueError:
        rel = path.name  # APP_ROOT harness file outside the instructions root
    allowed = VERSION_PROSE_ALLOWLIST.get(rel, set())
    if allowed is None:
        return  # whole file quarantined
    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        for m in BARE_VERSION_PATTERN.finditer(line):
            if m.group(0) not in allowed:
                findings.err(
                    path,
                    f"line {line_no}: bare version '{m.group(0)}' in payload prose (GR-08) - "
                    "use <latest-stable>/$(LatestStableTfm), or allowlist it in VERSION_PROSE_ALLOWLIST with an inline reason",
                )


# --- Phase 5 load-set table (GAP-003) ---------------------------------------
# The "Phase 5 file table" in ai/SKILL.md lists skills/templates/patterns by
# short backtick name (e.g. `domain-model`, `entity`, `patterns/data-layer-wiring`),
# not as markdown links, so check_links cannot catch a renamed/deleted target.
# Resolve every backtick file-token in the table rows against the filesystem.

PHASE5_SKILL_REL = "ai/SKILL.md"
PHASE5_TABLE_HEADING = "## Phase 5 file table"
BACKTICK_SPAN_PATTERN = re.compile(r"`([^`]+)`")
# A load-set file token is one or more lowercase-kebab segments, optionally
# joined by '/'. This deliberately excludes camelCase config keys
# (`includeFlowEngine: true`), code spans (`MapFlowEngineAdmin(...)`),
# dotted file names (`RegisterServices.FlowEngine.cs`), and brace tokens
# (`{Entity}RepositoryIntegrationTests`) that also appear in backticks.
LOADSET_TOKEN_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*(?:/[a-z0-9]+(?:-[a-z0-9]+)*)*$")
# Column order of the table after splitting on '|': subphase, then these three.
LOADSET_COLUMN_KINDS = ["subphase", "skills", "templates", "ondemand"]


def _resolve_loadset_token(token: str, kind: str) -> list[Path]:
    """Candidate paths a load-set token may map to, given its column kind."""
    candidates: list[Path] = []
    if "/" in token:  # path-form token, e.g. patterns/data-layer-wiring
        candidates.append(INSTRUCTIONS_ROOT / (token + ".md"))
    if kind == "skills":
        candidates.append(INSTRUCTIONS_ROOT / "skills" / (token + ".md"))
    elif kind == "templates":
        # Most templates use the -template suffix; a few (test-templates-*) do not.
        candidates.append(INSTRUCTIONS_ROOT / "templates" / (token + "-template.md"))
        candidates.append(INSTRUCTIONS_ROOT / "templates" / (token + ".md"))
    else:  # on-demand column mixes skills, templates, and patterns
        candidates.append(INSTRUCTIONS_ROOT / "skills" / (token + ".md"))
        candidates.append(INSTRUCTIONS_ROOT / "templates" / (token + "-template.md"))
        candidates.append(INSTRUCTIONS_ROOT / "templates" / (token + ".md"))
    return candidates


def check_phase5_load_set(findings: Findings) -> None:
    skill_path = INSTRUCTIONS_ROOT / PHASE5_SKILL_REL
    if not skill_path.exists():
        findings.err(skill_path, "ai/SKILL.md missing - cannot validate Phase 5 load-set table")
        return
    lines = skill_path.read_text(encoding="utf-8").splitlines()

    start = next((i for i, ln in enumerate(lines) if ln.strip() == PHASE5_TABLE_HEADING), None)
    if start is None:
        findings.err(skill_path, f"section '{PHASE5_TABLE_HEADING}' not found - load-set table moved or renamed")
        return
    end = next((j for j in range(start + 1, len(lines)) if lines[j].startswith("## ")), len(lines))

    checked = 0
    for offset, line in enumerate(lines[start:end]):
        line_no = start + offset + 1
        stripped = line.strip()

        # Base-context line: validate `path/with.md` style references too.
        if "base context" in stripped.lower():
            for span in BACKTICK_SPAN_PATTERN.findall(line):
                span = span.strip()
                if span.endswith(".md") and "/" in span and " " not in span:
                    checked += 1
                    cand = INSTRUCTIONS_ROOT / span
                    if not cand.exists():
                        findings.err(skill_path, f"line {line_no}: base-context file `{span}` not found")
            continue

        # Table data rows: first cell is **5a..5e ...**.
        if not stripped.startswith("|"):
            continue
        cells = [c.strip() for c in stripped.strip("|").split("|")]
        if len(cells) < 4 or not re.match(r"\*\*5[a-e]\b", cells[0]):
            continue
        for idx, cell in enumerate(cells[1:4], start=1):
            kind = LOADSET_COLUMN_KINDS[idx]
            for span in BACKTICK_SPAN_PATTERN.findall(cell):
                token = span.strip()
                if not LOADSET_TOKEN_PATTERN.match(token):
                    continue
                checked += 1
                candidates = _resolve_loadset_token(token, kind)
                if not any(c.exists() for c in candidates):
                    tried = ", ".join(display_path(c) for c in candidates)
                    findings.err(
                        skill_path,
                        f"line {line_no}: Phase 5 load-set reference `{token}` ({kind}) resolves to no file (tried: {tried})",
                    )

    if checked == 0:
        findings.warn(skill_path, "Phase 5 load-set check matched 0 file tokens - table format may have changed")


# --- Phase 5 reverse coverage (templates) -----------------------------------
# check_phase5_load_set is one-directional: every token IN the table must
# resolve to a file. This is the reverse: every template in templates/ must be
# REACHABLE from the Phase 5 table (or be an explicitly-exempt Phase-1 universal
# / structural index). Catches the recurring drift where a new template is added
# and routed in templates/index.md but never wired into ai/SKILL.md's table, so
# an agent following the "load only what the table lists" rule never loads it.
# Templates only: Phase-4 skills (solution-structure, package-dependencies) are
# legitimately absent from the Phase 5 table, so skills are out of scope here.
PHASE5_TEMPLATE_EXEMPT = {
    "design-decisions-template",  # Phase 1 universal (START-AI Phase Router)
    "ubiquitous-language-template",  # Phase 1 universal
    "index",  # the template index itself
    "test-templates",  # test-template routing index, not a code template
}


def check_phase5_template_coverage(findings: Findings) -> None:
    skill_path = INSTRUCTIONS_ROOT / PHASE5_SKILL_REL
    templates_dir = INSTRUCTIONS_ROOT / "templates"
    if not skill_path.exists() or not templates_dir.is_dir():
        return
    lines = skill_path.read_text(encoding="utf-8").splitlines()
    start = next((i for i, ln in enumerate(lines) if ln.strip() == PHASE5_TABLE_HEADING), None)
    if start is None:
        return  # check_phase5_load_set already errors on a missing heading
    end = next((j for j in range(start + 1, len(lines)) if lines[j].startswith("## ")), len(lines))

    referenced: set[Path] = set()
    for line in lines[start:end]:
        stripped = line.strip()
        if not stripped.startswith("|"):
            continue
        cells = [c.strip() for c in stripped.strip("|").split("|")]
        if len(cells) < 4 or not re.match(r"\*\*5[a-e]\b", cells[0]):
            continue
        # Templates column (idx 2) and on-demand column (idx 3) can name templates.
        for idx in (2, 3):
            kind = LOADSET_COLUMN_KINDS[idx]
            for span in BACKTICK_SPAN_PATTERN.findall(cells[idx]):
                token = span.strip()
                if not LOADSET_TOKEN_PATTERN.match(token):
                    continue
                for cand in _resolve_loadset_token(token, kind):
                    if cand.parent == templates_dir and cand.exists():
                        referenced.add(cand)

    missing = []
    for tmpl in sorted(templates_dir.glob("*.md")):
        if tmpl.stem in PHASE5_TEMPLATE_EXEMPT:
            continue
        if tmpl not in referenced:
            missing.append(tmpl.name)
    for name in missing:
        findings.err(
            skill_path,
            f"template templates/{name} is not reachable from the Phase 5 file table "
            f"(add it to the matching sub-phase row, or to PHASE5_TEMPLATE_EXEMPT if it is a Phase-1/structural file)",
        )


# --- Phase 5 load-set token budget --------------------------------------------
# Tracks curated raw-source load-set growth alongside the OPERATIONS.md
# "Context Budgets" advisory. The required set (session base + skills +
# templates columns) stays under its measured ceiling, and the full set
# (+ on-demand column) stays below a shared ceiling.
# Tokens are estimated as chars/4. Ceilings are ~15% above the measured
# 2026-07-13 unique-file baselines; if this check fires, prefer trimming or splitting the
# offending files over raising the ceiling.

# Session base: files every Phase 5 session loads before the load set.
LOADSET_SESSION_BASE = ["START-AI.md", "GROUND-RULES.md", "ai/SKILL.md"]

# Required set (session base + skills + templates columns + base-context line).
# Measured baselines: 5a ~70k, 5b ~106k, 5c ~84k, 5d ~61k, 5e ~49k tokens.
LOADSET_REQUIRED_CEILINGS = {
    "5a": 80_000,
    "5b": 122_000,
    "5c": 97_000,
    "5d": 70_000,
    "5e": 57_000,
}

# Full set (required + on-demand column). Measured worst: 5b ~139k tokens.
LOADSET_FULL_CEILING = 160_000


def _estimate_tokens(path: Path) -> int:
    try:
        return len(path.read_text(encoding="utf-8")) // 4
    except (OSError, UnicodeDecodeError):
        return 0


def _estimate_unique_tokens(*path_groups: Iterable[Path]) -> int:
    paths = {path for group in path_groups for path in group}
    return sum(_estimate_tokens(path) for path in paths if path.exists())


def check_loadset_token_budget(findings: Findings) -> None:
    skill_path = INSTRUCTIONS_ROOT / PHASE5_SKILL_REL
    if not skill_path.exists():
        return  # check_phase5_load_set already errors
    lines = skill_path.read_text(encoding="utf-8").splitlines()
    start = next((i for i, ln in enumerate(lines) if ln.strip() == PHASE5_TABLE_HEADING), None)
    if start is None:
        return  # check_phase5_load_set already errors
    end = next((j for j in range(start + 1, len(lines)) if lines[j].startswith("## ")), len(lines))

    base_files: list[Path] = [INSTRUCTIONS_ROOT / rel for rel in LOADSET_SESSION_BASE]
    for line in lines[start:end]:
        if "base context" in line.strip().lower():
            for span in BACKTICK_SPAN_PATTERN.findall(line):
                span = span.strip()
                if span.endswith(".md") and "/" in span and " " not in span:
                    base_files.append(INSTRUCTIONS_ROOT / span)
    for line in lines[start:end]:
        stripped = line.strip()
        if not stripped.startswith("|"):
            continue
        cells = [c.strip() for c in stripped.strip("|").split("|")]
        match = re.match(r"\*\*(5[a-e])\b", cells[0]) if len(cells) >= 4 else None
        if not match:
            continue
        sub = match.group(1)

        required: dict[Path, None] = {}
        on_demand: dict[Path, None] = {}
        for idx, bucket in ((1, required), (2, required), (3, on_demand)):
            kind = LOADSET_COLUMN_KINDS[idx]
            for span in BACKTICK_SPAN_PATTERN.findall(cells[idx]):
                token = span.strip()
                if not LOADSET_TOKEN_PATTERN.match(token):
                    continue
                for cand in _resolve_loadset_token(token, kind):
                    if cand.exists():
                        bucket[cand] = None
                        break

        required_tokens = _estimate_unique_tokens(base_files, required)
        full_tokens = _estimate_unique_tokens(base_files, required, on_demand)
        ceiling = LOADSET_REQUIRED_CEILINGS.get(sub)
        if ceiling is not None and required_tokens > ceiling:
            worst = sorted(required, key=_estimate_tokens, reverse=True)[:3]
            worst_desc = ", ".join(f"{display_path(p)} (~{_estimate_tokens(p)})" for p in worst)
            findings.err(
                skill_path,
                f"Phase {sub} required load set ~{required_tokens} tokens exceeds ceiling {ceiling} "
                f"(largest: {worst_desc}) - trim or split before raising the ceiling",
            )
        if full_tokens > LOADSET_FULL_CEILING:
            findings.err(
                skill_path,
                f"Phase {sub} full load set (required + on-demand) ~{full_tokens} tokens exceeds "
                f"ceiling {LOADSET_FULL_CEILING} - trim the on-demand column or split files",
            )


# --- Golden-path schema integrity --------------------------------------------
# The expected YAML blocks in support/golden-path-sample.md are the canonical
# regression fixture for instruction changes. Keep them consistent with the
# machine-readable schemas so doc edits and schema edits cannot drift apart.

GOLDEN_PATH_REL = "support/golden-path-sample.md"
# (label, heading that precedes the yaml block, schema file)
GOLDEN_PATH_BLOCKS = [
    ("Phase 1 domain-specification", "### `.scaffold/domain-specification.yaml`", "schemas/domain-specification.schema.json"),
    ("Phase 2 resource-implementation", "## Expected Phase 2 Output", "schemas/resource-implementation.schema.json"),
    ("Focused AI/Aspire resource-implementation", "## Focused AI/Aspire Schema Fixture", "schemas/resource-implementation.schema.json"),
]
YAML_FENCE_PATTERN = re.compile(r"```yaml\r?\n(.*?)\r?\n```", re.DOTALL)
TOP_KEY_LINE_PATTERN = re.compile(r"^([A-Za-z][A-Za-z0-9]*):(.*)$")


def _extract_yaml_block(text: str, heading: str) -> str | None:
    idx = text.find(heading)
    if idx == -1:
        return None
    match = YAML_FENCE_PATTERN.search(text, idx)
    return match.group(1) if match else None


def _yaml_scalar(raw: str) -> str:
    return raw.strip().strip("'\"")


def _check_block_structure(path: Path, label: str, block: str, schema: dict, findings: Findings) -> None:
    props: dict = schema.get("properties", {})
    required: list[str] = schema.get("required", [])
    defs: dict = schema.get("$defs", {})

    top_keys: list[str] = []
    for line in block.splitlines():
        m = TOP_KEY_LINE_PATTERN.match(line)
        if not m:
            continue
        key, rest = m.group(1), m.group(2)
        top_keys.append(key)
        # Scalar enum check for top-level keys with a declared enum.
        prop = props.get(key)
        if prop and "enum" in prop and rest.strip():
            value = _yaml_scalar(rest)
            if value and value not in prop["enum"]:
                findings.err(path, f"{label}: '{key}: {value}' not in schema enum {prop['enum']}")

    for req in required:
        if req not in top_keys:
            findings.err(path, f"{label}: required key '{req}' missing from the YAML block")
    for key in top_keys:
        if key not in props:
            findings.err(path, f"{label}: key '{key}' is not declared in the schema properties")

    # Phase 1: every `kind:` value must be in the property-kind enum.
    kind_enum = defs.get("property", {}).get("properties", {}).get("kind", {}).get("enum")
    if kind_enum:
        for m in re.finditer(r"^\s+kind:\s*(.+?)\s*$", block, re.MULTILINE):
            value = _yaml_scalar(m.group(1))
            if value not in kind_enum:
                findings.err(path, f"{label}: property kind '{value}' not in schema enum {kind_enum}")

    # Phase 2: every mode under externalDependencyModes must be a valid dependencyMode.
    mode_enum = defs.get("dependencyMode", {}).get("enum")
    if mode_enum and "externalDependencyModes" in top_keys:
        in_modes = False
        for line in block.splitlines():
            if TOP_KEY_LINE_PATTERN.match(line):
                in_modes = line.startswith("externalDependencyModes:")
                continue
            if not in_modes or not line.strip():
                continue
            m = re.match(r"^\s+([A-Za-z][A-Za-z0-9]*):\s*(.+?)\s*$", line)
            if not m or m.group(1) == "externalApis":
                continue
            value = _yaml_scalar(m.group(2))
            if value not in mode_enum:
                findings.err(path, f"{label}: externalDependencyModes.{m.group(1)} = '{value}' not in {mode_enum}")


def check_golden_path_schemas(findings: Findings) -> None:
    import json

    gp_path = INSTRUCTIONS_ROOT / GOLDEN_PATH_REL
    if not gp_path.exists():
        findings.err(gp_path, "golden-path sample missing - schema integrity unverifiable")
        return
    text = gp_path.read_text(encoding="utf-8")

    try:  # optional full validation when the libs are installed (CI installs them)
        import jsonschema  # type: ignore
        import yaml  # type: ignore
    except ImportError:
        jsonschema = yaml = None  # type: ignore

    for label, heading, schema_rel in GOLDEN_PATH_BLOCKS:
        schema_path = INSTRUCTIONS_ROOT / schema_rel
        if not schema_path.exists():
            findings.err(schema_path, f"{label}: schema file missing")
            continue
        try:
            schema = json.loads(schema_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            findings.err(schema_path, f"{label}: schema is not valid JSON ({exc})")
            continue

        block = _extract_yaml_block(text, heading)
        if block is None:
            findings.err(gp_path, f"{label}: no yaml block found after heading '{heading}'")
            continue

        _check_block_structure(gp_path, label, block, schema, findings)

        if yaml is not None and jsonschema is not None:
            try:
                data = yaml.safe_load(block)
                jsonschema.validate(data, schema)
            except yaml.YAMLError as exc:  # type: ignore[union-attr]
                findings.err(gp_path, f"{label}: YAML parse failure ({exc})")
            except jsonschema.ValidationError as exc:  # type: ignore[union-attr]
                findings.err(gp_path, f"{label}: full schema validation failed - {exc.message} (path: {'/'.join(str(p) for p in exc.absolute_path)})")


# --- EF package API integrity ------------------------------------------------
# Verifies that the types/members documented in ef-packages-reference.md
# actually exist in the installed package assemblies.
# Skips gracefully when dotnet is not on PATH or packages are not in the
# local NuGet cache (expected in CI without feed access).

EF_PACKAGES_REL = "support/ef-packages-reference.md"

# (package_id, fully_qualified_type, member_name, "prop"|"static")
EF_API_CLAIMS: list[tuple[str, str, str, str]] = [
    ("EF.Domain.Contracts", "EF.Domain.Contracts.DomainError",  "Error",        "prop"),
    ("EF.Domain.Contracts", "EF.Domain.Contracts.DomainError",  "Code",         "prop"),
    ("EF.Domain.Contracts", "EF.Domain.Contracts.DomainError",  "Message",      "prop"),
    ("EF.Domain.Contracts", "EF.Domain.Contracts.DomainError",  "Create",       "static"),
    ("EF.Domain.Contracts", "EF.Domain.Contracts.DomainResult", "IsSuccess",    "prop"),
    ("EF.Domain.Contracts", "EF.Domain.Contracts.DomainResult", "IsFailure",    "prop"),
    ("EF.Domain.Contracts", "EF.Domain.Contracts.DomainResult", "ErrorMessage", "prop"),
    ("EF.Domain.Contracts", "EF.Domain.Contracts.DomainResult", "Errors",       "prop"),
    ("EF.Domain.Contracts", "EF.Domain.Contracts.DomainResult", "Failure",      "static"),
    ("EF.Domain.Contracts", "EF.Domain.Contracts.DomainResult", "Success",      "static"),
    ("EF.Common.Contracts", "EF.Common.Contracts.Result",       "IsSuccess",    "prop"),
    ("EF.Common.Contracts", "EF.Common.Contracts.Result",       "IsFailure",    "prop"),
    ("EF.Common.Contracts", "EF.Common.Contracts.Result",       "ErrorMessage", "prop"),
    ("EF.Common.Contracts", "EF.Common.Contracts.Result",       "Failure",      "static"),
    ("EF.Common.Contracts", "EF.Common.Contracts.Result",       "Success",      "static"),
]


def _semver_key(p: Path) -> tuple[int, ...]:
    try:
        return tuple(int(x) for x in p.name.split("."))
    except ValueError:
        return (0,)


def _find_cached_dll(package_id: str) -> Path | None:
    """Return the DLL for the latest cached version of package_id, or None."""
    cache = Path.home() / ".nuget" / "packages" / package_id.lower()
    if not cache.exists():
        return None
    for ver_dir in sorted(cache.iterdir(), key=_semver_key, reverse=True):
        for tfm in ("net10.0", "net9.0", "net8.0"):
            dll = ver_dir / "lib" / tfm / f"{package_id}.dll"
            if dll.exists():
                return dll
    return None


def check_ef_package_api(findings: Findings) -> None:
    if not shutil.which("dotnet"):
        return  # dotnet not on PATH - skip silently

    dll_map: dict[str, Path] = {}
    for pkg_id, *_ in EF_API_CLAIMS:
        if pkg_id in dll_map:
            continue
        dll = _find_cached_dll(pkg_id)
        if dll is None:
            return  # packages not cached - skip silently (expected in CI)
        dll_map[pkg_id] = dll

    # Detect SDK major version for TargetFramework.
    sdk_proc = subprocess.run(["dotnet", "--version"], capture_output=True, text=True)
    tfm = f"net{sdk_proc.stdout.strip().split('.')[0]}.0" if sdk_proc.returncode == 0 else "net10.0"

    # Generate a self-contained C# console app that loads the assemblies and
    # checks each documented member. Assembly.LoadFile is metadata-safe for
    # GetType/GetProperties/GetMethods without loading transitive dependencies.
    load_lines = "\n".join(
        f'    asms[@"{str(dll).replace(chr(34), chr(34)+chr(34))}"] = Assembly.LoadFile(@"{str(dll).replace(chr(34), chr(34)+chr(34))}");'
        for dll in dll_map.values()
    )
    check_lines = "\n".join(
        f'    Check(asms[@"{str(dll_map[pkg_id]).replace(chr(34), chr(34)+chr(34))}"], "{type_fqn}", "{member}", "{kind}");'
        for pkg_id, type_fqn, member, kind in EF_API_CLAIMS
    )
    cs_check_method = (
        "static void Check(Assembly asm, string typeFqn, string member, string kind)\n"
        "{\n"
        "    var t = asm.GetType(typeFqn);\n"
        "    if (t == null) { Console.WriteLine(\"FAIL:\" + typeFqn + \" type not found\"); return; }\n"
        "    bool found = kind == \"prop\"\n"
        "        ? Array.Exists(t.GetProperties(), p => p.Name == member)\n"
        "        : Array.Exists(t.GetMethods(BindingFlags.Public | BindingFlags.Static), m => m.Name == member);\n"
        "    Console.WriteLine(found ? \"OK:\" + typeFqn + \".\" + member : \"FAIL:\" + typeFqn + \".\" + member + \" (\" + kind + \" not found)\");\n"
        "}"
    )
    cs_source = "\n".join([
        "using System;",
        "using System.Collections.Generic;",
        "using System.Reflection;",
        "var asms = new Dictionary<string, Assembly>();",
        load_lines,
        cs_check_method,
        check_lines,
    ])
    csproj = (
        "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup>"
        f"<OutputType>Exe</OutputType><TargetFramework>{tfm}</TargetFramework>"
        "<Nullable>enable</Nullable><ImplicitUsings>disable</ImplicitUsings>"
        "</PropertyGroup></Project>"
    )

    ref_path = INSTRUCTIONS_ROOT / EF_PACKAGES_REL
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        (tmp_path / "Check.cs").write_text(cs_source, encoding="utf-8")
        (tmp_path / "Check.csproj").write_text(csproj, encoding="utf-8")
        proc = subprocess.run(
            ["dotnet", "run", "--project", str(tmp_path)],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
        )
        if proc.returncode != 0:
            findings.warn(ref_path, f"EF package API check could not run ({proc.stderr.strip()[:120]})")
            return
        for line in proc.stdout.splitlines():
            if line.startswith("FAIL:"):
                findings.err(
                    ref_path,
                    f"EF package API mismatch: {line[5:]} - update {EF_PACKAGES_REL} to match installed packages",
                )


def main() -> int:
    findings = Findings()

    md_files = iter_markdown_files()
    headings_cache: dict[Path, list[str]] = {}
    for path in md_files:
        check_whole_file_fence(path, findings)
        check_links(path, findings)
        check_phase_labels(path, findings)
        check_section_anchors(path, findings, headings_cache)
        check_refapp_count_claims(path, findings)
        check_version_prose(path, findings)

    check_command_shape(findings)
    check_maintenance_guards(findings)
    check_payload_shape(findings)
    check_readme_install_table(findings)
    check_phase5_load_set(findings)
    check_phase5_template_coverage(findings)
    check_loadset_token_budget(findings)
    check_golden_path_schemas(findings)
    check_ef_package_api(findings)

    print(f"validated {len(md_files)} markdown file(s) under {INSTRUCTIONS_ROOT}")
    if APP_ROOT != INSTRUCTIONS_ROOT:
        print(f"app root: {APP_ROOT}")
    print()
    return findings.report()


if __name__ == "__main__":
    sys.exit(main())
