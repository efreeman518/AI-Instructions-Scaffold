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
import hashlib
import json
import shutil
import subprocess
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

MANIFEST_FORMAT = 1
MANIFEST_REL = ".instructions/.scaffold-install-manifest.json"

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


def hash_bytes(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def hash_file(path: Path) -> str:
    return hash_bytes(path.read_bytes())


def managed_block_content(src: Path) -> str:
    return adapt_installed_entrypoint_links(
        src,
        src.read_text(encoding="utf-8"),
    ).strip()


def extract_managed_block(content: str) -> str | None:
    if MERGE_SENTINEL_START not in content or MERGE_SENTINEL_END not in content:
        return None
    _before, rest = content.split(MERGE_SENTINEL_START, 1)
    managed, _after = rest.split(MERGE_SENTINEL_END, 1)
    return managed.strip()


def source_commit(repo_root: Path) -> str | None:
    if not shutil.which("git"):
        return None
    proc = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo_root,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return proc.stdout.strip() if proc.returncode == 0 else None


def source_repository(repo_root: Path) -> str | None:
    if not shutil.which("git"):
        return None
    proc = subprocess.run(
        ["git", "remote", "get-url", "origin"],
        cwd=repo_root,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return proc.stdout.strip() if proc.returncode == 0 and proc.stdout.strip() else None


def iter_source_files(root: Path):
    for path in root.rglob("*"):
        if path.is_dir():
            continue
        rel = path.relative_to(root)
        if any(part in EXCLUDE_PARTS for part in rel.parts):
            continue
        yield path, rel


def build_manifest(repo_root: Path, instructions_only: bool) -> dict:
    managed_files: dict[str, str] = {}
    managed_blocks: dict[str, str] = {}

    for rel in INSTRUCTIONS_FILES:
        src = repo_root / rel
        if src.exists():
            managed_files[f".instructions/{rel}"] = hash_file(src)
    for rel in INSTRUCTIONS_DIRS:
        src_root = repo_root / rel
        if not src_root.exists():
            continue
        for src, child_rel in iter_source_files(src_root):
            managed_files[f".instructions/{rel}/{child_rel.as_posix()}"] = hash_file(src)

    if not instructions_only:
        for src_rel, dst_rel, kind in AGENT_COPIES:
            src = repo_root / src_rel
            if not src.exists():
                continue
            if kind == "merge":
                managed_blocks[dst_rel] = hash_bytes(managed_block_content(src).encode("utf-8"))
            elif kind == "file":
                managed_files[dst_rel] = hash_file(src)
            else:
                for child, child_rel in iter_source_files(src):
                    managed_files[f"{dst_rel}/{child_rel.as_posix()}"] = hash_file(child)

    manifest = {
        "format": MANIFEST_FORMAT,
        "scope": "instructions-only" if instructions_only else "full",
        "managedFiles": dict(sorted(managed_files.items())),
        "managedBlocks": dict(sorted(managed_blocks.items())),
    }
    repository = source_repository(repo_root)
    if repository:
        manifest["sourceRepository"] = repository
    commit = source_commit(repo_root)
    if commit:
        manifest["sourceCommit"] = commit
    return manifest


def validate_manifest_shape(manifest: object) -> str | None:
    if not isinstance(manifest, dict):
        return "manifest root must be an object"
    if manifest.get("format") != MANIFEST_FORMAT:
        return f"unsupported manifest format: {manifest.get('format')!r}"
    if manifest.get("scope") not in {"full", "instructions-only"}:
        return "manifest scope must be 'full' or 'instructions-only'"
    for key in ("managedFiles", "managedBlocks"):
        entries = manifest.get(key)
        if not isinstance(entries, dict):
            return f"manifest {key} must be an object"
        for rel, digest in entries.items():
            path = Path(rel)
            if (
                not isinstance(rel, str)
                or not rel
                or path.is_absolute()
                or ".." in path.parts
                or not isinstance(digest, str)
                or len(digest) != 64
                or any(ch not in "0123456789abcdef" for ch in digest)
            ):
                return f"manifest {key} contains an invalid entry: {rel!r}"
    return None


def load_manifest(target_root: Path) -> tuple[dict | None, str | None]:
    path = target_root / MANIFEST_REL
    if not path.exists():
        return None, None
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return None, f"cannot read {MANIFEST_REL}: {exc}"
    error = validate_manifest_shape(manifest)
    return (None, error) if error else (manifest, None)


def plan_pruning(
    target_root: Path,
    previous: dict | None,
    expected: dict,
    instructions_only: bool,
) -> tuple[list[str], list[str], list[str]]:
    if previous is None:
        return [], [], []

    old_files: dict[str, str] = previous["managedFiles"]
    new_files: dict[str, str] = expected["managedFiles"]
    removed_files: list[str] = []
    removed_blocks: list[str] = []
    conflicts: list[str] = []

    for rel in sorted(set(old_files) - set(new_files)):
        if instructions_only and not rel.startswith(".instructions/"):
            continue
        path = target_root / rel
        if not path.exists():
            continue
        if not path.is_file() or hash_file(path) != old_files[rel]:
            conflicts.append(rel)
        else:
            removed_files.append(rel)

    if not instructions_only:
        old_blocks: dict[str, str] = previous["managedBlocks"]
        new_blocks: dict[str, str] = expected["managedBlocks"]
        for rel in sorted(set(old_blocks) - set(new_blocks)):
            path = target_root / rel
            if not path.exists():
                continue
            managed = extract_managed_block(path.read_text(encoding="utf-8"))
            if managed is None or hash_bytes(managed.encode("utf-8")) != old_blocks[rel]:
                conflicts.append(f"{rel} (managed block)")
            else:
                removed_blocks.append(rel)

    return removed_files, removed_blocks, conflicts


def remove_managed_block(path: Path) -> None:
    content = path.read_text(encoding="utf-8")
    before, rest = content.split(MERGE_SENTINEL_START, 1)
    _managed, after = rest.split(MERGE_SENTINEL_END, 1)
    remaining = (before.rstrip() + "\n\n" + after.lstrip()).strip()
    if remaining:
        path.write_text(remaining + "\n", encoding="utf-8")
    else:
        path.unlink()


def apply_pruning(
    target_root: Path,
    removed_files: list[str],
    removed_blocks: list[str],
    dry_run: bool,
) -> None:
    for rel in removed_files:
        print(f"  [{'dry-run' if dry_run else 'removed'}] {rel} (removed from source manifest)")
        if not dry_run:
            (target_root / rel).unlink()
    for rel in removed_blocks:
        print(f"  [{'dry-run' if dry_run else 'removed'}] {rel} managed block (removed from source manifest)")
        if not dry_run:
            remove_managed_block(target_root / rel)


def write_manifest(target_root: Path, manifest: dict, dry_run: bool) -> None:
    action = "dry-run" if dry_run else "write"
    print(f"  [{action}] {MANIFEST_REL}")
    if dry_run:
        return
    path = target_root / MANIFEST_REL
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


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
        src_content = managed_block_content(src)
        block = (
            MERGE_SENTINEL_START
            + "\n"
            + src_content
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
    """Verify every manifest-managed file and marker block. Returns process exit code."""
    manifest, manifest_error = load_manifest(target_root)
    print()
    print("== install integrity check ==")
    if manifest_error:
        print(f"  [fail] {manifest_error}")
        return 1
    if manifest is None:
        print(f"  [fail] {MANIFEST_REL} is missing; re-run the installer to establish managed ownership")
        return 1

    managed_files: dict[str, str] = manifest["managedFiles"]
    managed_blocks: dict[str, str] = manifest["managedBlocks"]
    # The manifest's recorded scope narrows verification alongside the CLI flag:
    # an instructions-only manifest simply has no harness records to verify.
    instructions_only = instructions_only or manifest.get("scope") == "instructions-only"
    required = list(SMOKE_CHECK_PAYLOAD)
    if not instructions_only:
        required += SMOKE_CHECK_HARNESS_ENTRYPOINTS

    missing_records = [
        rel for rel in required
        if rel not in managed_files and rel not in managed_blocks
    ]
    missing: list[str] = []
    changed: list[str] = []
    for rel, expected_hash in managed_files.items():
        if instructions_only and not rel.startswith(".instructions/"):
            continue
        path = target_root / rel
        if not path.exists() or not path.is_file():
            missing.append(rel)
        elif hash_file(path) != expected_hash:
            changed.append(rel)

    block_issues: list[str] = []
    if not instructions_only:
        for rel, expected_hash in managed_blocks.items():
            path = target_root / rel
            if not path.exists() or not path.is_file():
                missing.append(rel)
                continue
            managed = extract_managed_block(path.read_text(encoding="utf-8"))
            if managed is None:
                block_issues.append(f"{rel} (sentinel markers missing)")
            elif hash_bytes(managed.encode("utf-8")) != expected_hash:
                block_issues.append(f"{rel} (managed block changed)")

    observed: set[str] = set()
    instructions_root = target_root / ".instructions"
    if instructions_root.exists():
        for path in instructions_root.rglob("*"):
            if path.is_file() and path != target_root / MANIFEST_REL:
                observed.add(path.relative_to(target_root).as_posix())
    if not instructions_only:
        for _src_rel, dst_rel, kind in AGENT_COPIES:
            if kind != "dir":
                continue
            root = target_root / dst_rel
            if root.exists():
                for path in root.rglob("*"):
                    if path.is_file():
                        observed.add(path.relative_to(target_root).as_posix())
    extras = sorted(observed - set(managed_files))

    if missing_records or missing or changed or block_issues:
        issue_count = (
            len(missing_records) + len(missing) + len(changed)
            + len(block_issues)
        )
        print(f"  [fail] {issue_count} install issue(s) under {target_root}:")
    if missing_records:
        print("         required manifest record(s) missing:")
        for rel in missing_records:
            print(f"         - {rel}")
    if missing:
        print("         managed file(s) missing:")
        for rel in missing:
            print(f"         - {rel}")
    if changed:
        print("         managed file(s) changed:")
        for rel in changed:
            print(f"         - {rel}")
    if block_issues:
        print("         managed block issue(s):")
        for rel in block_issues:
            print(f"         - {rel}")
    if extras:
        print(f"  [warn] {len(extras)} unmanifested file(s) left untouched:")
        for rel in extras:
            print(f"         - {rel}")
    if missing_records or missing or changed or block_issues:
        return 1
    checked_count = sum(
        1 for rel in managed_files
        if not instructions_only or rel.startswith(".instructions/")
    )
    print(f"  [ok]   {checked_count} managed file hash(es) match")
    if not instructions_only:
        print(f"  [ok]   {len(managed_blocks)} managed block hash(es) match")
    if manifest.get("sourceCommit"):
        print(f"  [info] installed from source commit {manifest['sourceCommit']}")
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
        help="After install, verify all manifest-managed file and marker-block hashes.",
    )
    parser.add_argument(
        "--verify-only", action="store_true",
        help="Skip install; verify all manifest-managed content. Implies --verify.",
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

    previous_manifest, manifest_error = load_manifest(target_root)
    if manifest_error:
        print(f"error: {manifest_error}", file=sys.stderr)
        return 1
    expected_manifest = build_manifest(repo_root, args.instructions_only)
    if args.instructions_only and previous_manifest and previous_manifest.get("scope") == "full":
        # This run does not touch harness content; dropping the prior full-scope
        # records would orphan those files from ownership and future pruning.
        for rel, digest in previous_manifest["managedFiles"].items():
            if not rel.startswith(".instructions/"):
                expected_manifest["managedFiles"][rel] = digest
        expected_manifest["managedFiles"] = dict(sorted(expected_manifest["managedFiles"].items()))
        expected_manifest["managedBlocks"] = dict(sorted(previous_manifest["managedBlocks"].items()))
        expected_manifest["scope"] = "full"
    removed_files, removed_blocks, prune_conflicts = plan_pruning(
        target_root,
        previous_manifest,
        expected_manifest,
        args.instructions_only,
    )
    if prune_conflicts:
        print("error: cannot safely remove locally changed managed content:", file=sys.stderr)
        for rel in prune_conflicts:
            print(f"  - {rel}", file=sys.stderr)
        print("restore the prior managed content or move the local changes, then retry", file=sys.stderr)
        return 1

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

    apply_pruning(target_root, removed_files, removed_blocks, args.dry_run)

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

    print()
    print("== install manifest ==")
    write_manifest(target_root, expected_manifest, args.dry_run)

    planner.summary()

    if args.verify and not args.dry_run:
        return verify_install(target_root, args.instructions_only)

    return 0


if __name__ == "__main__":
    sys.exit(main())
