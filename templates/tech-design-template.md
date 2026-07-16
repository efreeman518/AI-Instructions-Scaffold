# Tech Design Template - `docs/tech-design.md` + `docs/tech-design.html`

Scaffold output: `docs/tech-design.md` and `docs/tech-design.html` in the target project, with rendered SVGs under `docs/assets/tech-design-diagrams/`. Diagrams follow the source-plus-SVG pattern in [../support/tech-design-diagrams.md](../support/tech-design-diagrams.md).

Reference example: <https://github.com/efreeman518/AI-Instructions-ReferenceApp/blob/main/docs/tech-design.md>.

## What This Template Owns

- The **format**: doc shell, TOC pattern, heading numbering, GitHub anchor rules.
- The **HTML viewer**: self-contained CSS + vanilla JS with sticky TOC + scroll-spy, click-to-zoom modal with pan, smooth scroll, keyboard shortcuts.

## What It Does NOT Own

- The diagram list. Section count and diagram inventory are **project-driven** - generate sections that the scaffolded code actually needs, named from the entity list (`.scaffold/domain-specification.yaml`), the resource list (`.scaffold/resource-implementation.yaml`), and the active design decisions (`.scaffold/DESIGN-DECISIONS.md`). Do not pad with stub sections for unused subsystems.

## Generation Rules

1. Every diagram embeds an `.svg` from `docs/assets/tech-design-diagrams/` - never an inline `mermaid` fence. Filenames follow `{NN}-{kebab-name}.{mmd,svg}` (see [../support/tech-design-diagrams.md](../support/tech-design-diagrams.md) section Filename Convention).
2. Section headings use the numbered form (`## 2. {Section}`) so GitHub's auto-slugger produces `#2-{section}`.
3. The HTML viewer references the **same** SVGs as the markdown - no second render pass.
4. Replace `{ProjectName}` and other placeholders per [../ai/placeholder-tokens.md](../ai/placeholder-tokens.md).
5. Run the render gate every time a `.mmd` file is added or edited. Run the final-doc validation before declaring the doc done.
6. When AI or hosted UI test lanes are generated, include durable rationale: AI provider order (Azure Foundry -> Foundry Local -> no-op), `Test.Aspire` vs `Test.FoundryLocal` split, the optional LiveAI classification owned by [../skills/ai-integration.md](../skills/ai-integration.md), required-infrastructure false opt-outs and Docker preflight, post-preflight failures staying red with diagnostics, Uno Skia canvas bridge rationale, one cumulative startup deadline, bounded Playwright runner design, and Aspire-hosted UI URL resolution. Document env var or Aspire-resolved URL only; no fixed localhost fallback URLs in `docs/tech-design.md` or `docs/tech-design.html`. Put exact commands and pass conditions in README/test README; keep this doc as architecture/test rationale.

## Markdown Doc Shell (`docs/tech-design.md`)

```md
# {ProjectName} - Technical Design Document

> **Audience**: Developers onboarding to the project
> **Last updated**: {YYYY-MM}

---

## Table of Contents

1. [Overview](#1-overview)
2. [{Section title}](#2-{slug})
3. [{Section title}](#3-{slug})
N. [{Section title}](#n-{slug})

---

## 1. Overview

{One-paragraph elevator pitch.}

### Tech Stack

| Layer | Technology |
|-------|-----------|
| ... | ... |

### Design Principles

{Pull from `.scaffold/DESIGN-DECISIONS.md`.}

---

## 2. {Section title}

{Intro paragraph.}

<!-- Mermaid source: assets/tech-design-diagrams/{NN}-{kebab-name}.mmd -->
![{Title}](assets/tech-design-diagrams/{NN}-{kebab-name}.svg)

> **Diagram legend:** {...}

---

## N. {Section title}

...
```

Cross-section references use the same slug form: `[See Section 11: Audit Strategy](#11-audit-strategy)`.

## HTML Viewer Shell (`docs/tech-design.html`)

Self-contained - no CDN, no build step. Open directly from the filesystem or serve as a static asset. The shell below is the minimum; layout/typography tokens match the GitHub dark palette and can be overridden per project.

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{ProjectName} - Technical Design</title>
<style>
  :root {
    --bg: #0d1117; --surface: #161b22; --border: #30363d;
    --text: #e6edf3; --text-muted: #8b949e;
    --accent: #58a6ff; --accent-2: #3fb950; --purple: #bc8cff;
    --sidebar: 280px;
  }
  @media (prefers-color-scheme: light) {
    :root { --bg:#fff; --surface:#f6f8fa; --border:#d0d7de; --text:#1f2328; --text-muted:#656d76; }
  }
  * { box-sizing: border-box; }
  html { scroll-behavior: smooth; }
  body { margin: 0; font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
         background: var(--bg); color: var(--text); }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }
  code { background: var(--surface); border: 1px solid var(--border); border-radius: 4px; padding: 1px 6px; font-size: .9em; }
  pre { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 1rem; overflow-x: auto; }
  table { border-collapse: collapse; width: 100%; margin: 1rem 0; }
  th, td { border: 1px solid var(--border); padding: .5rem .8rem; text-align: left; vertical-align: top; }
  th { background: var(--surface); }

  /* Layout: sidebar + content */
  .layout { display: grid; grid-template-columns: var(--sidebar) 1fr; min-height: 100vh; }
  .sidebar {
    position: sticky; top: 0; align-self: start; height: 100vh; overflow-y: auto;
    border-right: 1px solid var(--border); padding: 1.5rem 1rem; background: var(--surface);
  }
  .sidebar h2 { font-size: 1rem; margin: 0 0 .75rem; color: var(--text-muted); text-transform: uppercase; letter-spacing: .05em; }
  .sidebar ol { list-style: none; counter-reset: toc; padding: 0; margin: 0; }
  .sidebar li { counter-increment: toc; margin: .15rem 0; }
  .sidebar li a {
    display: block; padding: .35rem .6rem; border-radius: 6px; color: var(--text); font-size: .92rem;
    border-left: 2px solid transparent;
  }
  .sidebar li a::before { content: counter(toc) ". "; color: var(--accent); font-weight: 600; }
  .sidebar li a:hover { background: rgba(88,166,255,0.08); text-decoration: none; }
  .sidebar li a.active { background: rgba(88,166,255,0.14); border-left-color: var(--accent); }
  .content { padding: 2rem 2.5rem; max-width: 1100px; }
  h1 { font-size: 2rem; border-bottom: 2px solid var(--accent); padding-bottom: .4rem; margin: 0 0 1rem; }
  h2 { font-size: 1.55rem; color: var(--accent); margin: 2.25rem 0 1rem; border-bottom: 1px solid var(--border); padding-bottom: .3rem; }
  h3 { font-size: 1.2rem; color: var(--purple); margin: 1.4rem 0 .6rem; }
  .subtitle { color: var(--text-muted); font-size: .95rem; margin: -.25rem 0 1.5rem; }

  /* Diagrams */
  .diagram {
    background: var(--surface); border: 1px solid var(--border); border-radius: 10px;
    margin: 1.25rem 0; padding: 1rem; overflow: hidden; cursor: zoom-in;
    position: relative;
  }
  .diagram img, .diagram svg { display: block; max-width: 100%; margin: 0 auto; }
  .diagram figcaption {
    margin-top: .5rem; color: var(--text-muted); font-size: .85rem; text-align: center;
  }
  .diagram:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

  /* Zoom modal */
  .zoom-overlay {
    position: fixed; inset: 0; background: rgba(0,0,0,0.85); display: none;
    align-items: center; justify-content: center; z-index: 1000; touch-action: none;
  }
  .zoom-overlay.open { display: flex; }
  .zoom-stage {
    width: 92vw; height: 88vh; overflow: hidden; position: relative; cursor: grab;
    background: var(--bg); border: 1px solid var(--border); border-radius: 8px;
  }
  .zoom-stage.dragging { cursor: grabbing; }
  .zoom-stage img {
    position: absolute; top: 50%; left: 50%; transform-origin: 0 0;
    user-select: none; -webkit-user-drag: none; pointer-events: none;
  }
  .zoom-controls {
    position: absolute; top: 1rem; right: 1rem; display: flex; gap: .35rem;
    background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: .35rem;
  }
  .zoom-controls button {
    background: transparent; border: 0; color: var(--text); width: 32px; height: 32px;
    font-size: 1rem; border-radius: 6px; cursor: pointer;
  }
  .zoom-controls button:hover { background: rgba(255,255,255,0.06); }
  .zoom-title {
    position: absolute; top: 1rem; left: 1rem; padding: .4rem .8rem;
    background: var(--surface); border: 1px solid var(--border); border-radius: 6px;
    color: var(--text-muted); font-size: .9rem; max-width: 60%;
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }

  /* Back-to-top */
  .to-top {
    position: fixed; right: 1.25rem; bottom: 1.25rem; width: 42px; height: 42px;
    border-radius: 50%; background: var(--surface); border: 1px solid var(--border);
    color: var(--text); font-size: 1.1rem; cursor: pointer; display: none;
  }
  .to-top.visible { display: flex; align-items: center; justify-content: center; }

  /* Shortcuts panel */
  .shortcuts {
    position: fixed; inset: 50% auto auto 50%; transform: translate(-50%, -50%);
    background: var(--surface); border: 1px solid var(--border); border-radius: 10px;
    padding: 1.5rem 2rem; display: none; z-index: 1100; min-width: 320px;
  }
  .shortcuts.open { display: block; }
  .shortcuts h3 { margin: 0 0 .8rem; }
  .shortcuts kbd {
    background: var(--bg); border: 1px solid var(--border); border-radius: 4px;
    padding: 1px 6px; font-size: .85rem; font-family: ui-monospace, monospace;
  }
  .shortcuts table td:first-child { white-space: nowrap; }

  @media (max-width: 900px) {
    .layout { grid-template-columns: 1fr; }
    .sidebar { position: static; height: auto; max-height: 50vh; border-right: 0; border-bottom: 1px solid var(--border); }
    .content { padding: 1.25rem 1rem; }
  }
</style>
</head>
<body>
<div class="layout">

  <nav class="sidebar" aria-label="Table of contents">
    <h2>Contents</h2>
    <ol id="toc">
      <li><a href="#1-overview">Overview</a></li>
      <!-- Generated: one <li><a href="#N-slug">Title</a></li> per ## heading -->
    </ol>
  </nav>

  <main class="content">
    <h1>{ProjectName} - Technical Design Document</h1>
    <p class="subtitle">Audience: developers onboarding to the project - Last updated: {YYYY-MM}</p>

    <h2 id="1-overview">1. Overview</h2>
    <!-- ... -->

    <h2 id="2-{slug}">2. {Section title}</h2>
    <p>{Intro.}</p>
    <figure class="diagram" tabindex="0" data-title="{Title}">
      <img src="assets/tech-design-diagrams/{NN}-{kebab-name}.svg" alt="{Title}" />
      <figcaption>{Title}</figcaption>
    </figure>

    <!-- Repeat per project-driven section. -->
  </main>

</div>

<button class="to-top" id="toTop" aria-label="Back to top">up</button>

<div class="zoom-overlay" id="zoom" role="dialog" aria-modal="true" aria-label="Diagram viewer">
  <div class="zoom-stage" id="zoomStage">
    <div class="zoom-title" id="zoomTitle"></div>
    <div class="zoom-controls">
      <button data-act="zoom-in"  aria-label="Zoom in">+</button>
      <button data-act="zoom-out" aria-label="Zoom out">-</button>
      <button data-act="reset"    aria-label="Reset">-></button>
      <button data-act="close"    aria-label="Close">x</button>
    </div>
    <img id="zoomImg" alt="" />
  </div>
</div>

<div class="shortcuts" id="shortcuts" role="dialog" aria-modal="true" aria-label="Keyboard shortcuts">
  <h3>Keyboard shortcuts</h3>
  <table>
    <tr><td><kbd>?</kbd></td><td>Toggle this panel</td></tr>
    <tr><td><kbd>Esc</kbd></td><td>Close modal / panel</td></tr>
    <tr><td>Click diagram / <kbd>Enter</kbd></td><td>Open zoom viewer</td></tr>
    <tr><td><kbd>+</kbd> / <kbd>-</kbd></td><td>Zoom in / out (in viewer)</td></tr>
    <tr><td><kbd>0</kbd></td><td>Reset zoom &amp; pan</td></tr>
    <tr><td>Mouse wheel / pinch</td><td>Zoom at cursor</td></tr>
    <tr><td>Click &amp; drag</td><td>Pan (when zoomed)</td></tr>
  </table>
</div>

<script>
(function () {
  // ---- Scroll-spy: highlight the TOC entry for the section currently in view ----
  const tocLinks = Array.from(document.querySelectorAll('#toc a'));
  const sections = tocLinks
    .map(a => document.getElementById(a.getAttribute('href').slice(1)))
    .filter(Boolean);
  const linkFor = id => tocLinks.find(a => a.getAttribute('href') === '#' + id);
  const spy = new IntersectionObserver(entries => {
    entries.forEach(e => {
      if (e.isIntersecting) {
        tocLinks.forEach(a => a.classList.remove('active'));
        const a = linkFor(e.target.id);
        if (a) a.classList.add('active');
      }
    });
  }, { rootMargin: '-40% 0px -55% 0px', threshold: 0 });
  sections.forEach(s => spy.observe(s));

  // ---- Back-to-top button ----
  const toTop = document.getElementById('toTop');
  window.addEventListener('scroll', () => {
    toTop.classList.toggle('visible', window.scrollY > window.innerHeight);
  }, { passive: true });
  toTop.addEventListener('click', () => window.scrollTo({ top: 0, behavior: 'smooth' }));

  // ---- Zoom modal: click-to-open, wheel/pinch zoom, drag pan ----
  const overlay = document.getElementById('zoom');
  const stage   = document.getElementById('zoomStage');
  const img     = document.getElementById('zoomImg');
  const title   = document.getElementById('zoomTitle');
  let scale = 1, tx = 0, ty = 0;
  const MIN = 0.25, MAX = 16;

  const apply = () => {
    img.style.transform = `translate(calc(-50% + ${tx}px), calc(-50% + ${ty}px)) scale(${scale})`;
  };
  const reset = () => { scale = 1; tx = 0; ty = 0; apply(); };
  const open  = (src, t) => {
    img.src = src; title.textContent = t || '';
    reset(); overlay.classList.add('open');
  };
  const close = () => { overlay.classList.remove('open'); img.src = ''; };

  document.querySelectorAll('.diagram').forEach(fig => {
    const i = fig.querySelector('img');
    if (!i) return;
    const handler = () => open(i.src, fig.dataset.title || i.alt || '');
    fig.addEventListener('click', handler);
    fig.addEventListener('keydown', e => {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); handler(); }
    });
  });

  stage.addEventListener('wheel', e => {
    e.preventDefault();
    const rect = stage.getBoundingClientRect();
    const cx = e.clientX - rect.left - rect.width / 2;
    const cy = e.clientY - rect.top  - rect.height / 2;
    const factor = e.deltaY < 0 ? 1.15 : 1 / 1.15;
    const next = Math.min(MAX, Math.max(MIN, scale * factor));
    // zoom toward cursor
    tx = (tx - cx) * (next / scale) + cx;
    ty = (ty - cy) * (next / scale) + cy;
    scale = next; apply();
  }, { passive: false });

  let dragging = false, sx = 0, sy = 0;
  stage.addEventListener('pointerdown', e => {
    dragging = true; stage.classList.add('dragging');
    sx = e.clientX - tx; sy = e.clientY - ty;
    stage.setPointerCapture(e.pointerId);
  });
  stage.addEventListener('pointermove', e => {
    if (!dragging) return;
    tx = e.clientX - sx; ty = e.clientY - sy; apply();
  });
  stage.addEventListener('pointerup',   () => { dragging = false; stage.classList.remove('dragging'); });
  stage.addEventListener('pointercancel', () => { dragging = false; stage.classList.remove('dragging'); });

  overlay.addEventListener('click', e => { if (e.target === overlay) close(); });
  document.querySelectorAll('.zoom-controls button').forEach(b => {
    b.addEventListener('click', e => {
      e.stopPropagation();
      const a = b.dataset.act;
      if (a === 'close') close();
      else if (a === 'reset') reset();
      else {
        const factor = a === 'zoom-in' ? 1.25 : 1 / 1.25;
        scale = Math.min(MAX, Math.max(MIN, scale * factor)); apply();
      }
    });
  });

  // ---- Shortcuts panel + global keys ----
  const shortcuts = document.getElementById('shortcuts');
  document.addEventListener('keydown', e => {
    const inField = /^(input|textarea|select)$/i.test(e.target.tagName);
    if (inField) return;
    if (e.key === '?' || (e.shiftKey && e.key === '/')) {
      shortcuts.classList.toggle('open'); return;
    }
    if (e.key === 'Escape') {
      if (overlay.classList.contains('open')) close();
      shortcuts.classList.remove('open');
      return;
    }
    if (overlay.classList.contains('open')) {
      if (e.key === '+' || e.key === '=') { scale = Math.min(MAX, scale * 1.25); apply(); }
      else if (e.key === '-' || e.key === '_') { scale = Math.max(MIN, scale / 1.25); apply(); }
      else if (e.key === '0') reset();
    }
  });
})();
</script>
</body>
</html>
```

The script is intentionally compact (~80 lines of JS, no dependencies). Drop it as-is - only the body markup is project-specific.

## When to Generate

`docs/tech-design.md` is a Phase 5d deliverable. Generate it after `test-templates-quality` is in place and the scaffold satisfies the applicable [final acceptance criteria](../support/final-scaffold-checklist.md). The doc reflects the *shipped* topology - sections whose backing code is not generated are dropped, not stubbed.

Generation order per session:

1. Decide the section list from the actual scaffold output (entities, hosts, integrations, design decisions).
2. Sketch each `.mmd` source per section need.
3. Run the **render gate** (see [../support/tech-design-diagrams.md](../support/tech-design-diagrams.md) section Render Gate) to produce `.svg` siblings.
4. Write `docs/tech-design.md` using the markdown shell above, embedding the rendered SVGs.
5. Write `docs/tech-design.html` using the HTML viewer shell, mirroring the TOC.
6. Run the **final-doc validation** - Mermaid-runtime grep, `git diff --check`, SVG-reference check, TOC anchor check.
7. Spot-check the GitHub render after pushing and open `tech-design.html` from disk to confirm zoom/scroll-spy/shortcuts work offline.
