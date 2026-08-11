# System Monitor ++

A highly optimized, native desktop system monitor built with Python, GTK3, and `psutil`. Features a custom Penpot-inspired UI with real-time performance tracking, advanced process management, and dynamic theming.

## Key Features

*   **3 Main Views:**
    *   **Processes:** List or Tree View with real-time stats (CPU, Memory, Disk I/O). Sortable by clicking headers, plus a built-in search filter.
    *   **Resources:** Real-time Cairo-drawn graphs for CPU usage (overall and per-core), RAM, Swap, and Network activity (with auto-scaling).
    *   **File Systems:** Visual progress bars for mounted partitions showing total, used, and free space.
*   **Advanced Process Management (Context Menu):** 
    *   Change **CPU Affinity** (Linux-specific).
    *   Adjust **Process Priority** (nice values).
    *   Kill (SIGKILL), End (SIGTERM), Stop, or Continue processes.
    *   **Open File Location** (integrates with `xdg-open` / Nemo).
    *   View detailed process **Properties** (cwd, open files, threads).
*   **Custom Highlights & Pins:** Pin favorite processes to the top (📌) or assign custom highlight colors via a native color picker. Preferences are saved automatically to `~/.config/system-monitor-pp/process_config.json`.
*   **Dynamic Theming:** Switch between 6 custom CSS palettes on the fly (Default, EVA-01, MAGI, EVA-00, EVA-02, Pastel Fuchsia) without restarting the app.
*   **Deeply Optimized:** Built for speed and low CPU usage. Utilizes background threads (`ThreadPoolExecutor`), GTK idle updates, and aggressive caching to ensure the UI never freezes during data polling.

## Installation

Designed for Linux environments (specifically tested on Linux Mint/Debian-based distros). It is highly recommended to install GTK bindings via your system package manager and `psutil` via `pip`.

### 1. Install Dependencies

```bash
sudo apt update
sudo apt install -y python3-gi gir1.2-gtk-3.0 python3-pip

# Install Python requirements (psutil)
pip install --break-system-packages -r requirements.txt
```

### 2. Install UI Font (Optional)
The UI is styled to use **JetBrains Mono** for its data tables. If not installed, it will fall back to your system's default monospace font.

```bash
sudo apt install fonts-jetbrains-mono
```

## Running the App

Ensure you have the correct directory structure (with the `themes/` folder present), then run:

```bash
python3 main.py
```

## Directory Structure

```text
system-monitor-pp/
├── main.py            # Main application, UI, and caching logic
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
