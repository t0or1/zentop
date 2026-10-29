#!/usr/bin/env python3
"""
zentop
Native GTK3 system monitor.

Performance notes:
  - Process data gathering (ProcessCache.refresh) runs on a persistent
    single-worker ThreadPoolExecutor, never touching GTK. Results are
    handed back to the main thread via GLib.idle_add.
  - Only the currently visible tab is polled. Switching tabs triggers an
    immediate refresh of that tab and the other two go quiet.
  - The flat-view GTK store is updated in place (existing rows updated,
    new rows appended, dead rows removed) and reordered with
    ListStore.reorder() instead of being torn down and rebuilt.
  - Row highlighting uses TreeViewColumn.add_attribute() bound to hidden
    background/foreground store columns computed once per row — no
    per-cell Python callback.
  - Per-process fields that never change after start (name, ppid,
    create_time) are cached the first time a PID is seen, not re-read
    every tick.
"""

import os
import time
import json
import math
import pwd
import getpass
import subprocess
import threading
import ctypes
import ctypes.util
from concurrent.futures import ThreadPoolExecutor
from collections import deque
from datetime import datetime

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib, Gdk, Pango

import psutil

APP_DIR = os.path.dirname(os.path.abspath(__file__))
FONTS_DIR = os.path.join(APP_DIR, "fonts")
CONFIG_DIR = os.path.expanduser("~/.config/system-monitor-pp")
CONFIG_PATH = os.path.join(CONFIG_DIR, "process_config.json")
APP_CONFIG_PATH = os.path.join(CONFIG_DIR, "app_config.json")
THEMES_DIR = os.path.join(APP_DIR, "themes")

THEMES = [
    {
        "id": "default",
        "name": "DEFAULT — GitHub Dark",
        "desc": "background #0D1117, violet accents.",
        "colors": ["#0D1117", "#8B5CF6", "#161B22"],
    },
    {
        "id": "eva01",
        "name": "EVA-01",
        "desc": "Deep Violet, Light green, Red.",
        "colors": ["#0F0A1F", "#7B2FD9", "#8CFF6B"],
    },
    {
        "id": "magi",
        "name": "MAGI",
        "desc": "Black Monochromatic terminal, amber CRT.",
        "colors": ["#060606", "#FFB000", "#FFCC66"],
    },
    {
        "id": "eva00",
        "name": "EVA-00",
        "desc": "Pale Blue / White, Orange Stripes.",
        "colors": ["#0A1420", "#FF8C1A", "#7FD4F0"],
    },
    {
        "id": "eva02",
        "name": "EVA-02",
        "desc": "Red/Orange, Made in Germany, cream.",
        "colors": ["#150808", "#E8412C", "#F4C95D"],
    },
    {
        "id": "pastel",
        "name": "PASTEL PINK",
        "desc": "Pale pink background, fuchsia and lavender tones.",
        "colors": ["#FDF0F5", "#E85CA6", "#C9A0DC"],
    },
]

PROCESS_REFRESH_MS = 2000
RESOURCES_REFRESH_MS = 1000
FS_REFRESH_MS = 5000
HISTORY_LEN = 60  # ~1 minute at 1s ticks
IO_COUNTERS_EVERY_N_TICKS = 3  # disk I/O columns refresh every ~6s instead of every 2s
PIN_ICONS = ("view-pin-symbolic", "starred-symbolic")  # first one the icon theme has wins

# Load bands: the signature of the table. Numbers are typeset by how much
# they matter -- idle values go dim, hot ones go bold in the theme's hot
# colour -- so the busy processes stand out without any chart.
CPU_IDLE_BELOW = 0.5   # % of one core
CPU_HOT_FROM = 20.0
MEM_IDLE_BELOW = 0.5   # % of total RAM
MEM_HOT_FROM = 5.0
WEIGHT_NORMAL = 400
WEIGHT_SEMIBOLD = 600
WEIGHT_BOLD = 700

# Colour roles each theme CSS defines as `.zt-c-<role> { color: ... }`.
# They're read once per theme change and handed to Cairo / the tree store.
COLOR_ROLES = ("ink", "idle", "hot", "bg", "g-bg", "g-grid", "g-cpu", "g-mem",
               "g-swap", "g-rx", "g-tx") + tuple(f"s{i}" for i in range(8))

PIE_TOP_N = 10  # individual wedges; everything past this gets grouped into "Others"
FS_SCAN_TOP_N = 20  # same idea, for the disk-usage treemap/pie
# Pre-built once instead of inside hot loops: except-clause tuples get
# rebuilt by Python every time they're evaluated, and dict.get()'s default
# argument is evaluated eagerly even when unused — both add up when done
# ~300 times per tick.
_EMPTY_DICT = {}
_PROC_LOOKUP_ERRORS = (psutil.NoSuchProcess, psutil.ZombieProcess, psutil.AccessDenied)
_IO_ERRORS = (psutil.AccessDenied, psutil.Error, AttributeError)
_CPUNUM_ERRORS = (AttributeError, psutil.Error)
_ACTIVE_STATUSES = (psutil.STATUS_RUNNING, psutil.STATUS_SLEEPING)

# ------------------------------------------------------------- FORMATTING

def format_bytes(n):
    if n is None:
        return "-"
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024.0:
            return f"{n:.1f}{unit}"
        n /= 1024.0
    return f"{n:.1f}PB"

def format_rate(n):
    return f"{format_bytes(n)}/s" if n is not None else "-"

def format_duration(seconds):
    seconds = int(seconds or 0)
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"

def format_started(epoch, now):
    if not epoch:
        return "-"
    dt = datetime.fromtimestamp(epoch)
    return dt.strftime("%H:%M:%S") if dt.date() == now.date() else dt.strftime("%b %d")

def safe_call(fn, default="-"):
    try:
        return fn()
    except (psutil.AccessDenied, psutil.Error, FileNotFoundError, OSError):
        return default

def register_app_fonts():
    """Make the bundled fonts/ folder visible to Pango through fontconfig,
    for this process only (nothing is installed system-wide). Runs once,
    before the first widget exists. If anything fails the themes fall back
    to the system sans."""
    if not os.path.isdir(FONTS_DIR):
        return
    try:
        fc = ctypes.CDLL(ctypes.util.find_library("fontconfig") or "libfontconfig.so.1")
        fc.FcConfigAppFontAddDir.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        fc.FcConfigAppFontAddDir(None, FONTS_DIR.encode())
    except (OSError, AttributeError):
        pass

def rgb_to_hex(rgb):
    r, g, b = rgb
    return "#{:02X}{:02X}{:02X}".format(round(r * 255), round(g * 255), round(b * 255))

def readable_on(rgb, dark, light=(1.0, 1.0, 1.0)):
    """Pick whichever of `dark` / `light` reads better on top of `rgb`."""
    lum = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
    return dark if lum > 0.5 else light

def tabular_attrs():
    """Pango attributes for tabular (fixed-width) figures, so numbers line
    up column by column. Built once per renderer, never per row."""
    attrs = Pango.AttrList()
    attrs.insert(Pango.attr_font_features_new("tnum 1"))
    return attrs

# --------------------------------------------------------- DISK USAGE SCAN

def _dir_size(path, root_dev, cancel_event):
    """Recursive size of everything under `path`, WITHOUT crossing onto a
    different mounted filesystem (checks st_dev, same idea as `du -x` /
    `find -xdev` — this is what keeps a scan of "/" from wandering into
    /proc, /sys, or a separately-mounted /home). Symlinks are skipped
    entirely to avoid loops and double-counting."""
    total = 0
    try:
        with os.scandir(path) as it:
            for entry in it:
                if cancel_event.is_set():
                    return total
                if entry.is_symlink():
                    continue
                try:
                    st = entry.stat(follow_symlinks=False)
                except (OSError, PermissionError):
                    continue
                if st.st_dev != root_dev:
                    continue
                if entry.is_dir(follow_symlinks=False):
                    total += _dir_size(entry.path, root_dev, cancel_event)
                else:
                    total += st.st_size
    except (OSError, PermissionError):
        pass
    return total

def scan_disk_usage(mountpoint, cancel_event):
    """One level deep under `mountpoint`: (name, size_bytes, is_dir) for
    each direct child, sizes computed recursively but never crossing a
    filesystem boundary. Runs entirely off the GTK thread."""
    try:
        root_dev = os.stat(mountpoint).st_dev
    except OSError:
        return None
    entries = []
    try:
        with os.scandir(mountpoint) as it:
            for entry in it:
                if cancel_event.is_set():
                    break
                if entry.is_symlink():
                    continue
                try:
                    st = entry.stat(follow_symlinks=False)
                except (OSError, PermissionError):
                    continue
                if st.st_dev != root_dev:
                    continue
                is_dir = entry.is_dir(follow_symlinks=False)
                size = _dir_size(entry.path, root_dev, cancel_event) if is_dir else st.st_size
                if size > 0:
                    entries.append((entry.name, size, is_dir))
    except (OSError, PermissionError):
        pass
    return entries

# ------------------------------------------------------- SQUARIFIED TREEMAP
# Standard "squarified treemap" layout (Bruls, Huizing, van Wijk 1999) —
# lays out rectangles sized proportional to their value while keeping
# aspect ratios close to square, which is what makes a treemap actually
# readable instead of a strip of skinny slivers.

def _normalize_sizes(sizes, dx, dy):
    total = sum(sizes)
    area = dx * dy
    if total <= 0 or area <= 0:
        return [0.0 for _ in sizes]
    return [s * area / total for s in sizes]

def _treemap_layout_row(sizes, x, y, dx, dy):
    covered = sum(sizes)
    width = covered / dy if dy > 0 else 0
    rects, cx = [], x
    for s in sizes:
        h = s / width if width > 0 else 0
        rects.append((cx, y, width, h))
        cx += width
    return rects

def _treemap_layout_col(sizes, x, y, dx, dy):
    covered = sum(sizes)
    height = covered / dx if dx > 0 else 0
    rects, cy = [], y
    for s in sizes:
        w = s / height if height > 0 else 0
        rects.append((x, cy, w, height))
        cy += height
    return rects

def _treemap_layout(sizes, x, y, dx, dy):
    return _treemap_layout_row(sizes, x, y, dx, dy) if dx >= dy else _treemap_layout_col(sizes, x, y, dx, dy)

def _treemap_leftover(sizes, x, y, dx, dy):
    covered = sum(sizes)
    if dx >= dy:
        width = covered / dy if dy > 0 else 0
        return (x + width, y, dx - width, dy)
    height = covered / dx if dx > 0 else 0
    return (x, y + height, dx, dy - height)

def _treemap_worst_ratio(sizes, x, y, dx, dy):
    rects = _treemap_layout(sizes, x, y, dx, dy)
    worst = 0.0
    for _, _, w, h in rects:
        if w <= 0 or h <= 0:
            return float("inf")
        worst = max(worst, w / h if w > h else h / w)
    return worst

def squarify_treemap(sizes, x, y, dx, dy):
    """sizes: values already normalized so sum(sizes) == dx*dy (call
    _normalize_sizes first). Returns [(x, y, w, h), ...] in the same
    order as `sizes`."""
    sizes = [s for s in sizes if s > 0]
    if not sizes:
        return []
    if len(sizes) == 1:
        return _treemap_layout(sizes, x, y, dx, dy)
    i = 1
    while i < len(sizes) and _treemap_worst_ratio(sizes[:i + 1], x, y, dx, dy) <= _treemap_worst_ratio(sizes[:i], x, y, dx, dy):
        i += 1
    current, remaining = sizes[:i], sizes[i:]
    rects = _treemap_layout(current, x, y, dx, dy)
    lx, ly, ldx, ldy = _treemap_leftover(current, x, y, dx, dy)
    rects.extend(squarify_treemap(remaining, lx, ly, ldx, ldy))
    return rects

# --------------------------------------------------------------- CONFIG

def load_config():
    try:
        with open(CONFIG_PATH, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def save_config(data):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(CONFIG_PATH, "w") as f:
        json.dump(data, f, indent=2)

def load_app_config():
    try:
        with open(APP_CONFIG_PATH, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def save_app_config(data):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(APP_CONFIG_PATH, "w") as f:
        json.dump(data, f, indent=2)

# ------------------------------------------------------------- DATA LAYER

class ProcessCache:
    """Keeps psutil.Process objects alive across refreshes so cpu_percent()
    and IO deltas are computed correctly instead of resetting every tick.

    Runs entirely off the GTK main thread — must never touch Gtk/Gdk.
    """

    def __init__(self):
        self.processes = {}
        self.prev_io = {}
        self.uid_cache = {}          # uid -> username, resolved once, forever
        self.last_io_values = {}     # pid -> (read_total, write_total, read_rate, write_rate)
        self.static_cache = {}       # pid -> {"name", "ppid", "create_time"} — fetched once
        self.tick = 0

    def _resolve_username(self, uid):
        cached = self.uid_cache.get(uid)
        if cached is not None:
            return cached
        try:
            name = pwd.getpwuid(uid).pw_name
        except (KeyError, OSError):
            name = str(uid)
        self.uid_cache[uid] = name
        return name

    def refresh(self):
        self.tick += 1
        fetch_io = (self.tick % IO_COUNTERS_EVERY_N_TICKS == 0)
        # Local names avoid repeated attribute lookups across ~300 iterations.
        processes = self.processes
        static_cache = self.static_cache
        prev_io = self.prev_io
        last_io_values = self.last_io_values
        resolve_username = self._resolve_username
        rows = []
        now = time.time()
        seen_pids = set()
        for p in psutil.process_iter(["pid"]):
            pid = p.info["pid"]
            seen_pids.add(pid)
            proc = processes.get(pid)
            if proc is None:
                try:
                    proc = psutil.Process(pid)
                    processes[pid] = proc
                    static_cache[pid] = {
                        "name": safe_call(proc.name, "?"),
                        "ppid": safe_call(proc.ppid, 0),
                        "create_time": safe_call(proc.create_time, 0),
                    }
                    # No separate "priming" cpu_percent() call needed — the
                    # first-ever call on a Process object always returns a
                    # meaningless 0.0 by design, whether it happens here or
                    # inside the oneshot block below. Priming was a second,
                    # fully redundant /proc read for every newly-seen pid.
                except psutil.NoSuchProcess:
                    continue
            static = static_cache.get(pid, _EMPTY_DICT)
            try:
                with proc.oneshot():
                    name = static.get("name") or proc.name()
                    ppid = static.get("ppid", proc.ppid())
                    create_time = static.get("create_time") or proc.create_time()
                    uid = proc.uids().real
                    cpu = proc.cpu_percent(None)
                    nice = proc.nice()
                    mem = proc.memory_info().rss
                    status = proc.status()
                    times = proc.cpu_times()
                    cputime = times.user + times.system
                    try:
                        cpuid = proc.cpu_num()
                    except _CPUNUM_ERRORS:
                        cpuid = -1
                user = resolve_username(uid)
                if fetch_io:
                    try:
                        io = proc.io_counters()
                        read_total, write_total = io.read_bytes, io.write_bytes
                    except _IO_ERRORS:
                        read_total = write_total = None
                    if read_total is not None:
                        prev = prev_io.get(pid)
                        if prev is not None:
                            dt = now - prev[2]
                            read_rate = (read_total - prev[0]) / dt if dt > 0 else 0
                            write_rate = (write_total - prev[1]) / dt if dt > 0 else 0
                        else:
                            read_rate = write_rate = 0
                        prev_io[pid] = (read_total, write_total, now)
                    else:
                        read_rate = write_rate = None
                    last_io_values[pid] = (read_total, write_total, read_rate, write_rate)
                else:
                    cached_io = last_io_values.get(pid)
                    if cached_io is not None:
                        read_total, write_total, read_rate, write_rate = cached_io
                    else:
                        read_total = write_total = read_rate = write_rate = None
                rows.append({
                    "pid": pid, "ppid": ppid, "name": name, "user": user,
                    "cpu": cpu, "cpuid": cpuid, "mem": mem,
                    "read_total": read_total, "write_total": write_total,
                    "read_rate": read_rate, "write_rate": write_rate,
                    "priority": nice, "status": status,
                    "create_time": create_time, "cputime": cputime,
                })
            except _PROC_LOOKUP_ERRORS:
                continue
        stale = processes.keys() - seen_pids
        for pid in stale:
            processes.pop(pid, None)
            prev_io.pop(pid, None)
            last_io_values.pop(pid, None)
            static_cache.pop(pid, None)
        return rows

# ------------------------------------------------------------- HISTORY GRAPH

class HistoryGraph(Gtk.DrawingArea):
    """Scrolling filled line-chart. Colours come from the active theme via
    the shared `theme` dict (role -> (r,g,b)), so switching theme only
    needs a redraw, not a rebuild."""

    def __init__(self, theme, series, y_max=100.0, auto_scale=False, height=120):
        super().__init__()
        self.theme = theme
        self.series = series  # list of {"role": "g-cpu", "data": deque}
        self.y_max = y_max
        self.auto_scale = auto_scale
        self.set_size_request(-1, height)
        self.connect("draw", self._on_draw)

    def push(self, values):
        for s, v in zip(self.series, values):
            s["data"].append(v)
        self.queue_draw()

    def _on_draw(self, widget, cr):
        theme = self.theme
        w = widget.get_allocated_width()
        h = widget.get_allocated_height()
        cr.set_source_rgb(*theme["g-bg"])
        cr.paint()
        # timetable rules: three hairlines on whole pixels so they stay crisp
        cr.set_source_rgb(*theme["g-grid"])
        cr.set_line_width(1)
        for i in range(1, 4):
            y = int(h * i / 4) + 0.5
            cr.move_to(0, y)
            cr.line_to(w, y)
        cr.stroke()
        if self.auto_scale:
            y_max = max((v for s in self.series for v in s["data"]), default=0)
            y_max = max(y_max * 1.25, 1)
        else:
            y_max = self.y_max
        for s in self.series:
            data = s["data"]  # deque supports len() and repeated iteration
            n = len(data)
            if n < 2:
                continue
            step = w / (HISTORY_LEN - 1)
            x0 = w - (n - 1) * step  # newest sample pinned to the right edge
            r, g, b = theme[s["role"]]
            scale = h / y_max
            pts = [(x0 + i * step, h - min(v, y_max) * scale) for i, v in enumerate(data)]
            cr.move_to(pts[0][0], h)
            for x, y in pts:
                cr.line_to(x, y)
            cr.line_to(pts[-1][0], h)
            cr.close_path()
            cr.set_source_rgba(r, g, b, 0.16)
            cr.fill()
            cr.move_to(*pts[0])
            for x, y in pts[1:]:
                cr.line_to(x, y)
            cr.set_source_rgb(r, g, b)
            cr.set_line_width(1.5)
            cr.stroke()
        return False

class ColorChip(Gtk.DrawingArea):
    """A small colour swatch. Drawn with Cairo instead of a per-chip
    CssProvider: changing its colour is a redraw, not a stylesheet parse."""

    def __init__(self, rgb=(0, 0, 0), size=12, outline=None):
        super().__init__()
        self.rgb = rgb
        self.outline = outline  # theme dict: hairline in its ink, for swatches that may match the ground
        self.set_size_request(size, size)
        self.set_valign(Gtk.Align.CENTER)
        self.connect("draw", self._on_draw)

    def set_rgb(self, rgb):
        if rgb != self.rgb:
            self.rgb = rgb
            self.queue_draw()

    def _on_draw(self, widget, cr):
        cr.set_source_rgb(*self.rgb)
        w, h = widget.get_allocated_width(), widget.get_allocated_height()
        cr.rectangle(0, 0, w, h)
        cr.fill()
        if self.outline:
            cr.set_source_rgba(*self.outline["ink"], 0.35)
            cr.set_line_width(1)
            cr.rectangle(0.5, 0.5, w - 1, h - 1)
            cr.stroke()
        return False

# ------------------------------------------------------------- PIE GRAPH

class PieGraph(Gtk.DrawingArea):
    """Wedge per process, sized by an 'overall' consumption score. The
    legend (names + percentages) is built as normal GTK widgets by the
    window, not drawn here — text layout in raw Cairo is a pain to keep
    legible, GTK labels already handle it for free."""

    def __init__(self, theme):
        super().__init__()
        self.theme = theme
        self.slices = []  # list of (label, value), already sorted
        self.set_size_request(-1, 320)
        self.connect("draw", self._on_draw)

    def set_data(self, slices):
        self.slices = slices
        self.queue_draw()

    def _on_draw(self, widget, cr):
        w = widget.get_allocated_width()
        h = widget.get_allocated_height()
        cx, cy = w / 2, h / 2
        radius = max(min(w, h) / 2 - 12, 1)
        total = sum(v for _, v in self.slices)
        if total <= 0:
            return False
        start_angle = -math.pi / 2  # 12 o'clock
        for i, (_, value) in enumerate(self.slices):
            end_angle = start_angle + (value / total) * 2 * math.pi
            cr.set_source_rgb(*self.theme[f"s{i % 8}"])
            cr.move_to(cx, cy)
            cr.arc(cx, cy, radius, start_angle, end_angle)
            cr.close_path()
            cr.fill()
            start_angle = end_angle
        # hollow centre + 1px gaps between wedges in the ground colour:
        # reads as a ring of figures instead of a candy pie
        cr.set_source_rgb(*self.theme["bg"])
        cr.set_line_width(2)
        start_angle = -math.pi / 2
        for _, value in (self.slices if len(self.slices) > 1 else ()):
            cr.move_to(cx, cy)
            cr.line_to(cx + radius * math.cos(start_angle), cy + radius * math.sin(start_angle))
            start_angle += (value / total) * 2 * math.pi
        cr.stroke()
        cr.arc(cx, cy, radius * 0.58, 0, 2 * math.pi)
        cr.fill()
        return False

# ---------------------------------------------------------- TREEMAP GRAPH

class TreemapGraph(Gtk.DrawingArea):
    """WizTree-style treemap: one rectangle per entry, sized proportional
    to disk usage via the squarified layout above. Labels are drawn
    inside a tile only if it's big enough to hold them legibly."""

    def __init__(self, theme):
        super().__init__()
        self.theme = theme
        self.entries = []  # list of (name, size, is_dir)
        self.set_size_request(-1, 380)
        self.connect("draw", self._on_draw)

    def set_data(self, entries):
        self.entries = entries
        self.queue_draw()

    def _on_draw(self, widget, cr):
        w = widget.get_allocated_width()
        h = widget.get_allocated_height()
        theme = self.theme
        cr.set_source_rgb(*theme["g-bg"])
        cr.paint()
        if not self.entries or w <= 0 or h <= 0:
            return False
        sizes = [e[1] for e in self.entries]
        normalized = _normalize_sizes(sizes, w, h)
        rects = squarify_treemap(normalized, 0, 0, w, h)
        cr.select_font_face("Inter", 0, 0)
        dark = theme["bg"]
        for i, ((name, size, is_dir), rect) in enumerate(zip(self.entries, rects)):
            rx, ry, rw, rh = rect
            tile = theme[f"s{i % 8}"]
            if not is_dir:  # loose files read one step quieter than folders
                gb = theme["g-bg"]
                tile = tuple(c * 0.7 + g * 0.3 for c, g in zip(tile, gb))
            cr.set_source_rgb(*tile)
            # 1px ground-colour gutter between tiles instead of a stroked border
            cr.rectangle(rx + 0.5, ry + 0.5, max(rw - 1, 0), max(rh - 1, 0))
            cr.fill()
            if rw > 42 and rh > 20:
                ink = readable_on(tile, dark)
                cr.save()
                cr.rectangle(rx, ry, rw, rh)
                cr.clip()
                cr.set_source_rgb(*ink)
                cr.set_font_size(12)
                cr.move_to(rx + 6, ry + 16)
                cr.show_text(self._truncate(cr, name, rw - 12))
                if rh > 38:
                    cr.set_source_rgba(ink[0], ink[1], ink[2], 0.78)
                    cr.move_to(rx + 6, ry + 31)
                    cr.show_text(format_bytes(size))
                cr.restore()
        return False

    def _truncate(self, cr, text, max_width):
        if cr.text_extents(text)[2] <= max_width:
            return text
        while text and cr.text_extents(text + "…")[2] > max_width:
            text = text[:-1]
        return text + "…" if text else ""

# ------------------------------------------------------------- MAIN WINDOW

class SystemMonitorWindow(Gtk.Window):
    COLUMNS = [
        ("PROCESS", 1), ("USER", 2), ("CPU", 3), ("CPUID", 4), ("MEMORY", 5),
        ("DISKREADTOTAL", 6), ("DISKWRITETOTAL", 7), ("DISKREAD", 8),
        ("DISKWRITE", 9), ("PRIORITY", 10), ("STATUS", 11), ("STARTED", 12),
        ("CPU TIME", 13),
    ]
    # 0=pid(int), 1-13=display strings, 14=background hex, 15=foreground hex,
    # 16=pin icon name, then the load-band columns: per-cell foreground and
    # weight, computed once per row when data arrives (no cell_data_func).
    BG_COL = 14
    FG_COL = 15
    PIN_COL = 16
    CPU_FG_COL = 17
    CPU_WT_COL = 18
    MEM_FG_COL = 19
    MEM_WT_COL = 20
    RD_FG_COL = 21
    WR_FG_COL = 22
    NAME_WT_COL = 23
    STORE_SCHEMA = (int, *([str] * 16), str, int, str, int, str, str, int)
    # column index -> (foreground column, weight column or None)
    BAND_BINDINGS = {3: (17, 18), 5: (19, 20), 8: (21, None), 9: (22, None), 1: (15, 23)}
    SORT_KEYS = {
        1: lambda r: (r["name"] or "").lower(),
        2: lambda r: (r["user"] or "").lower(),
        3: lambda r: r["cpu"],
        4: lambda r: r["cpuid"] if r["cpuid"] is not None else -1,
        5: lambda r: r["mem"] or 0,
        6: lambda r: r["read_total"] or 0,
        7: lambda r: r["write_total"] or 0,
        8: lambda r: r["read_rate"] or 0,
        9: lambda r: r["write_rate"] or 0,
        10: lambda r: r["priority"],
        11: lambda r: r["status"] or "",
        12: lambda r: r["create_time"] or 0,
        13: lambda r: r["cputime"] or 0,
    }
    PRIORITY_PRESETS = [
        ("Very High (-20)", -20), ("High (-10)", -10), ("Normal (0)", 0),
        ("Low (10)", 10), ("Very Low (19)", 19),
    ]

    def __init__(self):
        super().__init__(title="zentop")
        self.set_default_size(1440, 900)
        self.process_cache = ProcessCache()
        self.current_user = getpass.getuser()
        self.process_filter_mode = "all"
        self.tree_mode = False
        self.search_text = ""
        self.prev_net = None
        self.sort_column = 3       # CPU
        self.sort_reverse = True   # highest first
        self.process_config = load_config()  # {process_name: {"highlight_color", "pinned"}}
        self.app_config = load_app_config()  # {"theme": "default" | "evangelion"}
        self.current_theme = self.app_config.get("theme", "default")
        self._process_refresh_in_flight = False
        self.active_tab = "processes"
        self.processes_paused = False
        self._contrast_cache = {}  # hex color -> "#000000"/"#FFFFFF", never changes per color
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="proc-gather")
        self.fs_scan_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="fs-scan")
        self.fs_scan_in_progress = False
        self.fs_scan_cancel_event = None
        self.total_mem = psutil.virtual_memory().total or 1
        # Active theme colours, role -> (r,g,b). Mutated in place on theme
        # change so every graph holding a reference sees the new values.
        self.theme = {role: (0.5, 0.5, 0.5) for role in COLOR_ROLES}
        self.theme_hex = {}
        self.pin_icon = next((n for n in PIN_ICONS if Gtk.IconTheme.get_default().has_icon(n)), None)
        self._hdr_hot = False
        self._last_count = -1
        self._last_pie_rows = []
        self._last_fs_entries = []
        self._load_css()
        self._build_ui()
        self._read_theme_colors()
        for chip, i in self._legend_chips:  # built before the colours were read
            chip.set_rgb(self.theme[f"s{i % 8}"])
        self.connect("style-updated", self._on_style_updated)
        self.connect("destroy", self._on_destroy)
        GLib.timeout_add(PROCESS_REFRESH_MS, self._refresh_processes)
        GLib.timeout_add(PROCESS_REFRESH_MS, self._refresh_header)
        GLib.timeout_add(RESOURCES_REFRESH_MS, self._refresh_resources)
        GLib.timeout_add(FS_REFRESH_MS, self._refresh_filesystems)
        self._refresh_header()
        self._on_active_tab_changed(self.stack, None)  # populate whichever tab is shown first

    def _on_destroy(self, *args):
        if self.fs_scan_cancel_event:
            self.fs_scan_cancel_event.set()
        self._executor.shutdown(wait=False)
        self.fs_scan_executor.shutdown(wait=False)

    def _load_css(self):
        self._css_provider = Gtk.CssProvider()
        path = os.path.join(THEMES_DIR, f"{self.current_theme}.css")
        if not os.path.exists(path):
            path = os.path.join(THEMES_DIR, "default.css")
            self.current_theme = "default"
        self._css_provider.load_from_path(path)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), self._css_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

    def _apply_theme(self, theme_id):
        path = os.path.join(THEMES_DIR, f"{theme_id}.css")
        if not os.path.exists(path):
            self._show_error(f"Could not find theme file: {path}")
            return
        # Reloading content on the SAME provider (already registered on the
        # screen) is enough — GTK re-applies styles to every widget live,
        # no need to remove/re-add providers or restart the app.
        self._css_provider.load_from_path(path)
        self.current_theme = theme_id
        self.app_config["theme"] = theme_id
        save_app_config(self.app_config)

    # -- theme colour roles

    def _read_theme_colors(self):
        """Read every `.zt-c-<role>` colour from the loaded CSS. Returns True
        when something changed. Cost: ~20 style lookups, only on theme or
        window-state changes -- never per tick."""
        ctx = self.get_style_context()
        changed = False
        for role in COLOR_ROLES:
            ctx.save()
            ctx.add_class("zt-c-" + role)
            c = ctx.get_color(Gtk.StateFlags.NORMAL)
            ctx.restore()
            rgb = (c.red, c.green, c.blue)
            if self.theme.get(role) != rgb:
                self.theme[role] = rgb
                changed = True
        if changed:
            self.theme_hex = {role: rgb_to_hex(rgb) for role, rgb in self.theme.items()}
        return changed

    def _on_style_updated(self, widget):
        # Also fires on focus in/out (backdrop state); bail out unless the
        # colours really changed, so that stays free.
        if not self._read_theme_colors():
            return
        self._flat_pid_values.clear()  # band colours changed: rewrite rows on next tick
        for chip, i in getattr(self, "_legend_chips", ()):
            chip.set_rgb(self.theme[f"s{i % 8}"])
        for g in (self.cpu_history, self.mem_history, self.net_history,
                  self.pie_graph, self.fs_pie_graph, self.fs_treemap):
            g.queue_draw()
        if self.active_tab == "processes" and not self.processes_paused:
            self._refresh_processes()

    # -- layout

    def _build_ui(self):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        root.get_style_context().add_class("root-bg")
        self.add(root)
        # One-line header strip: wordmark, tabs, live figures. Replaces the
        # old centred title + pill row and gives the tables ~100px back.
        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
        header.get_style_context().add_class("zt-header")
        title = Gtk.Label(label="ZENTOP")
        title.get_style_context().add_class("title-label")
        title.set_margin_end(28)
        header.pack_start(title, False, False, 0)
        self.stack = Gtk.Stack()
        # no crossfade: an instant switch costs zero animation frames
        self.stack.set_transition_type(Gtk.StackTransitionType.NONE)
        switcher = Gtk.StackSwitcher()
        switcher.set_stack(self.stack)
        switcher.set_halign(Gtk.Align.START)
        switcher.get_style_context().add_class("pill-switcher")
        header.pack_start(switcher, False, False, 0)
        self.hdr_mem = self._header_stat(header, "MEM")
        self.hdr_cpu = self._header_stat(header, "CPU")
        root.pack_start(header, False, False, 0)
        self.stack.add_titled(self._build_processes_tab(), "processes", "PROCESSES")
        self.stack.add_titled(self._build_resources_tab(), "resources", "RESOURCES")
        self.stack.add_titled(self._build_piegraph_tab(), "piegraph", "PIE GRAPH")
        self.stack.add_titled(self._build_filesystems_tab(), "filesystems", "FILE SYSTEMS")
        self.stack.add_titled(self._build_themes_tab(), "themes", "THEMES")
        switcher.set_homogeneous(False)  # after the pages exist: tabs as wide as their words
        self.stack.set_visible_child_name("processes")
        self.stack.connect("notify::visible-child-name", self._on_active_tab_changed)
        root.pack_start(self.stack, True, True, 0)

    def _on_active_tab_changed(self, stack, param):
        self.active_tab = stack.get_visible_child_name()
        # refresh immediately on switch so the tab isn't showing stale data
        if self.active_tab in ("processes", "piegraph"):
            self._refresh_processes()
        elif self.active_tab == "resources":
            self._refresh_resources()
        elif self.active_tab == "filesystems":
            self._refresh_filesystems()

    def _header_stat(self, header, key):
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        box.set_margin_start(20)
        k = Gtk.Label(label=key)
        k.get_style_context().add_class("zt-stat-key")
        v = Gtk.Label(label="-")
        v.get_style_context().add_class("zt-stat-value")
        box.pack_start(k, False, False, 0)
        box.pack_start(v, False, False, 0)
        header.pack_end(box, False, False, 0)
        return v

    def _refresh_header(self):
        """Always-visible figures. Two tiny reads (/proc/stat, /proc/meminfo)
        every 2s regardless of tab; labels are only touched when they change."""
        cpu = psutil.cpu_percent(None)
        vm = psutil.virtual_memory()
        cpu_txt = f"{cpu:.0f}%"
        mem_txt = f"{format_bytes(vm.used)} / {format_bytes(vm.total)}"
        if self.hdr_cpu.get_text() != cpu_txt:
            self.hdr_cpu.set_text(cpu_txt)
        if self.hdr_mem.get_text() != mem_txt:
            self.hdr_mem.set_text(mem_txt)
        hot = cpu >= 80
        if hot != self._hdr_hot:
            self._hdr_hot = hot
            ctx = self.hdr_cpu.get_style_context()
            (ctx.add_class if hot else ctx.remove_class)("zt-hot")
        return True
    # ------------------------------------------------------------ PROCESSES

    def _build_processes_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        toolbar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        toolbar.set_margin_start(20)
        toolbar.set_margin_end(20)
        toolbar.set_margin_top(12)
        toolbar.set_margin_bottom(10)
        self.filter_combo = Gtk.ComboBoxText()
        self.filter_combo.append("all", "All Processes")
        self.filter_combo.append("mine", "My Processes")
        self.filter_combo.append("active", "Active Processes")
        self.filter_combo.set_active_id("all")
        self.filter_combo.connect("changed", self._on_filter_changed)
        toolbar.pack_start(self.filter_combo, False, False, 0)
        self.tree_toggle = Gtk.ToggleButton(label="TREE VIEW")
        self.tree_toggle.get_style_context().add_class("tree-toggle")
        self.tree_toggle.connect("toggled", self._on_tree_toggled)
        toolbar.pack_start(self.tree_toggle, False, False, 0)
        self.search_entry = Gtk.SearchEntry()
        self.search_entry.set_placeholder_text("Filter by process name...")
        self.search_entry.get_style_context().add_class("search-entry")
        self.search_entry.connect("search-changed", self._on_search_changed)
        toolbar.pack_start(self.search_entry, True, True, 0)
        self.proc_count_label = Gtk.Label(label="")
        self.proc_count_label.get_style_context().add_class("zt-count")
        self.proc_count_label.set_margin_start(6)
        toolbar.pack_start(self.proc_count_label, False, False, 0)
        self.pause_toggle = Gtk.ToggleButton()
        self.pause_toggle.get_style_context().add_class("zt-icon-btn")
        self.pause_toggle.set_tooltip_text("Pause table updates")
        self.pause_icon = Gtk.Image.new_from_icon_name("media-playback-pause-symbolic", Gtk.IconSize.SMALL_TOOLBAR)
        self.pause_toggle.add(self.pause_icon)
        self.pause_toggle.connect("toggled", self._on_pause_toggled)
        toolbar.pack_start(self.pause_toggle, False, False, 0)
        box.pack_start(toolbar, False, False, 0)
        self.flat_store = Gtk.ListStore(*self.STORE_SCHEMA)
        self.tree_store = Gtk.TreeStore(*self.STORE_SCHEMA)
        self._flat_pid_iters = {}
        self._flat_pid_values = {}  # pid -> last-written row tuple, for change detection
        self.process_filter = self.flat_store.filter_new()
        self.process_filter.set_visible_func(self._filter_func)
        self.process_view = Gtk.TreeView(model=self.process_filter)
        self.process_view.get_style_context().add_class("data-table")
        self.process_view.connect("button-press-event", self._on_process_button_press)
        tnum = tabular_attrs()
        for title, idx in self.COLUMNS:
            col = Gtk.TreeViewColumn(title)
            renderer = Gtk.CellRendererText(xalign=0.0 if idx in (1, 2, 11) else 1.0)
            renderer.set_padding(8, 3)
            if idx not in (1, 2, 11):
                renderer.set_property("attributes", tnum)
            # PROCESS: the name takes only its own width so the pin sits right after it
            col.pack_start(renderer, idx != 1)
            col.add_attribute(renderer, "text", idx)
            col.add_attribute(renderer, "background", self.BG_COL)
            if idx == 1:  # PROCESS: pin icon after the name, so names stay on the header's edge
                pin = Gtk.CellRendererPixbuf()
                pin.set_padding(6, 0)
                pin.set_alignment(0.0, 0.5)
                col.pack_start(pin, True)
                # don't line cells up across rows, or every pin sits past the longest name
                for cell in (renderer, pin):
                    col.get_area().cell_set_property(cell, "align", False)
                    col.get_area().cell_set_property(cell, "fixed-size", False)
                col.add_attribute(pin, "icon-name", self.PIN_COL)
                col.add_attribute(pin, "cell-background", self.BG_COL)
            fg_col, wt_col = self.BAND_BINDINGS.get(idx, (self.FG_COL, None))
            col.add_attribute(renderer, "foreground", fg_col)
            if wt_col is not None:
                col.add_attribute(renderer, "weight", wt_col)
            col.set_resizable(True)
            col.set_expand(idx == 1)
            col.set_clickable(True)
            col.connect("clicked", self._on_column_clicked, idx)
            self.process_view.append_column(col)
        self._update_sort_indicators()
        scroller = Gtk.ScrolledWindow()
        scroller.set_vexpand(True)
        # 12px + the cells' 8px padding lines the first column up with the toolbar
        scroller.set_margin_start(12)
        scroller.set_margin_end(12)
        scroller.add(self.process_view)
        box.pack_start(scroller, True, True, 0)
        return box

    def _is_pinned(self, r):
        return r["pinned"]

    def _ordered_pids(self, pids, rows_by_pid, key_fn):
        """Pinned rows always go first. Partition once instead of sorting
        the full list twice — pins are rare, so this does a full sort on
        the (usually tiny) pinned group and one sort on the rest, instead
        of two full-size sorts."""
        pinned, unpinned = [], []
        for p in pids:
            (pinned if self._is_pinned(rows_by_pid[p]) else unpinned).append(p)
        pinned.sort(key=lambda p: key_fn(rows_by_pid[p]), reverse=self.sort_reverse)
        unpinned.sort(key=lambda p: key_fn(rows_by_pid[p]), reverse=self.sort_reverse)
        return pinned + unpinned

    def _row_tuple(self, r, now):
        color = r["highlight_color"]
        cpuid = r["cpuid"]
        cpu = r["cpu"]
        mem_pct = r["mem"] * 100.0 / self.total_mem
        if color:
            # highlighted row: one readable ink for every cell on its colour
            fg = self._contrast_color(color)
            cpu_fg = mem_fg = rd_fg = wr_fg = fg
        else:
            fg = None
            idle, hot = self.theme_hex["idle"], self.theme_hex["hot"]
            cpu_fg = idle if cpu < CPU_IDLE_BELOW else (hot if cpu >= CPU_HOT_FROM else None)
            mem_fg = idle if mem_pct < MEM_IDLE_BELOW else (hot if mem_pct >= MEM_HOT_FROM else None)
            rd_fg = None if r["read_rate"] else idle
            wr_fg = None if r["write_rate"] else idle
        return (
            r["pid"], r["name"], r["user"] or "-", f"{cpu:.1f}%",
            str(cpuid) if cpuid >= 0 else "-",
            format_bytes(r["mem"]), format_bytes(r["read_total"]), format_bytes(r["write_total"]),
            format_rate(r["read_rate"]), format_rate(r["write_rate"]),
            str(r["priority"]), r["status"], format_started(r["create_time"], now),
            format_duration(r["cputime"]), color if color else None, fg,
            self.pin_icon if r["pinned"] else None,
            cpu_fg, WEIGHT_BOLD if cpu >= CPU_HOT_FROM else WEIGHT_NORMAL,
            mem_fg, WEIGHT_BOLD if mem_pct >= MEM_HOT_FROM else WEIGHT_NORMAL,
            rd_fg, wr_fg,
            WEIGHT_SEMIBOLD if r["pinned"] else WEIGHT_NORMAL,
        )

    def _filter_func(self, model, it, data):
        if not self.search_text:
            return True
        name = (model[it][1] or "").lower()
        return self.search_text in name

    def _on_search_changed(self, entry):
        self.search_text = entry.get_text().strip().lower()
        self.process_filter.refilter()

    def _on_filter_changed(self, combo):
        self.process_filter_mode = combo.get_active_id() or "all"

    def _on_tree_toggled(self, button):
        self.tree_mode = button.get_active()
        self.search_entry.set_sensitive(not self.tree_mode)
        if self.tree_mode:
            self.search_entry.set_text("")
            self.search_text = ""
            self.process_filter = self.tree_store.filter_new()
        else:
            self.process_filter = self.flat_store.filter_new()
        self.process_filter.set_visible_func(self._filter_func)
        self.process_view.set_model(self.process_filter)
        self._refresh_processes()

    def _on_pause_toggled(self, button):
        self.processes_paused = button.get_active()
        if self.processes_paused:
            self.pause_icon.set_from_icon_name("media-playback-start-symbolic", Gtk.IconSize.SMALL_TOOLBAR)
            button.set_tooltip_text("Resume update")
        else:
            self.pause_icon.set_from_icon_name("media-playback-pause-symbolic", Gtk.IconSize.SMALL_TOOLBAR)
            button.set_tooltip_text("Stop process table update")
            self._refresh_processes()  # catch up immediately on resume
    # -- click-to-sort column headers

    def _on_column_clicked(self, column, idx):
        if self.sort_column == idx:
            self.sort_reverse = not self.sort_reverse
        else:
            self.sort_column = idx
            self.sort_reverse = True
        self._update_sort_indicators()
        self._refresh_processes()

    def _update_sort_indicators(self):
        for i, tv_col in enumerate(self.process_view.get_columns()):
            _, idx = self.COLUMNS[i]
            if idx == self.sort_column:
                tv_col.set_sort_indicator(True)
                tv_col.set_sort_order(Gtk.SortType.DESCENDING if self.sort_reverse else Gtk.SortType.ASCENDING)
            else:
                tv_col.set_sort_indicator(False)

    def _contrast_color(self, hex_color):
        cached = self._contrast_cache.get(hex_color)
        if cached is not None:
            return cached
        rgba = Gdk.RGBA()
        if not rgba.parse(hex_color):
            result = "#FFFFFF"
        else:
            luminance = 0.299 * rgba.red + 0.587 * rgba.green + 0.114 * rgba.blue
            result = "#000000" if luminance > 0.6 else "#FFFFFF"
        self._contrast_cache[hex_color] = result
        return result
    # -- background gather + main-thread apply

    def _refresh_processes(self):
        if self.active_tab not in ("processes", "piegraph"):
            return True
        if self.active_tab == "processes" and self.processes_paused:
            return True
        if self._process_refresh_in_flight:
            return True
        self._process_refresh_in_flight = True
        self._executor.submit(self._gather_processes_bg)
        return True

    def _gather_processes_bg(self):
        """Runs on the executor's worker thread. psutil-only, zero GTK."""
        rows = self.process_cache.refresh()
        if self.process_filter_mode == "mine":
            current_user = self.current_user
            rows = [r for r in rows if r["user"] == current_user]
        elif self.process_filter_mode == "active":
            rows = [r for r in rows if r["status"] in _ACTIVE_STATUSES]
        GLib.idle_add(self._apply_process_rows, rows)

    def _apply_process_rows(self, rows):
        self._process_refresh_in_flight = False
        if self.active_tab == "piegraph":
            self._apply_pie(rows)
            return False
        now = datetime.now()
        process_config = self.process_config
        for r in rows:
            cfg = process_config.get(r["name"], _EMPTY_DICT)
            r["pinned"] = cfg.get("pinned", False)
            r["highlight_color"] = cfg.get("highlight_color")
        if self.tree_mode:
            self._apply_tree(rows, now)
        else:
            self._apply_flat(rows, now)
        if len(rows) != self._last_count:
            self._last_count = len(rows)
            self.proc_count_label.set_text(f"{len(rows)} processes")
        return False

    def _apply_flat(self, rows, now):
        rows_by_pid = {r["pid"]: r for r in rows}
        key_fn = self.SORT_KEYS[self.sort_column]
        flat_store = self.flat_store
        pid_iters = self._flat_pid_iters
        pid_values = self._flat_pid_values
        row_tuple = self._row_tuple
        stale_pids = pid_iters.keys() - rows_by_pid.keys()
        for pid in stale_pids:
            it = pid_iters.pop(pid)
            flat_store.remove(it)
            pid_values.pop(pid, None)
        for pid, r in rows_by_pid.items():
            values = row_tuple(r, now)
            it = pid_iters.get(pid)
            if it is None:
                it = flat_store.append(values)
                pid_iters[pid] = it
                pid_values[pid] = values
            elif pid_values.get(pid) != values:
                # Only touch the store when the row actually changed — a
                # write here fires a row-changed signal, which makes the
                # TreeModelFilter re-run visible_func for that row. Most
                # processes are idle between 2s samples, so this skips a
                # large fraction of GTK work every tick.
                flat_store[it] = values
                pid_values[pid] = values
        desired_pids = self._ordered_pids(rows_by_pid.keys(), rows_by_pid, key_fn)
        new_order = [flat_store.get_path(pid_iters[pid]).get_indices()[0] for pid in desired_pids]
        if new_order:
            flat_store.reorder(new_order)

    def _apply_tree(self, rows, now):
        self.tree_store.clear()
        rows_by_pid = {r["pid"]: r for r in rows}
        key_fn = self.SORT_KEYS[self.sort_column]
        tree_store = self.tree_store
        row_tuple = self._row_tuple
        ordered_pids = self._ordered_pids
        children_map = {}
        roots = []
        for pid, r in rows_by_pid.items():
            ppid = r["ppid"]
            if ppid in rows_by_pid and ppid != pid:
                children_map.setdefault(ppid, []).append(pid)
            else:
                roots.append(pid)

        def insert(parent_iter, pid):
            it = tree_store.append(parent_iter, row_tuple(rows_by_pid[pid], now))
            for child in ordered_pids(children_map.get(pid, []), rows_by_pid, key_fn):
                insert(it, child)
        for root_pid in ordered_pids(roots, rows_by_pid, key_fn):
            insert(None, root_pid)
    # -- process context menu / actions

    def _get_selected_pid(self):
        model, it = self.process_view.get_selection().get_selected()
        if it is None:
            return None
        return model.get_value(it, 0)

    def _on_process_button_press(self, widget, event):
        if event.button == 3:
            path_info = widget.get_path_at_pos(int(event.x), int(event.y))
            if path_info is not None:
                widget.get_selection().unselect_all()
                widget.get_selection().select_path(path_info[0])
                self._show_process_context_menu(event)
            return True
        return False

    def _show_process_context_menu(self, event):
        pid = self._get_selected_pid()
        if pid is None:
            return
        try:
            proc = psutil.Process(pid)
            proc_name = proc.name()
        except psutil.NoSuchProcess:
            return
        try:
            current_nice = proc.nice()
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            current_nice = None
        menu = Gtk.Menu()

        def add_item(label, callback):
            item = Gtk.MenuItem(label=label)
            item.connect("activate", callback)
            menu.append(item)
        is_pinned = self.process_config.get(proc_name, {}).get("pinned", False)
        add_item("Unpin" if is_pinned else "Pin to Top", lambda w: self._action_toggle_pin(proc_name))
        menu.append(Gtk.SeparatorMenuItem())
        add_item("End Process", lambda w: self._action_signal(pid, "terminate"))
        add_item("Kill Process", lambda w: self._action_kill_confirm(pid))
        menu.append(Gtk.SeparatorMenuItem())
        add_item("Stop", lambda w: self._action_signal(pid, "suspend"))
        add_item("Continue", lambda w: self._action_signal(pid, "resume"))
        menu.append(Gtk.SeparatorMenuItem())
        priority_item = Gtk.MenuItem(label="Change Priority")
        priority_menu = Gtk.Menu()
        current_label = Gtk.MenuItem(label=f"Active Priority: {current_nice if current_nice is not None else '?'}")
        current_label.set_sensitive(False)
        priority_menu.append(current_label)
        priority_menu.append(Gtk.SeparatorMenuItem())
        radio_items = []
        group = None
        for label, value in self.PRIORITY_PRESETS:
            item = Gtk.RadioMenuItem.new_with_label_from_widget(group, label)
            group = item
            radio_items.append((item, value))
            priority_menu.append(item)
        for item, value in radio_items:  # set initial state before connecting, avoids spurious applies
            if current_nice == value:
                item.set_active(True)
        for item, value in radio_items:
            item.connect("toggled", lambda w, v=value: self._on_priority_radio_toggled(w, pid, v))
        priority_menu.append(Gtk.SeparatorMenuItem())
        custom = Gtk.MenuItem(label="Custom...")
        custom.connect("activate", lambda w: self._action_custom_priority(pid, current_nice))
        priority_menu.append(custom)
        priority_item.set_submenu(priority_menu)
        menu.append(priority_item)
        add_item("CPU Affinity...", lambda w: self._action_cpu_affinity(pid))
        menu.append(Gtk.SeparatorMenuItem())
        add_item("Open File Location", lambda w: self._action_open_folder(pid))
        menu.append(Gtk.SeparatorMenuItem())
        add_item("Highlight Color...", lambda w: self._action_highlight_color(pid, proc_name))
        if proc_name in self.process_config and self.process_config[proc_name].get("highlight_color"):
            add_item("Remove Highlight", lambda w: self._action_remove_highlight(proc_name))
        menu.append(Gtk.SeparatorMenuItem())
        add_item("Properties...", lambda w: self._show_process_properties(pid))
        menu.show_all()
        menu.popup_at_pointer(event)

    def _show_error(self, message):
        dialog = Gtk.MessageDialog(transient_for=self, message_type=Gtk.MessageType.ERROR,
                                    buttons=Gtk.ButtonsType.OK, text=message)
        dialog.run()
        dialog.destroy()

    def _action_toggle_pin(self, proc_name):
        entry = self.process_config.setdefault(proc_name, {})
        if entry.get("pinned"):
            entry.pop("pinned", None)
        else:
            entry["pinned"] = True
        if not entry:
            del self.process_config[proc_name]
        save_config(self.process_config)
        self._refresh_processes()

    def _action_signal(self, pid, method):
        try:
            getattr(psutil.Process(pid), method)()
        except psutil.NoSuchProcess:
            self._show_error("The process does not exist.")
        except psutil.AccessDenied:
            self._show_error("Permission denied for that accion in that process.")

    def _action_kill_confirm(self, pid):
        dialog = Gtk.MessageDialog(transient_for=self, message_type=Gtk.MessageType.WARNING,
                                    buttons=Gtk.ButtonsType.YES_NO,
                                    text=f"Kill process PID {pid} with SIGKILL?")
        response = dialog.run()
        dialog.destroy()
        if response == Gtk.ResponseType.YES:
            self._action_signal(pid, "kill")

    def _on_priority_radio_toggled(self, widget, pid, value):
        if widget.get_active():
            self._action_set_priority(pid, value)

    def _action_set_priority(self, pid, value):
        try:
            psutil.Process(pid).nice(value)
        except psutil.NoSuchProcess:
            self._show_error("The process does not exist.")
        except psutil.AccessDenied:
            self._show_error("Permission denied.")

    def _action_custom_priority(self, pid, current_value=0):
        dialog = Gtk.Dialog(title="Custom priority", transient_for=self)
        dialog.add_buttons("Cancel", Gtk.ResponseType.CANCEL, "Apply", Gtk.ResponseType.OK)
        content = dialog.get_content_area()
        content.set_border_width(12)
        content.set_spacing(6)
        content.add(Gtk.Label(label=f"Nice value (-20 a 19). current: {current_value if current_value is not None else '?'}"))
        adjustment = Gtk.Adjustment(value=current_value or 0, lower=-20, upper=19, step_increment=1)
        spin = Gtk.SpinButton(adjustment=adjustment, climb_rate=1, digits=0)
        content.add(spin)
        dialog.show_all()
        response = dialog.run()
        if response == Gtk.ResponseType.OK:
            self._action_set_priority(pid, spin.get_value_as_int())
        dialog.destroy()

    def _action_cpu_affinity(self, pid):
        try:
            proc = psutil.Process(pid)
            current = set(proc.cpu_affinity())
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            self._show_error("Permission denied, or the process no longer exists.")
            return
        except AttributeError:
            self._show_error("cpu_affinity() not supported in this system.")
            return
        core_count = psutil.cpu_count(logical=True) or 1
        dialog = Gtk.Dialog(title=f"CPU Affinity - PID {pid}", transient_for=self)
        dialog.add_buttons("Cancel", Gtk.ResponseType.CANCEL, "Apply", Gtk.ResponseType.OK)
        content = dialog.get_content_area()
        content.set_border_width(12)
        content.set_spacing(8)
        content.add(Gtk.Label(label="Allowed cores:", xalign=0))
        checks = []
        grid = Gtk.Grid(row_spacing=4, column_spacing=12)
        cols = 4
        for i in range(core_count):
            check = Gtk.CheckButton(label=f"CORE {i}")
            check.set_active(i in current)
            checks.append(check)
            r, c = divmod(i, cols)
            grid.attach(check, c, r, 1, 1)
        content.add(grid)
        btn_box = Gtk.Box(spacing=6)
        select_all = Gtk.Button(label="All")
        select_all.connect("clicked", lambda w: [c.set_active(True) for c in checks])
        select_none = Gtk.Button(label="None")
        select_none.connect("clicked", lambda w: [c.set_active(False) for c in checks])
        btn_box.pack_start(select_all, False, False, 0)
        btn_box.pack_start(select_none, False, False, 0)
        content.add(btn_box)
        dialog.show_all()
        response = dialog.run()
        if response == Gtk.ResponseType.OK:
            selected = [i for i, c in enumerate(checks) if c.get_active()]
            if not selected:
                self._show_error("Leave at least one core selected.")
            else:
                try:
                    proc.cpu_affinity(selected)
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    self._show_error("Permission denied.")
        dialog.destroy()

    def _action_open_folder(self, pid):
        try:
            exe = psutil.Process(pid).exe()
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            self._show_error("Could not obtain the executable path. "
                              "(Permission denied, or it is a kernel thread with no associated executable.).")
            return
        if not exe:
            self._show_error("That process does not have an associated executable path.")
            return
        folder = os.path.dirname(exe)
        try:
            subprocess.Popen(["xdg-open", folder])
        except FileNotFoundError:
            self._show_error("could not find 'xdg-open'. Install with: sudo apt install xdg-utils")

    def _action_highlight_color(self, pid, proc_name):
        dialog = Gtk.ColorChooserDialog(title=f"Color for \"{proc_name}\"", transient_for=self)
        existing = self.process_config.get(proc_name, {}).get("highlight_color")
        if existing:
            rgba = Gdk.RGBA()
            if rgba.parse(existing):
                dialog.set_rgba(rgba)
        response = dialog.run()
        if response == Gtk.ResponseType.OK:
            rgba = dialog.get_rgba()
            hex_color = "#{:02X}{:02X}{:02X}".format(
                round(rgba.red * 255), round(rgba.green * 255), round(rgba.blue * 255)
            )
            self.process_config.setdefault(proc_name, {})["highlight_color"] = hex_color
            save_config(self.process_config)
            self._refresh_processes()
        dialog.destroy()

    def _action_remove_highlight(self, proc_name):
        if proc_name in self.process_config:
            self.process_config[proc_name].pop("highlight_color", None)
            if not self.process_config[proc_name]:
                del self.process_config[proc_name]
            save_config(self.process_config)
            self._refresh_processes()

    def _show_process_properties(self, pid):
        try:
            proc = psutil.Process(pid)
            with proc.oneshot():
                name = proc.name()
                status = proc.status()
                user = proc.username()
                created = format_started(proc.create_time(), datetime.now())
                threads = proc.num_threads()
            exe = safe_call(proc.exe, "-")
            cwd = safe_call(proc.cwd, "-")
            cmdline = " ".join(safe_call(proc.cmdline, []) or []) or "-"
            try:
                affinity = ",".join(str(c) for c in proc.cpu_affinity())
            except (psutil.AccessDenied, psutil.Error, AttributeError):
                affinity = "N/A"
            try:
                open_files = len(proc.open_files())
            except (psutil.AccessDenied, psutil.Error):
                open_files = "N/A"
            try:
                conn_fn = proc.net_connections if hasattr(proc, "net_connections") else proc.connections
                conns = len(conn_fn())
            except (psutil.AccessDenied, psutil.Error):
                conns = "N/A"
        except psutil.NoSuchProcess:
            self._show_error("The process does not exist.")
            return
        dialog = Gtk.Dialog(title=f"Properties - PID {pid}", transient_for=self)
        dialog.add_buttons("Close", Gtk.ResponseType.CLOSE)
        dialog.set_default_size(440, 340)
        content = dialog.get_content_area()
        content.set_border_width(16)
        content.get_style_context().add_class("props-dialog")
        grid = Gtk.Grid(row_spacing=6, column_spacing=16)
        fields = [
            ("PID", str(pid)), ("Name", name), ("State", status), ("User", user),
            ("Executable", exe), ("Directory", cwd), ("Command", cmdline),
            ("Threads", str(threads)), ("Created", created), ("CPU Affinity", affinity),
            ("Open Files", str(open_files)), ("Connections", str(conns)),
        ]
        for i, (label, value) in enumerate(fields):
            lbl = Gtk.Label(label=label, xalign=0)
            lbl.get_style_context().add_class("props-key")
            val = Gtk.Label(label=str(value), xalign=0)
            val.set_line_wrap(True)
            val.set_max_width_chars(42)
            val.get_style_context().add_class("props-value")
            grid.attach(lbl, 0, i, 1, 1)
            grid.attach(val, 1, i, 1, 1)
        content.add(grid)
        dialog.show_all()
        dialog.run()
        dialog.destroy()
    # ------------------------------------------------------------ PIE GRAPH

    def _build_piegraph_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=32)
        box.set_margin_start(20)
        box.set_margin_end(20)
        box.set_margin_top(20)
        box.set_margin_bottom(20)
        self.pie_graph = PieGraph(self.theme)
        self.pie_graph.set_hexpand(True)
        self.pie_graph.set_vexpand(True)
        box.pack_start(self.pie_graph, True, True, 0)
        side = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        side.set_size_request(320, -1)
        side.pack_start(self._section_label("TOP CONSUMERS  ·  CPU% + MEM%"), False, False, 0)
        self.pie_legend = self._build_legend(side, PIE_TOP_N + 1)
        box.pack_start(side, False, False, 0)
        return box

    def _build_legend(self, parent, rows):
        """A fixed set of legend rows built once. Updating = setting label
        text; no widgets are created or destroyed per tick."""
        legend_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        parent.pack_start(legend_box, False, False, 0)
        entries = []
        self._legend_chips = getattr(self, "_legend_chips", [])
        attrs = tabular_attrs()
        for i in range(rows):
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
            row.get_style_context().add_class("zt-theme-row")
            chip = ColorChip(self.theme[f"s{i % 8}"], size=10)
            self._legend_chips.append((chip, i))
            name = Gtk.Label(label="", xalign=0)
            name.set_ellipsize(Pango.EllipsizeMode.END)
            name.get_style_context().add_class("props-value")
            pct = Gtk.Label(label="", xalign=1)
            pct.set_attributes(attrs)
            pct.get_style_context().add_class("props-value")
            row.pack_start(chip, False, False, 0)
            row.pack_start(name, True, True, 0)
            row.pack_start(pct, False, False, 0)
            row.set_no_show_all(True)
            for w in (chip, name, pct):
                w.show()
            legend_box.pack_start(row, False, False, 0)
            entries.append((row, name, pct))
        return entries

    def _apply_pie(self, rows):
        """'Overall' consumption = CPU% + memory% of total RAM, blended
        50/50 — both are already 0-100 scale, so a plain sum is a
        reasonable single 'how much of the machine is this using' score.
        Reuses the SAME row data the Processes tab fetches; no separate
        process scan just for this chart."""
        total_mem = self.total_mem
        scored = []
        for r in rows:
            score = r["cpu"] + r["mem"] * 100.0 / total_mem
            if score > 0:
                scored.append((r["name"], score))
        scored.sort(key=lambda t: t[1], reverse=True)
        top = scored[:PIE_TOP_N]
        rest = scored[PIE_TOP_N:]
        others_total = sum(s for _, s in rest)
        slices = list(top)
        if others_total > 0.05:
            slices.append((f"Others ({len(rest)})", others_total))
        self.pie_graph.set_data(slices)
        self._update_legend(self.pie_legend, slices)

    def _update_legend(self, entries, slices, fmt_value=None):
        total = sum(v for _, v in slices) or 1.0
        for i, (row, name_lbl, pct_lbl) in enumerate(entries):
            if i < len(slices):
                name, value = slices[i]
                txt = fmt_value(value) if fmt_value else f"{value / total * 100:.1f}%"
                if name_lbl.get_text() != name:
                    name_lbl.set_text(name)
                if pct_lbl.get_text() != txt:
                    pct_lbl.set_text(txt)
                if not row.get_visible():
                    row.show()
            elif row.get_visible():
                row.hide()
    # ------------------------------------------------------------ RESOURCES

    def _build_resources_tab(self):
        outer = Gtk.ScrolledWindow()
        outer.set_vexpand(True)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_margin_start(20)
        box.set_margin_end(20)
        box.set_margin_top(16)
        box.set_margin_bottom(24)
        outer.add(box)
        # CPU: the figure first, then its history, then the per-core board
        _, self.cpu_total_label = self._section_header(box, "CPU")
        self.cpu_history = HistoryGraph(
            self.theme, [{"role": "g-cpu", "data": deque(maxlen=HISTORY_LEN)}], y_max=100.0)
        box.pack_start(self.cpu_history, False, False, 0)
        core_count = psutil.cpu_count(logical=True) or 1
        self.core_bars = []
        cores_grid = Gtk.Grid(row_spacing=10, column_spacing=24, column_homogeneous=False)
        cores_grid.set_margin_top(6)
        cols = 2 if core_count <= 4 else 4
        for i in range(core_count):
            lbl = Gtk.Label(label=f"CORE {i}", xalign=0)
            lbl.get_style_context().add_class("bar-label")
            lbl.set_width_chars(7)
            bar = Gtk.ProgressBar()
            bar.get_style_context().add_class("cpu-bar")
            bar.set_hexpand(True)
            bar.set_valign(Gtk.Align.CENTER)
            val = Gtk.Label(label="-", xalign=1)
            val.get_style_context().add_class("bar-label")
            val.set_width_chars(4)
            r, c = divmod(i, cols)
            cores_grid.attach(lbl, c * 3, r, 1, 1)
            cores_grid.attach(bar, c * 3 + 1, r, 1, 1)
            cores_grid.attach(val, c * 3 + 2, r, 1, 1)
            self.core_bars.append((bar, val))
        box.pack_start(cores_grid, False, False, 0)
        # MEMORY & SWAP
        _, self.mem_total_label = self._section_header(box, "MEMORY", margin_top=24)
        self.ram_bar = Gtk.ProgressBar()
        self.ram_bar.get_style_context().add_class("ram-bar")
        box.pack_start(self.ram_bar, False, False, 0)
        _, self.swap_total_label = self._section_header(box, "SWAP", margin_top=8)
        self.swap_bar = Gtk.ProgressBar()
        self.swap_bar.get_style_context().add_class("swap-bar")
        box.pack_start(self.swap_bar, False, False, 0)
        self.mem_history = HistoryGraph(
            self.theme,
            [{"role": "g-mem", "data": deque(maxlen=HISTORY_LEN)},
             {"role": "g-swap", "data": deque(maxlen=HISTORY_LEN)}],
            y_max=100.0)
        self.mem_history.set_margin_top(6)
        box.pack_start(self.mem_history, False, False, 0)
        # NETWORK
        net_header, _ = self._section_header(box, "NETWORK", margin_top=24, with_value=False)
        self.net_sent_label = Gtk.Label(label="TX 0.0B/s")
        self.net_sent_label.get_style_context().add_class("net-sent-label")
        self.net_recv_label = Gtk.Label(label="RX 0.0B/s")
        self.net_recv_label.get_style_context().add_class("net-recv-label")
        self.net_recv_label.set_margin_end(18)
        net_header.pack_end(self.net_sent_label, False, False, 0)
        net_header.pack_end(self.net_recv_label, False, False, 0)
        self.net_history = HistoryGraph(
            self.theme,
            [{"role": "g-rx", "data": deque(maxlen=HISTORY_LEN)},
             {"role": "g-tx", "data": deque(maxlen=HISTORY_LEN)}],
            auto_scale=True)
        box.pack_start(self.net_history, False, False, 0)
        return outer

    def _section_label(self, text):
        lbl = Gtk.Label(label=text, xalign=0)
        lbl.get_style_context().add_class("section-label")
        return lbl

    def _section_header(self, parent, text, margin_top=0, with_value=True):
        """Section name on the left, its live figure on the right, like a
        timetable's line name and departure time on one rule."""
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        row.set_margin_top(margin_top)
        row.pack_start(self._section_label(text), False, False, 0)
        value = None
        if with_value:
            value = Gtk.Label(label="-", xalign=1)
            value.get_style_context().add_class("zt-stat-value")
            row.pack_end(value, False, False, 0)
        parent.pack_start(row, False, False, 0)
        return row, value

    def _refresh_resources(self):
        if self.active_tab != "resources":
            return True
        per_core = psutil.cpu_percent(percpu=True)
        for (bar, val), pct in zip(self.core_bars, per_core):
            bar.set_fraction(pct / 100.0)
            val.set_text(f"{pct:.0f}%")
        overall_cpu = sum(per_core) / len(per_core) if per_core else 0.0
        self.cpu_history.push([overall_cpu])
        self.cpu_total_label.set_text(f"{overall_cpu:.0f}%")
        vm = psutil.virtual_memory()
        self.ram_bar.set_fraction(vm.percent / 100.0)
        self.mem_total_label.set_text(f"{format_bytes(vm.used)} / {format_bytes(vm.total)}  ·  {vm.percent:.0f}%")
        sm = psutil.swap_memory()
        self.swap_bar.set_fraction((sm.percent / 100.0) if sm.total else 0.0)
        self.swap_total_label.set_text(
            f"{format_bytes(sm.used)} / {format_bytes(sm.total)}  ·  {sm.percent:.0f}%" if sm.total else "No swap"
        )
        self.mem_history.push([vm.percent, sm.percent if sm.total else 0.0])
        net = psutil.net_io_counters()
        now = time.time()
        if self.prev_net is not None:
            dt = now - self.prev_net[2]
            recv_rate = (net.bytes_recv - self.prev_net[0]) / dt if dt > 0 else 0
            sent_rate = (net.bytes_sent - self.prev_net[1]) / dt if dt > 0 else 0
        else:
            recv_rate = sent_rate = 0
        self.prev_net = (net.bytes_recv, net.bytes_sent, now)
        self.net_history.push([recv_rate, sent_rate])
        self.net_recv_label.set_text(f"RX {format_rate(recv_rate)}")
        self.net_sent_label.set_text(f"TX {format_rate(sent_rate)}")
        return True
    # ---------------------------------------------------------- FILESYSTEMS

    def _build_filesystems_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_margin_start(20)
        box.set_margin_end(20)
        box.set_margin_top(16)
        box.set_margin_bottom(20)
        self.fs_store = Gtk.ListStore(str, str, str, str, str, str, int)
        self.fs_view = Gtk.TreeView(model=self.fs_store)
        self.fs_view.get_style_context().add_class("data-table")
        titles = ["DEVICE", "MOUNTPOINT", "TYPE", "TOTAL", "USED", "FREE"]
        fs_tnum = tabular_attrs()
        for i, title in enumerate(titles):
            renderer = Gtk.CellRendererText(xalign=0.0 if i < 3 else 1.0)
            renderer.set_padding(8, 4)
            if i >= 3:
                renderer.set_property("attributes", fs_tnum)
            col = Gtk.TreeViewColumn(title, renderer, text=i)
            col.set_resizable(True)
            col.set_expand(i == 1)
            self.fs_view.append_column(col)
        # Timetable style: the figure in tabular digits, then a thin bar.
        # A handful of rows, so a data func here costs nothing.
        pct_col = Gtk.TreeViewColumn("USED %")
        pct_text = Gtk.CellRendererText(xalign=1.0)
        pct_text.set_padding(8, 3)
        pct_text.set_property("attributes", tabular_attrs())
        pct_col.pack_start(pct_text, False)
        pct_col.set_cell_data_func(
            pct_text, lambda c, r, m, it, d: r.set_property("text", f"{m[it][6]}%"))
        pct_renderer = Gtk.CellRendererProgress(text="")
        pct_renderer.set_fixed_size(-1, 4)  # never sets the row height...
        pct_renderer.set_padding(4, 8)      # ...and leaves a ~7px bar centred in it
        pct_col.pack_start(pct_renderer, True)
        pct_col.add_attribute(pct_renderer, "value", 6)
        pct_col.set_min_width(160)
        self.fs_view.append_column(pct_col)
        table_scroller = Gtk.ScrolledWindow()
        table_scroller.set_size_request(-1, 170)  # fixed-ish: the breakdown below needs the real space
        table_scroller.add(self.fs_view)
        box.pack_start(table_scroller, False, False, 0)
        # -- disk usage breakdown (WizTree-style treemap, with a pie fallback)
        breakdown = self._section_label("DISK USAGE BREAKDOWN")
        breakdown.set_margin_top(14)
        box.pack_start(breakdown, False, False, 0)
        toolbar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.fs_scan_button = Gtk.Button(label="Analyze Selected Disk")
        self.fs_scan_button.get_style_context().add_class("tree-toggle")
        self.fs_scan_button.connect("clicked", self._on_fs_scan_clicked)
        toolbar.pack_start(self.fs_scan_button, False, False, 0)
        self.fs_cancel_button = Gtk.Button(label="Cancel")
        self.fs_cancel_button.get_style_context().add_class("tree-toggle")
        self.fs_cancel_button.connect("clicked", self._on_fs_scan_cancel)
        self.fs_cancel_button.set_no_show_all(True)
        self.fs_cancel_button.set_visible(False)
        toolbar.pack_start(self.fs_cancel_button, False, False, 0)
        self.fs_pie_toggle = Gtk.ToggleButton(label="PIE VIEW")
        self.fs_pie_toggle.get_style_context().add_class("tree-toggle")
        self.fs_pie_toggle.connect("toggled", self._on_fs_pie_toggled)
        toolbar.pack_start(self.fs_pie_toggle, False, False, 0)
        self.fs_spinner = Gtk.Spinner()
        toolbar.pack_start(self.fs_spinner, False, False, 0)
        self.fs_status_label = Gtk.Label(label="Select a partition above, then Analyze.", xalign=0)
        self.fs_status_label.get_style_context().add_class("bar-label")
        toolbar.pack_start(self.fs_status_label, True, True, 0)
        box.pack_start(toolbar, False, False, 4)
        viz_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        viz_box.set_vexpand(True)
        self.fs_treemap = TreemapGraph(self.theme)
        self.fs_treemap.set_vexpand(True)
        viz_box.pack_start(self.fs_treemap, True, True, 0)
        self.fs_pie_container = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=24)
        self.fs_pie_container.set_vexpand(True)
        self.fs_pie_container.set_no_show_all(True)
        self.fs_pie_container.set_visible(False)
        self.fs_pie_graph = PieGraph(self.theme)
        self.fs_pie_graph.set_hexpand(True)
        self.fs_pie_graph.set_vexpand(True)
        self.fs_pie_container.pack_start(self.fs_pie_graph, True, True, 0)
        fs_legend_scroller = Gtk.ScrolledWindow()
        fs_legend_scroller.set_size_request(320, -1)
        fs_legend_scroller.set_vexpand(True)
        fs_side = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        fs_legend_scroller.add(fs_side)
        self.fs_pie_legend = self._build_legend(fs_side, FS_SCAN_TOP_N + 1)
        self.fs_pie_container.pack_start(fs_legend_scroller, False, False, 0)
        viz_box.pack_start(self.fs_pie_container, True, True, 0)
        box.pack_start(viz_box, True, True, 0)
        return box

    def _refresh_filesystems(self):
        if self.active_tab != "filesystems":
            return True
        self.fs_store.clear()
        for part in psutil.disk_partitions(all=False):
            try:
                usage = psutil.disk_usage(part.mountpoint)
            except (PermissionError, OSError):
                continue
            self.fs_store.append([
                part.device, part.mountpoint, part.fstype,
                format_bytes(usage.total), format_bytes(usage.used), format_bytes(usage.free),
                int(usage.percent),
            ])
        return True
    # -- disk usage scan orchestration

    def _on_fs_pie_toggled(self, button):
        pie_mode = button.get_active()
        if pie_mode:
            # fs_pie_container has no_show_all=True so it stays hidden by
            # default at startup — but that also means the app's initial
            # show_all() never descended into ITS children (the pie graph
            # and legend), so they were never shown even once. Clear the
            # flag and show_all() this subtree the first time we reveal it.
            self.fs_pie_container.set_no_show_all(False)
            self.fs_pie_container.show_all()
        self.fs_treemap.set_visible(not pie_mode)
        self.fs_pie_container.set_visible(pie_mode)

    def _on_fs_scan_clicked(self, button):
        if self.fs_scan_in_progress:
            return
        model, it = self.fs_view.get_selection().get_selected()
        if it is None:
            self._show_error("Select a partition from the table above first.")
            return
        mountpoint = model[it][1]
        self.fs_scan_in_progress = True
        self.fs_scan_cancel_event = threading.Event()
        self.fs_scan_button.set_sensitive(False)
        self.fs_cancel_button.set_visible(True)
        self.fs_spinner.start()
        self.fs_status_label.set_text(f"Scanning {mountpoint}... this can take a while on a big disk.")
        self.fs_scan_executor.submit(self._scan_disk_bg, mountpoint, self.fs_scan_cancel_event)

    def _on_fs_scan_cancel(self, button):
        if self.fs_scan_cancel_event is not None:
            self.fs_scan_cancel_event.set()

    def _scan_disk_bg(self, mountpoint, cancel_event):
        """Runs on fs_scan_executor's worker thread — pure filesystem
        walk, zero GTK calls."""
        start = time.time()
        entries = scan_disk_usage(mountpoint, cancel_event)
        elapsed = time.time() - start
        GLib.idle_add(self._on_fs_scan_done, entries, mountpoint, elapsed, cancel_event.is_set())

    def _on_fs_scan_done(self, entries, mountpoint, elapsed, cancelled):
        self.fs_scan_in_progress = False
        self.fs_scan_button.set_sensitive(True)
        self.fs_cancel_button.set_visible(False)
        self.fs_spinner.stop()
        if entries is None:
            self.fs_status_label.set_text(f"Couldn't read {mountpoint} (permission denied?).")
            return False
        entries.sort(key=lambda e: e[1], reverse=True)
        top = entries[:FS_SCAN_TOP_N]
        rest = entries[FS_SCAN_TOP_N:]
        others_size = sum(e[1] for e in rest)
        display_entries = list(top)
        if others_size > 0:
            display_entries.append((f"Others ({len(rest)} items)", others_size, False))
        self.fs_treemap.set_data(display_entries)
        slices = [(name, size) for name, size, _ in display_entries]
        self.fs_pie_graph.set_data(slices)
        self._update_legend(self.fs_pie_legend, slices, fmt_value=format_bytes)
        prefix = "Cancelled — partial results. " if cancelled else ""
        self.fs_status_label.set_text(
            f"{prefix}{mountpoint}: {len(entries)} top-level items scanned in {elapsed:.1f}s"
        )
        return False
    # -------------------------------------------------------------- THEMES

    def _build_themes_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        box.set_margin_start(20)
        box.set_margin_end(20)
        box.set_margin_top(16)
        heading = self._section_label("SELECT A THEME")
        heading.set_margin_bottom(6)
        box.pack_start(heading, False, False, 0)
        self.theme_radios = {}
        group = None
        for theme in THEMES:
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14)
            row.get_style_context().add_class("zt-theme-row")
            radio = Gtk.RadioButton.new_from_widget(group)
            group = radio
            radio.set_active(theme["id"] == self.current_theme)
            self.theme_radios[theme["id"]] = radio
            row.pack_start(radio, False, False, 0)
            text_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            name_lbl = Gtk.Label(label=theme["name"], xalign=0)
            name_lbl.get_style_context().add_class("theme-name")
            desc_lbl = Gtk.Label(label=theme["desc"], xalign=0)
            desc_lbl.get_style_context().add_class("theme-desc")
            text_box.pack_start(name_lbl, False, False, 0)
            text_box.pack_start(desc_lbl, False, False, 0)
            row.pack_start(text_box, True, True, 0)
            chips = Gtk.Box(spacing=4)
            for hex_color in theme["colors"]:
                rgba = Gdk.RGBA()
                rgba.parse(hex_color)
                chips.pack_start(ColorChip((rgba.red, rgba.green, rgba.blue), size=16, outline=self.theme), False, False, 0)
            row.pack_start(chips, False, False, 0)
            # clicking anywhere on the row selects the theme, not just the radio dot
            event_box = Gtk.EventBox()
            event_box.add(row)
            theme_id = theme["id"]
            event_box.connect("button-press-event", lambda w, e, tid=theme_id: self.theme_radios[tid].set_active(True))
            radio.connect("toggled", self._on_theme_radio_toggled, theme_id)
            box.pack_start(event_box, False, False, 0)
        return box

    def _on_theme_radio_toggled(self, widget, theme_id):
        if widget.get_active():
            self._apply_theme(theme_id)

def main():
    register_app_fonts()
    win = SystemMonitorWindow()
    win.connect("destroy", Gtk.main_quit)
    win.show_all()
    Gtk.main()

if __name__ == "__main__":
    main()
