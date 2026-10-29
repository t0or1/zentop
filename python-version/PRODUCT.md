# Product

<!-- impeccable:product-schema 1 -->

## Platform

native desktop — GTK3 on Linux (not one of web/ios/android/adaptive; recorded as-is)

## Users
- Primary: the author (Tor1), running zentop daily on a Linux Mint laptop (Acer TravelMate, i3 10th gen, 12 GB) and a Ryzen 7 5700G desktop, often left open for hours next to games.
- Secondary: people who find the GitHub repo (github.com/t0or1/zentop), judge it from screenshots, and install it.

## Product Purpose
A native Linux system monitor that matches GNOME System Monitor's functionality, adds power-user process controls, and looks far better — while using no more CPU than the stock monitor. Success: it can stay open all day without costing frame time, and the repo screenshots make people want to install it.

## Positioning
Not a terminal monitor (htop/btop) and not a stock GTK app: native GTK, deep process control (pin, highlight, affinity, priority), a WizTree-style disk breakdown, and swappable themes with real identities — including Evangelion unit themes.

## Operating Context
- Tabs: Processes (flat/tree table, sortable, filter, search, pause), Resources (per-core CPU, CPU/memory/swap/network history graphs), Pie Graph (top consumers), File Systems (partition table + treemap/pie disk breakdown), Themes (live switcher).
- Right-click process menu: Pin to Top, End/Kill/Stop/Continue, Change Priority, CPU Affinity, Open File Location, Highlight Color, Properties.
- Config persisted in ~/.config/system-monitor-pp/ (process_config.json, app_config.json).
- Two implementations share the themes/ CSS: python-version (complete, GTK3 + psutil) and vala-version (in-progress native rewrite).

## Capabilities and Constraints
- Performance is a hard constraint: GTK3 CSS must stay cheap to render (no transitions, shadows or gradients that add redraw cost); refresh paths already optimized and must not regress.
- UI copy is English.
- Themes are plain GTK3 CSS files in themes/, one per theme, selected via the THEMES list in main.py.

## Brand Commitments
- Name: zentop.
- Six fixed theme identities (names and unit colors are binding): DEFAULT (GitHub Dark, violet accent), EVA-01 (purple + lime green, red alert), MAGI (black, monochrome amber CRT), EVA-00 (pale blue/white + orange), EVA-02 (red/orange + cream), PASTEL PINK (light pink + fuchsia + lavender).

## Evidence on Hand
- Original Penpot mockup (tall condensed uppercase type, pill tabs, dense data table).
- No user counts, stars, testimonials or benchmarks exist — do not invent any.

## Product Principles
1. Cost nothing: the monitor must never be the process eating your CPU.
2. Data first: numbers are scannable at a glance; decoration never competes with them.
3. Themes are identities, not recolors — each one should feel like its source.
4. Native over novel: GTK behaviours (menus, dialogs, sorting) stay where users expect them.
