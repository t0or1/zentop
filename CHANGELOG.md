# Changelog

## Unreleased

* **Faster tables.** A full redraw of the process table drops from ~15 ms to ~6 ms. All tables now use one text cell (`src/table_text.vala`) that keeps the shaped text of every value it has drawn, instead of GTK re-shaping each cell on every redraw. The Processes tab uses ~35% less CPU while the list reorders, and startup uses ~45% less CPU.
* **Disk scans match `du`.** "Analyze Selected Disk" counts allocated blocks, not apparent sizes, and counts hard-linked files once. Results now add up to the partition's "used" figure; before they were ~6% low. Scans run on several threads, ~2x faster on a dual-core.
* **Sensors:** locked RAPL rows no longer redraw every second.
* **Fixes:**
    * The process table could overflow the window by ~60 px after its column widths locked.
    * `build.sh` reported success when compilation failed, keeping the old binary.

## 0.100 — first release

zentop is a native Linux system monitor in Vala + GTK3. It reads `/proc` and `/sys` directly and is styled like a railway timetable.

* **Processes:** List or tree view.
    * Sort by any column.
    * Search, plus All/My/Active filters.
    * Pause the table while you browse.
    * Load-band typesetting: idle values fade, hot values go bold.
    * Right-click menu:
        * Pin to Top
        * End / Kill / Stop / Continue
        * Priority
        * CPU Affinity
        * Open File Location
        * Highlight Color
        * Properties
* **Resources:**
    * **General Measurements:** CPU, per-core, memory, swap and network graphs.
    * **Power Consumption:** RAPL, hwmon power and energy, batteries and NVIDIA NVML.
    * **Temperatures:** every hwmon and thermal-zone sensor, with each driver's warning and critical thresholds.
* **Pie Graph:** the top 10 processes by CPU% + memory%.
* **File Systems:** a partition table plus a treemap or pie breakdown of any disk. Scan results are cached between runs.
* **Themes:** 6 themes, switched live: Default, EVA-01, MAGI, EVA-00, EVA-02 and Pastel Pink.
* **`install.sh`:** installs per user with an app-menu entry and no root. `--rapl` sets up RAPL access for your user.

### Install

Download `zentop-0.100-linux-x86_64.tar.gz`, then:

```bash
tar xzf zentop-0.100-linux-x86_64.tar.gz
cd zentop-0.100-linux-x86_64
bash install.sh
```

Runtime dependencies (usually already present on a GTK desktop):
* Debian/Ubuntu/Mint: `libgtk-3-0 libgee-0.8-2 libjson-glib-1.0-0 fontconfig`
* Arch/CachyOS: `gtk3 libgee json-glib fontconfig`
