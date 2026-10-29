# zentop

A highly optimized, native Linux system monitor built with Python, GTK3, and `psutil`, with a native Vala rewrite in progress. It offers real-time performance tracking, advanced process management, a live consumption pie chart, a WizTree-style disk breakdown, and swappable themes.

## Look

zentop is typeset like a railway timetable. Every number uses tabular figures, hairline rules separate the columns, and a one-line header strip holds the wordmark, the tabs, and live CPU/MEM figures.

Load is shown through type:
* Idle values fade back.
* Hot values (CPU ≥ 20%, memory ≥ 5%) turn bold in the theme's hot color.

The themes avoid shadows, gradients and transitions, so the UI stays cheap to render. The full design system lives in `python-version/DESIGN.md`.

## Key Features

* **5 Main Views:**
    * **Processes:** List or tree view with live stats: CPU, memory, disk I/O, status, priority, start time and CPU time.
        * Sort by clicking any column header; click again to reverse.
        * Search and All/My/Active filters.
        * A pause button freezes the table while you browse.
    * **Resources:** Cairo-drawn history graphs for CPU, memory + swap, and network, plus a per-core load board.
    * **Pie Graph:** The top 10 processes by overall consumption (CPU% + memory%), with the rest grouped into "Others".
    * **File Systems:** A partition table with usage bars, plus a treemap or pie breakdown of any disk.
    * **Themes:** A live theme switcher. Your choice is remembered across restarts.
* **Right-click process menu:**
    * Pin to Top
    * End / Kill / Stop / Continue
    * Priority, showing the current value
    * CPU Affinity
    * Open File Location
    * Highlight Color
    * Properties
* **Saved preferences** in `~/.config/system-monitor-pp/`.
* **6 themes:** Default (GitHub Dark), EVA-01, MAGI, EVA-00, EVA-02, and Pastel Pink. Each theme is a single CSS file, and the graphs read their colors from it.
* **Deeply optimized:**
    * Process polling runs in a background thread.
    * Only the visible tab is polled.
    * Stores are updated in place.
    * There are no per-cell Python callbacks, and widgets are built once and only updated afterwards.

## Installation (python-version)

```bash
sudo apt install -y python3-gi python3-gi-cairo gir1.2-gtk-3.0 python3-pip
pip install --break-system-packages -r requirements.txt
```

zentop bundles the **Inter** font (SIL OFL) in `fonts/`. If the folder is empty, download the font with:

```bash
sh fonts/get-fonts.sh
```

Without Inter, zentop falls back to Noto Sans or Ubuntu.

## Running

```bash
cd python-version
python3 main.py
```

## Directory Structure

```text
zentop/
├── python-version/
│   ├── main.py            # App, UI and caching logic
│   ├── requirements.txt
│   ├── DESIGN.md          # Design system (tokens, rules)
│   ├── fonts/             # Inter + get-fonts.sh
│   └── themes/            # One CSS file per theme
└── vala-version/          # Native rewrite (in progress)
```
