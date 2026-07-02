#!/usr/bin/env python3
"""
Installs the runtime payload of this instruction repo into a consumer app.

Copies (unless --instructions-only):
    <repo>/<runtime files>                   -> <target>/.instructions/
    <repo>/AGENTS.md                         -> <target>/AGENTS.md            (merge)
    <repo>/CLAUDE.md                         -> <target>/CLAUDE.md            (merge)
    <repo>/.github/copilot-instructions.md   -> <target>/.github/copilot-instructions.md (merge)
    <repo>/.claude/commands/                 -> <target>/.claude/commands/    (dir)
    <repo>/.github/agents/                   -> <target>/.github/agents/      (dir)

"merge" writes source content inside sentinel markers. Existing target files are preserved
outside the managed block, so re-running the installer is idempotent.

Excludes author-side files: scripts/__pycache__, tests/, .git/, .github/workflows/,
.githooks/, .vscode/, .venv/, .tmp/, .gitignore.

Usage:
    python scripts/install-to-project.py --target <app-repo-root>
    python scripts/install-to-project.py --target <app-repo-root> --update
    python scripts/install-to-project.py --target <app-repo-root> --dry-run
    python scripts/install-to-project.py --target <app-repo-root> --instructions-only
    python scripts/install-to-project.py --target <app-repo-root> --verify
    python scripts/install-to-project.py --target <app-repo-root> --verify-only
"""

import argparse
import filecmp
import shutil
import sys
from pathlib import Path


# Runtime payload copied into <target>/.instructions/
INSTRUCTIONS_FILES = [
    "README.md",
    "AGENTS.md",
    "START-AI.md",
    "GROUND-RULES.md",
]

INSTRUCTIONS_DIRS = [
    "ai",
    "patterns",
    "profiles",
    "schemas",
    "skills",
    "support",
    "templates",
    "scripts",
]

# Paths excluded from any directory copy (matched against path parts).
EXCLUDE_PARTS = {
    "__pycache__",
    ".git",
    ".venv",
    ".tmp",
    ".vscode",
    ".githooks",
    "tests",
    "bin",
    "obj",
}

# Sentinel markers used when merging root-level markdown files.
MERGE_SENTINEL_START = "<!-- ai-scaffold: start -->"
MERGE_SENTINEL_END = "<!-- ai-scaffold: end -->"

# Agent/command placements that land at the app repo root, not under .instructions/.
# kind="merge" writes content inside sentinel markers (idempotent).
AGENT_COPIES = [
    ("AGENTS.md", "AGENTS.md", "merge"),
    ("CLAUDE.md", "CLAUDE.md", "merge"),
    (".github/copilot-instructions.md", ".github/copilot-instructions.md", "merge"),
    (".claude/commands", ".claude/commands", "dir"),
    (".github/agents", ".github/agents", "dir"),
]


def adapt_installed_entrypoint_links(src: Path, content: str) -> str:
    """Root harness files are copied outside .instructions, so author-side links need installed paths."""
    src_rel = src.as_posix()
    if src_rel.endswith("AGENTS.md"):
        return content.replace(
            "[README.md](README.md)",
            "[.instructions/README.md](.instructions/README.md)",
        )
    if src_rel.endswith("CLAUDE.md"):
        return (
            content.replace(
                "[README.md](README.md)",
                "[.instructions/README.md](.instructions/README.md)",
            )
            .replace(
                "[profiles/csharp-dotnet-azure.md](profiles/csharp-dotnet-azure.md)",
                "[.instructions/profiles/csharp-dotnet-azure.md](.instructions/profiles/csharp-dotnet-azure.md)",
            )
        )
    if src_rel.endswith(".github/copilot-instructions.md"):
        return (
            content.replace(
                "[README.md](../README.md)",
                "[.instructions/README.md](../.instructions/README.md)",
            )
            .replace(
                "[../profiles/csharp-dotnet-azure.md](../profiles/csharp-dotnet-azure.md)",
                "[../.instructions/profiles/csharp-dotnet-azure.md](../.instructions/profiles/csharp-dotnet-azure.md)",
            )
        )
    return content


class Planner:
    def __init__(self, dry_run: bool):
        self.dry_run = dry_run
        self.copied = 0
        self.skipped = 0
        self.unchanged = 0
        self.merged = 0
        self.overwritten: list[str] = []

    def _should_skip(self, rel_path: Path) -> bool:
        return any(part in EXCLUDE_PARTS for part in rel_path.parts)

    def copy_file(self, src: Path, dst: Path, label: str) -> None:
        # Content-aware and idempotent: identical files are skipped; differing
        # target files are overwritten (source is SSOT per GR-07) and listed.
        if dst.exists() and filecmp.cmp(src, dst, shallow=False):
            print(f"  [unchanged] {label}")
            self.unchanged += 1
            return
        overwrite = dst.exists()
        action = "[dry-run]" if self.dry_run else ("[overwrite]" if overwrite else "[copy]")
        print(f"  {action} {label}")
        if overwrite:
            self.overwritten.append(label)
        if not self.dry_run:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
        self.copied += 1

    def copy_tree(self, src: Path, dst: Path, label_prefix: str) -> None:
        if not src.exists():
            print(f"  [skip]  {label_prefix} (missing in source)")
            self.skipped += 1
            return
        for path in src.rglob("*"):
            if path.is_dir():
                continue
            rel = path.relative_to(src)
            if self._should_skip(rel):
                continue
            self.copy_file(path, dst / rel, f"{label_prefix}/{rel.as_posix()}")

    def merge_file(self, src: Path, dst: Path, label: str) -> None:
        """Write src inside sentinel markers, preserving target content outside the managed block."""
        src_content = adapt_installed_entrypoint_links(src, src.read_text(encoding="utf-8"))
        block = (
            MERGE_SENTINEL_START
            + "\n"
            + src_content.strip()
            + "\n"
            + MERGE_SENTINEL_END
        )
        if dst.exists():
            dst_content = dst.read_text(encoding="utf-8")
            if MERGE_SENTINEL_START in dst_content and MERGE_SENTINEL_END in dst_content:
                before, rest = dst_content.split(MERGE_SENTINEL_START, 1)
                _, after = rest.split(MERGE_SENTINEL_END, 1)
                merged = before.rstrip("\n") + "\n\n" + block + after
            elif dst_content.strip() == src_content.strip():
                merged = block + "\n"
            else:
                merged = dst_content.rstrip("\n") + "\n\n" + block + "\n"
            action = "[dry-run]" if self.dry_run else "[merge]"
            print(f"  {action} {label}")
            if not self.dry_run:
                dst.write_text(merged, encoding="utf-8")
            self.merged += 1
        else:
            action = "[dry-run]" if self.dry_run else "[copy]"
            print(f"  {action} {label}")
            if not self.dry_run:
                dst.parent.mkdir(parents=True, exist_ok=True)
                dst.write_text(block + "\n", encoding="utf-8")
            self.copied += 1

    def summary(self) -> None:
        print()
        print(f"copied:    {self.copied}")
        print(f"merged:    {self.merged} (appended scaffold block to existing file)")
        print(f"unchanged: {self.unchanged} (content identical, skipped)")
        print(f"skipped:   {self.skipped}")
        if self.overwritten:
            print(f"overwritten: {len(self.overwritten)} target file(s) differed from source (source is SSOT per GR-07):")
            for label in self.overwritten:
                print(f"  - {label}")
        if self.dry_run:
            print("(dry-run - no files written)")


def preserve_handoff(target_instructions: Path, dry_run: bool) -> Path | None:
    handoff = target_instructions.parent / "HANDOFF.md"
    if handoff.exists():
        print(f"[note] HANDOFF.md exists at {handoff} - left untouched")
        return handoff
    return None


# Required files/dirs after a full install (relative to <target>).
# Skipped expectations are pruned in verify_install when --instructions-only was used.
# Payload files removed from INSTRUCTIONS_FILES over time; deleted from targets
# on install so stale copies cannot contradict the current payload.
OBSOLETE_PAYLOAD_FILES = [
    ".instructions/CLAUDE.md",  # replaced by .instructions/AGENTS.md (root CLAUDE.md is now an @AGENTS.md import stub)
]

SMOKE_CHECK_PAYLOAD = [
    ".instructions/START-AI.md",
    ".instructions/README.md",
    ".instructions/AGENTS.md",
    ".instructions/GROUND-RULES.md",
    ".instructions/ai/SKILL.md",
    ".instructions/support/execution-gates.md",
    ".instructions/support/HANDOFF.md",
]

SMOKE_CHECK_HARNESS_ENTRYPOINTS = [
    "AGENTS.md",
    "CLAUDE.md",
    ".github/copilot-instructions.md",
    ".claude/commands/scaffold.md",
    ".claude/commands/vertical-slice.md",
    ".claude/commands/scaffold-adopt.md",
    ".github/agents/dotnet-scaffold.agent.md",
    ".github/agents/vertical-slice.agent.md",
    ".github/agents/scaffold-adopt.agent.md",
]


def verify_install(target_root: Path, instructions_only: bool) -> int:
    """Verify the expected files exist after install. Returns process exit code."""
    expected = list(SMOKE_CHECK_PAYLOAD)
    if not instructions_only:
        expected += SMOKE_CHECK_HARNESS_ENTRYPOINTS

    missing = [rel for rel in expected if not (target_root / rel).exists()]
    obsolete = [rel for rel in OBSOLETE_PAYLOAD_FILES if (target_root / rel).exists()]
    unmarked_merge_files: list[str] = []
    if not instructions_only:
        for _src_rel, dst_rel, kind in AGENT_COPIES:
            if kind != "merge":
                continue
            path = target_root / dst_rel
            if not path.exists():
                continue
            content = path.read_text(encoding="utf-8")
            if MERGE_SENTINEL_START not in content or MERGE_SENTINEL_END not in content:
                unmarked_merge_files.append(dst_rel)

    print()
    print("== install smoke check ==")
    if missing or unmarked_merge_files or obsolete:
        issue_count = len(missing) + len(unmarked_merge_files) + len(obsolete)
        print(f"  [fail] {issue_count} install issue(s) under {target_root}:")
    if missing:
        print("         missing expected file(s):")
        for rel in missing:
            print(f"         - {rel}")
    if unmarked_merge_files:
        print("         merge entrypoint(s) missing sentinel markers:")
        for rel in unmarked_merge_files:
            print(f"         - {rel}")
    if obsolete:
        print("         obsolete payload file(s) present (re-run install to remove):")
        for rel in obsolete:
            print(f"         - {rel}")
    if missing or unmarked_merge_files or obsolete:
        return 1
    print(f"  [ok]   all {len(expected)} expected files present under {target_root}")
    if not instructions_only:
        print("  [ok]   merge entrypoints contain sentinel markers")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Install AI-Instructions runtime payload into a consumer app.",
    )
    parser.add_argument(
        "--target", required=True,
        help="Path to the consumer app repo root (parent of .instructions/).",
    )
    parser.add_argument(
        "--update", action="store_true",
        help="Deprecated no-op, kept for compatibility: installs are always "
             "content-aware (identical files skipped, changed files overwritten and listed).",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Print planned copies without writing files.",
    )
    parser.add_argument(
        "--instructions-only", action="store_true",
        help="Install only <target>/.instructions/, skip agent/command placement.",
    )
    parser.add_argument(
        "--verify", action="store_true",
        help="After install, verify expected entrypoints and payload files exist.",
    )
    parser.add_argument(
        "--verify-only", action="store_true",
        help="Skip install; just verify an existing target. Implies --verify.",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    target_root = Path(args.target).resolve()

    if not target_root.exists():
        print(f"error: target does not exist: {target_root}", file=sys.stderr)
        return 1
    if not target_root.is_dir():
        print(f"error: target is not a directory: {target_root}", file=sys.stderr)
        return 1
    if target_root == repo_root and not args.verify_only:
        print("error: refusing to install into the instruction repo itself", file=sys.stderr)
        return 1

    target_instructions = target_root / ".instructions"
    print(f"source: {repo_root}")
    print(f"target: {target_root}")
    print()

    if args.verify_only:
        return verify_install(target_root, args.instructions_only)

    preserve_handoff(target_instructions, args.dry_run)

    planner = Planner(dry_run=args.dry_run)

    print("== .instructions/ payload ==")
    for rel in INSTRUCTIONS_FILES:
        src = repo_root / rel
        if not src.exists():
            print(f"  [skip]  {rel} (missing in source)")
            planner.skipped += 1
            continue
        planner.copy_file(src, target_instructions / rel, f".instructions/{rel}")

    for rel in INSTRUCTIONS_DIRS:
        planner.copy_tree(
            repo_root / rel,
            target_instructions / rel,
            f".instructions/{rel}",
        )

    for rel in OBSOLETE_PAYLOAD_FILES:
        stale = target_root / rel
        if stale.exists():
            action = "[dry-run]" if args.dry_run else "[removed]"
            print(f"  {action} {rel} (obsolete payload file)")
            if not args.dry_run:
                stale.unlink()

    if not args.instructions_only:
        print()
        print("== agent/command placement (app repo root) ==")
        for src_rel, dst_rel, kind in AGENT_COPIES:
            src = repo_root / src_rel
            dst = target_root / dst_rel
            if not src.exists():
                print(f"  [skip]  {dst_rel} (missing in source)")
                planner.skipped += 1
                continue
            if kind == "merge":
                planner.merge_file(src, dst, dst_rel)
            elif kind == "file":
                planner.copy_file(src, dst, dst_rel)
            else:
                planner.copy_tree(src, dst, dst_rel)

    planner.summary()

    if args.verify and not args.dry_run:
        return verify_install(target_root, args.instructions_only)

    return 0


if __name__ == "__main__":
    sys.exit(main())
