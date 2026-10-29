---
version: 1
slug: "main-py"
primary_target: "src/window.vala"
related_targets: ["themes"]
---

## Scope
Whole app shell + all five tabs + six theme files (themes/*.css). Visitor mode: Operate.

## Audience and task
Tor1 daily (monitor open for hours beside games) and GitHub visitors judging screenshots. Task: spot what is eating the machine and act on it (sort, search, right-click actions).

## Constraints
Theme identities and unit colors pinned (PRODUCT.md). Rendering must stay cheap: no CSS transitions, shadows, gradients; no per-cell callbacks. Native GTK controls only.

## Direction contract
THESIS: The process list is a departure board, not a spreadsheet: load is typeset. Refuses the category default of a flat grey grid where 0.0% and 85% wear the same weight, plus a big centered app title eating the top of the screen.
OWN-WORLD: Japanese railway timetable (jikokuhyō): strict tabular figures in a fixed column grid, hairline rules, compact gothic sans (Inter, tnum), a one-line header strip. Each theme's palette maps to roles: ground, header strip, rule, ink, dim ink, idle ink, accent, hot. Underlined tabs, not pills.
STORY: Glance at the header strip (CPU / MEM live), see the bold hot rows at the top, right-click to act.
FIRST VIEWPORT: Header strip 48px: wordmark left, tabs inline, live CPU/MEM figures right-aligned. Toolbar row: filter, tree, search (fills), count, pause. Table fills the rest; header row in small tracked caps.
FORM: Timetable, position 6 of 7 on the ordered list; seed:2afe8d1a4caa96f7
SIGNATURE: Load-band typesetting: CPU and memory cells step idle (dim light) / normal / hot (bold accent); zero I/O rates dim. Same rule drives Resources figures.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
