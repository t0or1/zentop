---
name: zentop
description: A native GTK3 system monitor typeset like a railway timetable.
colors:
  ground: "#0D1117"
  strip: "#010409"
  surface: "#161B22"
  raised: "#1C2128"
  rule: "#262C36"
  rule-strong: "#3D444D"
  ink: "#E6EDF3"
  ink-dim: "#9198A1"
  ink-idle: "#7D8590"
  accent: "#A78BFA"
  fill: "#8B5CF6"
  hot: "#C3ADFF"
  selection: "#2B2149"
  selection-ink: "#FFFFFF"
  graph-ground: "#10151C"
  graph-grid: "#1B222C"
  graph-cpu: "#8B5CF6"
  graph-mem: "#A78BFA"
  graph-swap: "#F0883E"
  graph-rx: "#8B5CF6"
  graph-tx: "#F472B6"
  series-0: "#8B5CF6"
  series-1: "#F472B6"
  series-2: "#3FB950"
  series-3: "#D29922"
  series-4: "#58A6FF"
  series-5: "#F85149"
  series-6: "#A78BFA"
  series-7: "#DB61A2"
typography:
  wordmark:
    fontFamily: "Inter, Noto Sans, Ubuntu, sans-serif"
    fontSize: "14px"
    fontWeight: 800
    letterSpacing: "3px"
  tab:
    fontFamily: "Inter, Noto Sans, Ubuntu, sans-serif"
    fontSize: "12px"
    fontWeight: 600
    letterSpacing: "1px"
  body:
    fontFamily: "Inter, Noto Sans, Ubuntu, sans-serif"
    fontSize: "13px"
    fontWeight: 400
  figure:
    fontFamily: "Inter, Noto Sans, Ubuntu, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    fontFeature: "tnum"
  label:
    fontFamily: "Inter, Noto Sans, Ubuntu, sans-serif"
    fontSize: "11px"
    fontWeight: 700
  column-head:
    fontFamily: "Inter, Noto Sans, Ubuntu, sans-serif"
    fontSize: "11px"
    fontWeight: 600
    letterSpacing: "1px"
rounded:
  control: "4px"
  bar: "2px"
  none: "0px"
spacing:
  cell-x: "8px"
  cell-y: "3px"
  gutter: "12px"
  page: "20px"
components:
  tab:
    textColor: "{colors.ink-dim}"
    typography: "{typography.tab}"
    padding: "15px 14px 13px 14px"
  tab-active:
    textColor: "{colors.ink}"
  control:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "3px 10px"
    height: "24px"
  header-strip:
    backgroundColor: "{colors.strip}"
    padding: "0 20px"
    height: "48px"
  table-cell:
    textColor: "{colors.ink}"
    typography: "{typography.figure}"
    padding: "3px 8px"
  table-cell-idle:
    textColor: "{colors.ink-idle}"
  table-cell-hot:
    textColor: "{colors.hot}"
  meter:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.bar}"
    height: "6px"
---
# Design System: zentop

## Overview

**Creative North Star: "The Departure Board"**

zentop reads like a Japanese railway timetable (jikokuhyō), not a spreadsheet. Figures sit in strict tabular columns, hairline rules separate them, and a single 48px header strip carries the wordmark, the tabs and the live CPU/MEM figures. Load is shown through type: a process that is costing you something is bold and in the hot colour, and an idle one fades back. Nothing decorative competes with the numbers.

The six themes are identities, not recolours. Every theme fills the same set of roles (ground, strip, rule, ink, dim ink, idle ink, accent, fill, hot, selection, graph roles, eight series colours), so layout and behaviour never change between them. Rendering must stay cheap: zentop runs for hours next to games on a 10th-gen i3.

**Key Characteristics:**
- Tabular figures everywhere a number appears (Inter `tnum`).
- Load bands: values are typeset idle, normal or hot instead of being uniformly grey.
- One-line header strip with underlined tabs instead of a big title and pills.
- Hairline 1px rules; no shadows, gradients or transitions.
- The app reads the colours from the theme CSS (`.zt-c-<role>`), so Cairo graphs follow the theme with no hard-coded palettes.

## Colors

All tokens in the frontmatter are the DEFAULT (GitHub Dark) values. Each theme file in `themes/` redefines the same roles.

### Primary
- **Accent** (`#A78BFA`): checked tab underline, sort arrow, focus.
- **Fill** (`#8B5CF6`): meters, the CPU graph, progress cells.

### Neutral
- **Ground** (`#0D1117`), **Strip** (`#010409`), **Surface** (`#161B22`) and **Rule** (`#262C36`) build the page from flat planes and hairlines.
- **Ink** (`#E6EDF3`), **Dim** (`#9198A1`) and **Idle** (`#7D8590`) form a three-step text ladder; each step is at least 4.5:1 on the ground.

### Theme roster

| theme | ground | ink | accent | fill | hot |
|---|---|---|---|---|---|
| default | `#0D1117` | `#E6EDF3` | `#A78BFA` | `#8B5CF6` | `#C3ADFF` |
| eva01 | `#0F0A1F` | `#ECE6F7` | `#8CFF6B` | `#7B2FD9` | `#A6FF8C` |
| magi | `#070604` | `#FFB000` | `#FFB000` | `#FFB000` | `#FFE6A8` |
| eva00 | `#0A1420` | `#E3F0F8` | `#FF8C1A` | `#FF8C1A` | `#FFA347` |
| eva02 | `#150808` | `#F7EADF` | `#FF6A52` | `#E8412C` | `#FFD23F` |
| pastel | `#FDF0F5` | `#3D1428` | `#B0105A` | `#E85CA6` | `#B0105A` |

### Named Rules
**The Load Band Rule.** CPU below 0.5% and memory below 0.5% use idle ink; CPU from 20% and memory from 5% use hot ink at weight 700. Zero disk rates use idle ink. A row highlight overrides the band with its own contrast colour.
**The Role Rule.** Code never names a hex value. The code asks the stylesheet for a role (`.zt-c-ink`, `.zt-c-g-cpu`, `.zt-c-s0`…), and a new theme is just one CSS file.

## Typography

**Inter** is bundled in `fonts/` (OFL) and registered per-app through fontconfig, so the timetable look does not depend on what is installed. The fallbacks are Noto Sans and Ubuntu.

### Hierarchy
- **Wordmark**: 14px / 800, tracked 3px, uppercase.
- **Tabs**: 12px / 600, tracked 1px, uppercase.
- **Column heads and section labels**: 11px / 600–700, uppercase, dim ink.
- **Body and figures**: 13px / 400. Figures use `tnum`; hot figures use 700.

### Named Rules
**The Tracking Rule.** Letter-spacing goes only on single-line uppercase strings inside a fixed-height container (the wordmark, tabs, column heads, stat keys). On free-standing GTK3 labels that contain a space, letter-spacing makes the label reserve two lines.

## Layout

- The header strip is 48px: wordmark on the left, tabs inline, live figures on the right.
- Pages use a 20px side margin. Toolbars are one row: filter, tree, search (fills the row), count, pause.
- Table cells are padded 8px × 3px. Resources stacks each figure, then its graph, then its bars. The per-core grid has 2 columns up to 4 cores and 4 columns above that.
- The Pie and File Systems tabs put the graph on the left and a 320px legend column on the right.

## Elevation & Depth

None. Depth comes from flat planes (strip, then ground, then surface) and 1px rules. Shadows, gradients and transitions are explicitly turned off in every theme for render cost.

## Shapes

Controls have a 4px radius and meters a 2px radius. Tabs, tables and treemap tiles are square, with 1px gutters between tiles. Pie wedges are separated by 2px gaps in the ground colour around a hollow centre at 0.58 of the radius.

## Components

### Navigation
GTK StackSwitcher, not homogeneous. Each tab is transparent with a 2px bottom border that turns to the accent colour when checked.

### Inputs / Fields
The combobox, tree toggle, search entry and buttons share one recipe: surface background, 1px rule border, 4px radius and 24px minimum height.

### Load-band table (signature)
A TreeView whose foreground and weight are bound to model columns, so no per-cell code runs. A pinned row gets a symbolic pin icon and a 600-weight name.

### Graphs
Cairo DrawingAreas on the graph ground with a hairline grid. History graphs pin the newest sample to the right edge and draw a 0.16-alpha fill under a 1.5px stroke. The treemap picks label ink per tile for contrast.

## Do's and Don'ts

### Do:
- Do add a theme by writing one CSS file that fills every role, `.zt-c-*` included.
- Do keep numbers in tabular figures and let weight and colour carry load.
- Do update widgets by setting text or values; build them once.

### Don't:
- Don't add transitions, box-shadow, gradients or text-shadow; they cost frame time.
- Don't hard-code colours in the code.
- Don't use letter-spacing on free-standing labels that contain spaces.
- Don't use per-cell `cell_data_func` on the process table.
