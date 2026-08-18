# Tech Design Diagrams - Format, Source-Plus-SVG, and Viewer Controls

Canonical rules for the **GitHub-facing technical design doc** the scaffold generates at `docs/tech-design.md` and its sibling viewer `docs/tech-design.html`. Reference shape: <https://github.com/efreeman518/AI-Instructions-ReferenceApp/blob/main/docs/tech-design.md>.

The scaffold owns the **format and viewer controls**, not the diagram list. Which diagrams to include is a per-project decision driven by `.scaffold/domain-specification.yaml`, `.scaffold/resource-implementation.yaml`, and what the app actually generates.

## Why Source-Plus-SVG

GitHub's live Mermaid runtime rejects diagram variants the local Mermaid CLI accepts - C4, `block-beta`, complex `erDiagram`, styled `graph` with `classDef`, and newer syntax. Committing both the `.mmd` source and a rendered `.svg` makes the doc render deterministically on GitHub *and* keeps the source editable.

## Scope

| Applies | Does not apply |
|---|---|
| `docs/tech-design.md`, `docs/tech-design.html`, and any peer **GitHub-rendered** architecture/topology docs under `docs/` | Scaffold-internal artifacts under `.scaffold/` (e.g. `DESIGN-DECISIONS.md`, `implementation-plan.md`). Inline `mermaid` fences are fine there - those are working artifacts, not GitHub-rendered docs. |

If a diagram source is a basic `flowchart` / `sequenceDiagram` / `stateDiagram` with **no** `classDef` styling and **no** `block-beta` / C4 / `classDiagram-v2`, an inline fence in `docs/` is acceptable. When in doubt, render to SVG.

## Source-Plus-Rendered Pattern

1. **Editable source** - `docs/assets/tech-design-diagrams/*.mmd`, one diagram per file.
2. **Rendered asset** - matching `docs/assets/tech-design-diagrams/*.svg` checked in.
3. **`docs/tech-design.md`** references the SVG, not a Mermaid fence:

   ```md
   <!-- Mermaid source: assets/tech-design-diagrams/{name}.mmd -->
   ![{Title}](assets/tech-design-diagrams/{name}.svg)
   ```

4. **`docs/tech-design.html`** wraps the same SVG in the diagram-container shell (see Viewer Controls below):

   ```html
   <figure class="diagram" data-title="{Title}">
     <img src="assets/tech-design-diagrams/{name}.svg" alt="{Title}" />
   </figure>
   ```

5. **Do not** include a live Mermaid runtime in generated HTML:
   - no `mermaid@...` CDN `<script>`
   - no `class="mermaid"` blocks
   - no `mermaid.initialize(...)` call

## Filename Convention

`docs/assets/tech-design-diagrams/{NN}-{kebab-name}.{mmd,svg}` where `{NN}` is a zero-padded two-digit ordinal in document order. The number is for sort stability across `Get-ChildItem` and PR diffs - not a fixed registry. Pick `{kebab-name}` to match the section subject (`05-service-topology`, `12-multi-tenancy-enforcement`). Reserve gaps when dropping a section so cross-doc deep links remain valid.

## Document Format

`docs/tech-design.md` opens with a short header and a Table of Contents whose anchors match the GitHub auto-slug for each section heading.

```md
# {ProjectName} - Technical Design Document

> **Audience**: Developers onboarding to the project
> **Last updated**: {YYYY-MM}

---

## Table of Contents

1. [Overview](#1-overview)
2. [{Section title}](#2-{slug})
...

---

## 1. Overview

...

## 2. {Section title}

...
```

Heading rules:

- Section headings use the numbered form (`## 2. C4 Architecture Diagrams`). GitHub's slugger turns it into `#2-c4-architecture-diagrams`, which is what the TOC entries point at.
- Sub-section numbering (`### 2.1`, `### 2.2`) follows the same rule for inline cross-section links like `[Section 11: Audit Strategy](#11-audit-strategy)`.
- Section count and titles are **project-driven**. Pull section needs from the entity list, resource list, and design decisions - not from a fixed scaffold template.

## Viewer Controls (`docs/tech-design.html`)

`tech-design.html` is a self-contained static viewer with **no external CDN dependencies**. It must run when opened from the filesystem (`file://`) or served as a plain static asset. Add the following controls:

### 1. Sticky TOC with scroll-spy

A left-side sidebar listing every `<h2 id="...">`. The current section highlights as the user scrolls. The TOC collapses to a top-of-page menu on screens < 900 px.

### 2. Smooth-scroll + back-to-top button

Anchor-link clicks use `scroll-behavior: smooth`. A floating "up" button appears once the user has scrolled past one viewport and scrolls back to the top.

### 3. Click-to-zoom diagrams

Each `<figure class="diagram">` is keyboard-focusable and opens a modal viewer on click / Enter / Space. The modal supports:

- pinch / wheel zoom (CSS transform on the SVG)
- click-and-drag pan once zoomed
- Esc / overlay click to close
- `+` / `-` keys to step zoom
- `0` key to reset zoom and pan to fit

Implement zoom/pan with a vanilla `svg-pan-zoom`-style approach - pure JS with `pointer` events, CSS `transform: matrix(...)`, and a small viewer class. Do **not** add a runtime dependency.

### 4. Dark theme by default, OS-preference aware

Match the GitHub dark palette used by the reference doc (`--bg: #0d1117`, `--surface: #161b22`, `--accent: #58a6ff`). Respect `prefers-color-scheme: light` if present, but default dark.

### 5. Keyboard shortcuts panel

A `?` keypress opens a small overlay listing the shortcuts above. Close with Esc.

The full viewer (CSS + JS + HTML shell) lives in [../templates/tech-design-template.md](../templates/tech-design-template.md) under section HTML Viewer Shell.

## Render Gate (scaffold time)

Run after creating or editing any `.mmd` file. Fails fast on the first diagram that does not render.

```powershell
powershell -NoProfile -Command '& {
  $fail = @()
  Get-ChildItem "docs\assets\tech-design-diagrams\*.mmd" | Sort-Object Name | ForEach-Object {
    $out = [System.IO.Path]::ChangeExtension($_.FullName, ".svg")
    npx -y "@mermaid-js/mermaid-cli@<latest-stable>" -i $_.FullName -o $out -t dark -b "#0f1419" --quiet
    if ($LASTEXITCODE -ne 0) { $fail += $_.Name }
  }
  if ($fail.Count -eq 0) { "all ok" } else { $fail; exit 1 }
}'
```

Resolve `<latest-stable>` when generating the project and record it in the project's npm lockfile so repeated renders are deterministic. Theme/background (`-t dark -b "#0f1419"`) is the scaffold default; override only if the project's `docs/` template uses a different theme.

## Final Doc Validation

Run before declaring the tech-design docs done. All checks must exit clean.

```powershell
# 1. No live Mermaid in either doc
rg -n -e '```mermaid' -e 'class="mermaid"' -e 'mermaid\.initialize' -e 'mermaid@' docs\tech-design.md docs\tech-design.html

# 2. Whitespace/CRLF damage on the SVG payload
git diff --check

# 3. Every .md SVG reference resolves on disk
powershell -NoProfile -Command '& {
  $bad=@(); Select-String -Path docs\tech-design.md -Pattern "assets/tech-design-diagrams/[^)]+\.svg" -AllMatches |
    ForEach-Object { $_.Matches } | ForEach-Object {
      $rel="docs/" + $_.Value
      if (-not (Test-Path $rel)) { $bad += $_.Value }
    }
  if ($bad.Count -eq 0) { "all svg refs resolve" } else { $bad; exit 1 }
}'
```

Also verify every TOC anchor resolves: every `[N. ...](#n-...)` link in the body must match a `## N. ...` heading. The auto-slug rule is lowercase, spaces -> hyphens, leading numbers preserved (`## 2. C4 Architecture Diagrams` -> `#2-c4-architecture-diagrams`).

## Expected Result

- `docs/tech-design.md` renders cleanly on GitHub - no Mermaid parser failures, no "Unable to render rich display" banners.
- `.mmd` source remains editable; rerunning the render gate regenerates the `.svg` deterministically.
- `docs/tech-design.html` opens directly from the filesystem with a sticky TOC, scroll-spy highlight, click-to-zoom modal with pan, and a `?` shortcuts panel - no external CDN.
- Markdown and HTML share the same SVG assets, so a diagram edit only requires one `.mmd` change + one render-gate run.
