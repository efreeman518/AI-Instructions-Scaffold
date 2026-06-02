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
  - Section-anchor existence: when prose says ``[label](file.md) section Section Name``
    or ``file.md -> Section Name`` (with the path in backticks), verify the named
    section exists as a heading in the target file. Catches refs left dangling
    after file splits.
  - Phase 5 load-set integrity: every skill/template/pattern named in the
    ai/SKILL.md "Phase 5 file table" (and its base-context line) resolves to a
    real file. The table references targets by backtick short-name, not by
    markdown link, so check_links does not cover them - a renamed or deleted
    skill/template would otherwise drift silently.

Exit code 0 if all checks pass, 1 otherwise. Output groups failures by file.
"""

from __future__ import annotations

import re
import sys
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

# Author-side directories that must NOT be in the runtime payload.
AUTHOR_ONLY_DIRS = {"tests", ".github/workflows", ".githooks", ".vscode", ".venv", ".tmp"}

# Markdown roots to walk. Skip vendored/temporary trees.
RUNTIME_SCAN_ROOTS = ["ai", "patterns", "schemas", "skills", "support", "templates"]
HARNESS_SCAN_ROOTS = [".claude", ".github"]
INSTRUCTIONS_TOP_LEVEL_MD = ["README.md", "START-AI.md", "CLAUDE.md", "GROUND-RULES.md"]
APP_TOP_LEVEL_MD = ["AGENTS.md", "CLAUDE.md"]

EXCLUDE_PARTS = {"__pycache__", ".git", ".venv", ".tmp", ".vscode", ".githooks", "tests", "bin", "obj", "node_modules"}

# Recognized phase tokens. Anything matching the pattern but not on this list is flagged.
CANONICAL_PHASES = {"Phase 1", "Phase 2", "Phase 3", "Phase 4", "Phase 5", "Phase 5a", "Phase 5b", "Phase 5c", "Phase 5d", "Phase 5e"}
PHASE_PATTERN = re.compile(r"\bPhase\s+(\d+[a-z]?)\b")

# Inline link pattern: [text](target). Skip absolute URLs and anchors-only.
LINK_PATTERN = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")

# Fenced code blocks can contain scaffold examples with placeholder links.
FENCED_CODE_PATTERN = re.compile(r"(^|\n)[ \t]{0,3}(`{3,}|~{3,})[^\n]*\n.*?\n[ \t]{0,3}\2[ \t]*(?=\n|$)", re.DOTALL)

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


def main() -> int:
    findings = Findings()

    md_files = iter_markdown_files()
    headings_cache: dict[Path, list[str]] = {}
    for path in md_files:
        check_links(path, findings)
        check_phase_labels(path, findings)
        check_section_anchors(path, findings, headings_cache)

    check_command_shape(findings)
    check_maintenance_guards(findings)
    check_payload_shape(findings)
    check_phase5_load_set(findings)

    print(f"validated {len(md_files)} markdown file(s) under {INSTRUCTIONS_ROOT}")
    if APP_ROOT != INSTRUCTIONS_ROOT:
        print(f"app root: {APP_ROOT}")
    print()
    return findings.report()


if __name__ == "__main__":
    sys.exit(main())
