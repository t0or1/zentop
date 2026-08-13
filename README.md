# zentop

A highly optimized, native desktop system monitor built with Python, GTK3, and `psutil`. Features a custom Penpot-inspired UI with real-time performance tracking, advanced process management, a live consumption pie chart, and dynamic theming.

## Key Features

* **5 Main Views:**
    * **Processes:** List or Tree View with real-time stats (CPU, Memory, Disk I/O, Status, Priority, Started, CPU Time). Sortable by clicking any column header (click again to reverse), plus a built-in search filter and an All/My/Active process filter. Pause button (top-right of the search bar) freezes the table so you can browse or search without rows reordering under you.
    * **Resources:** Real-time Cairo-drawn graphs for CPU usage (overall and per-core), RAM + Swap, and Network activity (auto-scaling).
    * **Pie Graph:** Live pie chart of the top 10 processes by overall consumption (CPU% + Memory%, blended), with the rest grouped into "Others". Shares the same background data fetch as Processes — no extra process scan.
    * **File Systems:** Visual progress bars for mounted partitions showing total, used, and free space.
    * **Themes:** Live theme switcher (see below), applied instantly and remembered across restarts.
* **Advanced Process Management (Right-click Context Menu):**
    * **Pin to Top** — keep a process pinned above the rest regardless of sort order (📌), persisted by process name.
    * Change **CPU Affinity** (Linux-specific), with per-core checkboxes.
    * Adjust **Process Priority** (nice value) — radio-button presets that show the *current* priority, or a custom value.
    * Kill (SIGKILL), End (SIGTERM), Stop, or Continue processes.
    * **Open File Location** (integrates with `xdg-open` / Nemo).
    * **Highlight Color** — assign a custom color to a process via a native color picker, to spot it at a glance over time.
    * View detailed process **Properties** (cwd, cmdline, threads, open files, connections, affinity).
* **Preferences saved automatically** to `~/.config/system-monitor-pp/` — pins and highlight colors in `process_config.json`, active theme in `app_config.json`.
* **Dynamic Theming:** Switch between 6 CSS palettes on the fly, no restart needed — Default (GitHub Dark), EVA-01, MAGI, EVA-00, EVA-02, and Pastel Fuchsia.
* **Deeply Optimized:** Built for speed and low CPU usage, comparable to a native system monitor despite being Python:
    * Background `ThreadPoolExecutor` for all process polling — the GTK main thread never blocks.
    * Only the currently visible tab is polled; the rest stay idle.
    * GTK stores are updated in place (row diffing + `reorder()`) instead of being torn down and rebuilt every tick.
    * No per-cell Python callbacks for rendering — highlighting is done via bound GTK attributes.
    * Aggressive caching: per-UID usernames, static per-process fields (name/ppid/start time), disk I/O throttled to every 3rd tick, per-color contrast lookups memoized.

## Installation

Designed for Linux environments (specifically tested on Linux Mint/Debian-based distros). Install GTK bindings via your system package manager and `psutil` via `pip`.

### 1. Install Dependencies

```bash
sudo apt update
sudo apt install -y python3-gi gir1.2-gtk-3.0 python3-pip

pip install --break-system-packages -r requirements.txt
```

### 2. Install UI Font (Optional)

The UI is styled to use **JetBrains Mono** for its data tables. If not installed, it falls back to your system's default monospace font.

```bash
sudo apt install fonts-jetbrains-mono
```

## Running the App

Make sure the directory structure below is intact (the `themes/` folder must sit next to `main.py`), then run:

```bash
python3 main.py
```

## Directory Structure

```text
zentop/
├── main.py            # Application, UI, and caching logic
├── requirements.txt   # Python dependencies
├── README.md
└── themes/            # CSS theme files
    ├── default.css
    ├── eva00.css
    ├── eva01.css
    ├── eva02.css
    ├── magi.css
    └── pastel.css
```
