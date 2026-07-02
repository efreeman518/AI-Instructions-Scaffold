---
name: golden-path
description: "Run the end-to-end golden-path regression: drive headless agent sessions through scaffold phases against the fixture with build/test gates. Heavy author-side regression, source-repo only. Trigger: /golden-path."
trigger: /golden-path
---

# /golden-path

Maintainer skill for the **source repo only**. Author-side end-to-end regression: drives headless agent sessions (Claude Code subscription login or Codex CLI - no API key) through Phases 3-5b plus a vertical-slice phase against the golden-path fixture in a throwaway workspace, gating each phase with `dotnet build` / `dotnet test`. The final `slice` phase adds a new independent aggregate to the scaffolded workspace and additionally gates on migration-history additivity (GR-13) and entity presence - it regression-tests the `/vertical-slice` flow.

## When to use

- Validate that an instruction change still scaffolds a working app end to end.
- Before a release, or after a large refactor that the structural validator cannot fully cover.

## Run

Run from the repo root; always start with `--dry-run`.

```powershell
# Dry run - print the plan without spawning sessions
py -3 tests/golden-path/run-golden-path.py --dry-run

# Full run
py -3 tests/golden-path/run-golden-path.py
```

## Notes

- Not part of the installed payload (`tests/` is excluded by the installer).
- Reports land under `.tmp/golden-path-runs/`.
- Heavy and slow - it spawns real agent sessions and builds/tests each phase. Run deliberately, not as a quick check. For fast structural validation use `/maintain-instructions` (the validator) instead.
