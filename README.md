# zentop

A highly optimized native Linux system monitor (GTK3). It comes in two versions:
* **vala-version:** compiled native code, the fastest. Recommended.
* **python-version:** Python + `psutil`, the original.

Both versions show the same views and share settings and themes.

## Look

zentop is typeset like a railway timetable:
* Every number uses tabular figures.
* Hairline rules separate the columns.
* A one-line header strip holds the wordmark, the tabs and live CPU/MEM figures.

Load is shown through type:
* Idle values fade back.
* Hot values (CPU ≥ 20%, memory ≥ 5%) turn bold in the theme's hot color.

The full design system lives in `python-version/DESIGN.md`.

## Key Features

* **Processes:** List or tree view.
    * Sort by any column.
    * Search, plus All/My/Active filters.
    * Pause the table while you browse.
* **Resources:** History graphs for CPU, memory + swap and network, plus a per-core board.
* **Pie Graph:** The top 10 processes by CPU% + memory%.
* **File Systems:** A partition table, plus a WizTree-style treemap or pie of any disk.
* **Themes:** 6 themes, switched live: Default (GitHub Dark), EVA-01, MAGI, EVA-00, EVA-02 and Pastel Pink.
* **Right-click menu on a process:**
    * Pin to Top
    * End / Kill / Stop / Continue
    * Priority
    * CPU Affinity
    * Open File Location
    * Highlight Color
    * Properties
* **Settings** are saved in `~/.config/system-monitor-pp/`.

## Performance (vala-version)

Measured over 60 s on the Processes tab, with about 370 processes running:

| | CPU (of one core) | RAM |
|---|---|---|
| vala-version | 0.8% | 87 MB |
| python-version | 3.7% | 111 MB |

* **Background reads:** `/proc` is read on a background thread.
* **Visible tab only:** only the tab on screen does any work, and nothing runs while the window is minimised.
* **Table updates:** the table only redraws the rows that actually changed.
* **Memory:** stays flat over long sessions.

## vala-version

```bash
sudo apt install valac libgtk-3-dev libgee-0.8-dev libjson-glib-dev libfontconfig-dev
cd vala-version
bash build.sh
./zentop
```

It uses the Inter font from `python-version/fonts/`.

## python-version

```bash
sudo apt install -y python3-gi python3-gi-cairo gir1.2-gtk-3.0 python3-pip
pip install --break-system-packages -r python-version/requirements.txt
cd python-version && python3 main.py
```

If `fonts/` is empty, run `sh fonts/get-fonts.sh`. Without Inter, zentop falls back to Noto Sans or Ubuntu.

## Directory Structure

```text
zentop/
├── python-version/      main.py, DESIGN.md, fonts/, themes/
└── vala-version/
    ├── main.vala        entry point
    ├── window.vala      header strip, tabs, 1 s scheduler
    ├── tab_*.vala       one file per tab
    ├── process_*.vala   /proc scan, worker thread, right-click actions
    ├── *_data.vala      CPU/memory/network and disk readers
    ├── graphs.vala      Cairo graphs, pie, treemap
    ├── theme.vala       theme catalogue and color roles
    └── themes/          one CSS file per theme
```
