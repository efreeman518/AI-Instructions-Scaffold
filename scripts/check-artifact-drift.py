#!/usr/bin/env python3
"""
Cross-artifact drift scan (advisory): Phase-1 artifacts vs code identifiers.

GR-01 makes `.scaffold/domain-specification.yaml` and
`.scaffold/UBIQUITOUS-LANGUAGE.md` the binding source of truth; this script
mechanically checks the code against them:

  1. Rejected synonyms (UBIQUITOUS-LANGUAGE "Rejected Synonyms" table) declared
     as C# type names under src/.
  2. Accepted domain terms (aggregate/entity/child entity/join entity/
     value-object rows of the "Accepted Terms" table) with no matching C# type
     declaration under src/.
  3. domain-specification.yaml entities/valueObjects with no matching C# type.

Advisory by default: always exits 0 so it can run inside checklists without
blocking; pass --strict to exit 1 when findings exist (future gate promotion).

Usage (from a scaffolded app root):
    python .instructions/scripts/check-artifact-drift.py [--root .] [--strict]
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# Accepted-term types that must exist as C# types. Roles, external systems,
# auth scenarios, and the system name itself have no single code type.
TYPE_BEARING_TERM_TYPES = {"aggregate", "entity", "child entity", "join entity", "value-object"}

TYPE_DECL_TEMPLATE = r"\b(?:class|record|struct|interface|enum)\s+{name}\b"


def parse_ul_tables(text: str) -> tuple[dict[str, str], dict[str, str]]:
    """Return (accepted {term: type}, rejected {term: use_instead})."""
    accepted: dict[str, str] = {}
    rejected: dict[str, str] = {}
    section = None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("## "):
            heading = stripped[3:].strip().lower()
            section = ("accepted" if heading == "accepted terms"
                       else "rejected" if heading == "rejected synonyms" else None)
            continue
        if section is None or not stripped.startswith("|"):
            continue
        cells = [c.strip() for c in stripped.strip("|").split("|")]
        if len(cells) < 2 or set(cells[0]) <= {"-", " "} or cells[0].lower() in ("term", "rejected term"):
            continue
        term = cells[0].strip("`").strip()
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", term):
            continue  # multi-word or non-identifier terms have no single code type
        if section == "accepted":
            accepted[term] = cells[1].strip("`").strip().lower()
        else:
            rejected[term] = cells[1].strip("`").strip()
    return accepted, rejected


def parse_domain_spec_names(text: str) -> set[str]:
    """Entity/value-object names from domain-specification.yaml.

    PyYAML when available; otherwise an indentation-based fallback that takes
    only top-level list items (`  - name:`) inside the entities:/valueObjects:
    sections, so nested attribute/invariant names are not picked up.
    """
    try:
        import yaml  # type: ignore
        data = yaml.safe_load(text) or {}
        names: set[str] = set()
        for key in ("entities", "valueObjects"):
            for item in data.get(key) or []:
                name = (item or {}).get("name")
                if isinstance(name, str):
                    names.add(name)
        return names
    except ImportError:
        pass
    names = set()
    section = None
    for line in text.splitlines():
        if re.match(r"^[A-Za-z]", line):
            section = line.split(":", 1)[0].strip()
            continue
        if section in ("entities", "valueObjects"):
            m = re.match(r"^  - name:\s*([A-Za-z][A-Za-z0-9]*)\s*$", line)
            if m:
                names.add(m.group(1))
    return names


def collect_cs_text(src_root: Path) -> str:
    chunks: list[str] = []
    for p in src_root.rglob("*.cs"):
        if any(part in ("bin", "obj") for part in p.parts):
            continue
        try:
            chunks.append(p.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            continue
    return "\n".join(chunks)


def main() -> int:
    parser = argparse.ArgumentParser(description="Advisory drift scan: Phase-1 artifacts vs C# code.")
    parser.add_argument("--root", default=".", help="Scaffolded app root (contains .scaffold/ and src/).")
    parser.add_argument("--strict", action="store_true",
                        help="Exit 1 when findings exist (default: advisory, always exit 0).")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    ul_path = root / ".scaffold" / "UBIQUITOUS-LANGUAGE.md"
    spec_path = root / ".scaffold" / "domain-specification.yaml"
    src_root = root / "src"

    missing = [p for p in (ul_path, spec_path, src_root) if not p.exists()]
    if missing:
        print("[note] drift scan skipped - missing: " + ", ".join(str(m) for m in missing))
        return 0

    accepted, rejected = parse_ul_tables(ul_path.read_text(encoding="utf-8"))
    spec_names = parse_domain_spec_names(spec_path.read_text(encoding="utf-8"))
    code = collect_cs_text(src_root)

    findings: list[str] = []

    for term, use_instead in sorted(rejected.items()):
        if re.search(TYPE_DECL_TEMPLATE.format(name=re.escape(term)), code):
            findings.append(f"rejected synonym '{term}' is declared as a type in src/ - use '{use_instead}' instead")

    type_bearing = {t for t, kind in accepted.items() if kind in TYPE_BEARING_TERM_TYPES}
    for term in sorted(type_bearing):
        if not re.search(TYPE_DECL_TEMPLATE.format(name=re.escape(term)), code):
            findings.append(f"accepted term '{term}' ({accepted[term]}) has no matching type declaration in src/")

    for name in sorted(spec_names - type_bearing):  # avoid double-reporting UL-covered names
        if not re.search(TYPE_DECL_TEMPLATE.format(name=re.escape(name)), code):
            findings.append(f"domain-specification entity/value-object '{name}' has no matching type declaration in src/")

    print(f"drift scan: {len(rejected)} rejected synonym(s), {len(type_bearing)} type-bearing accepted term(s), "
          f"{len(spec_names)} spec name(s) checked against src/")
    if findings:
        print(f"[drift] {len(findings)} finding(s) - artifact and code disagree (GR-01: fix the artifact first, then code):")
        for f in findings:
            print(f"  - {f}")
    else:
        print("[ok] no drift found between Phase-1 artifacts and src/ type declarations")

    return 1 if (findings and args.strict) else 0


if __name__ == "__main__":
    sys.exit(main())
