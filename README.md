# zentop

A native Linux system monitor written in Vala + GTK3. It reads `/proc` and `/sys` directly, with no Python and no psutil.

## Look

zentop is typeset like a railway timetable:
* Every number uses tabular figures.
* Hairline rules separate the columns.
* A one-line header strip holds the wordmark, the tabs and live CPU/MEM figures.

Load is shown through type:
* Idle values fade back.
* Hot values turn bold in the theme's hot color.

The design system lives in `DESIGN.md`.

## Features

* **Processes:** List or tree view.
    * Sort by any column.
    * Search, plus All/My/Active filters.
    * Pause the table while you browse.
* **Resources:** three sub-pages.
    * **General Measurements:** history graphs for CPU, memory + swap and network, plus a per-core board.
    * **Power Consumption:** every power sensor the system exposes:
        * RAPL (CPU package, cores, iGPU, DRAM, platform)
        * hwmon power and energy (amdgpu, zenpower, zenergy, i915/xe)
        * batteries
        * NVIDIA GPUs through NVML
    * **Temperatures:** every hwmon and thermal-zone sensor, grouped by device (CPU, GPU, NVMe, chipset, Wi-Fi…).
        * Each sensor shows its min, peak and the driver's own warning and critical thresholds.
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

## Build and run

```bash
sudo apt install valac libgtk-3-dev libgee-0.8-dev libjson-glib-dev libfontconfig-dev
bash build.sh
./zentop
```

On Arch or CachyOS, install `vala gtk3 libgee json-glib fontconfig` instead.

To install zentop for your user, with an app-menu entry and no root needed:

```bash
bash install.sh
```

To remove it again, run `bash install.sh --uninstall`.

### RAPL power readings (CPU package, cores, DRAM)

Since 2020, the kernel lets only root read the RAPL energy counters. This was a fix for the PLATYPUS power side-channel. To let your user read them, without running zentop as root, run this once:

```bash
bash install.sh --rapl
```

It asks for sudo once. It does three things:
* creates a `rapl` group;
* adds you to it;
* installs a udev rule (`/etc/udev/rules.d/70-zentop-rapl.rules`) that makes the counters readable by that group at every boot.

Log out and back in once, and the counters show up in Power Consumption. To undo it, run `bash install.sh --remove-rapl`.

## Performance

Measured over 60 s with about 370 processes running:

| Tab | CPU (of one core) | RAM |
|---|---|---|
| Processes | ~0.7–0.9% | 39 MB |
| Resources | 0.13% | 40 MB |
| Power Consumption / Temperatures | 0.26% / 0.16% | 40 MB |
| Minimised | 0% | 39 MB |

* **Kept-open files:** `/proc` and `/sys` files stay open and are re-read with `pread`. That is about 3x cheaper than reopening them, and they are parsed in place.
* **Visible tab only:** only the visible tab or sub-page does any work, and tabs are built the first time you open them.
* **Minimised:** nothing runs while the window is minimised, not even a timer.
* **Table updates:** tables only redraw rows whose text changed.

## Layout

```text
zentop/
├── src/            Vala sources, one file per tab plus the /proc and /sys readers
├── themes/         one CSS file per theme
├── fonts/          Inter (SIL OFL); get-fonts.sh downloads it if missing
├── build.sh        compiles ./zentop
└── install.sh      per-user install and menu entry
```

Settings live in `~/.config/system-monitor-pp/`.
