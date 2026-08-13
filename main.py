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
from concurrent.futures import ThreadPoolExecutor
from collections import deque
from datetime import datetime

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib, Gdk

import psutil

APP_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_DIR = os.path.expanduser("~/.config/system-monitor-pp")
CONFIG_PATH = os.path.join(CONFIG_DIR, "process_config.json")
APP_CONFIG_PATH = os.path.join(CONFIG_DIR, "app_config.json")
THEMES_DIR = os.path.join(APP_DIR, "themes")

THEMES = [
    {
        "id": "default",
        "name": "DEFAULT — GitHub Dark",
        "desc": "Fondo #0D1117, acentos violeta.",
        "colors": ["#0D1117", "#8B5CF6", "#161B22"],
    },
    {
        "id": "eva01",
        "name": "EVA-01",
        "desc": "Violeta profundo, verde lima, alerta roja.",
        "colors": ["#0F0A1F", "#7B2FD9", "#8CFF6B"],
    },
    {
        "id": "magi",
        "name": "MAGI",
        "desc": "Terminal negra monocromática, ámbar CRT.",
        "colors": ["#060606", "#FFB000", "#FFCC66"],
    },
    {
        "id": "eva00",
        "name": "EVA-00",
        "desc": "Azul pálido / blanco, franjas naranja.",
        "colors": ["#0A1420", "#FF8C1A", "#7FD4F0"],
    },
    {
        "id": "eva02",
        "name": "EVA-02",
        "desc": "Rojo/naranja Made in Germany, crema.",
        "colors": ["#150808", "#E8412C", "#F4C95D"],
    },
    {
        "id": "pastel",
        "name": "PASTEL FUCSIA",
        "desc": "Fondo rosa claro, tonos fucsia y lavanda.",
        "colors": ["#FDF0F5", "#E85CA6", "#C9A0DC"],
    },
]

PROCESS_REFRESH_MS = 2000
RESOURCES_REFRESH_MS = 1000
FS_REFRESH_MS = 5000
HISTORY_LEN = 60  # ~1 minute at 1s ticks
IO_COUNTERS_EVERY_N_TICKS = 3  # disk I/O columns refresh every ~6s instead of every 2s
PIN_MARKER = "\U0001F4CC "  # pin emoji; swap for "[PIN] " if it doesn't render on your system

PIE_TOP_N = 10  # individual wedges; everything past this gets grouped into "Otros"
# Fixed categorical palette, independent of the active theme — same
# approach the history graphs already use (their series colors don't
# change when you switch themes either). (hex, (r,g,b) 0-1) pairs so
# neither the Cairo drawing nor the GTK legend chips need to convert.
PIE_PALETTE = [
    ("#8B5CF6", (0.545, 0.361, 0.965)),
    ("#F472B6", (0.957, 0.447, 0.714)),
    ("#34D399", (0.204, 0.827, 0.600)),
    ("#FBBF24", (0.984, 0.749, 0.141)),
    ("#38BDF8", (0.220, 0.741, 0.973)),
    ("#F87171", (0.973, 0.443, 0.443)),
    ("#A3E635", (0.639, 0.902, 0.208)),
    ("#C084FC", (0.753, 0.518, 0.988)),
    ("#FB923C", (0.984, 0.573, 0.235)),
    ("#818CF8", (0.506, 0.549, 0.973)),
    ("#4ADE80", (0.290, 0.871, 0.502)),
    ("#FCD34D", (0.988, 0.827, 0.302)),
]

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
    """Scrolling filled line-chart, GNOME-System-Monitor style."""

    def __init__(self, series, y_max=100.0, auto_scale=False, history_len=HISTORY_LEN):
        super().__init__()
        self.series = series  # list of {"color": (r,g,b), "data": deque}
        self.y_max = y_max
        self.auto_scale = auto_scale
        self.set_size_request(-1, 130)
        self.connect("draw", self._on_draw)

    def push(self, values):
        for s, v in zip(self.series, values):
            s["data"].append(v)
        self.queue_draw()

    def _on_draw(self, widget, cr):
        alloc = widget.get_allocation()
        w, h = alloc.width, alloc.height

        cr.set_source_rgba(0.055, 0.063, 0.09, 1)
        cr.rectangle(0, 0, w, h)
        cr.fill()

        cr.set_source_rgba(1, 1, 1, 0.06)
        cr.set_line_width(1)
        for i in range(1, 4):
            y = h * i / 4
            cr.move_to(0, y)
            cr.line_to(w, y)
            cr.stroke()

        if self.auto_scale:
            y_max = max((v for s in self.series for v in s["data"]), default=0)
            y_max = max(y_max * 1.25, 1)
        else:
            y_max = self.y_max

        for s in self.series:
            data = s["data"]  # deque supports len() and repeated iteration — no need to copy to a list
            if len(data) < 2:
                continue
            n = len(data)
            step = w / max(n - 1, 1)
            r, g, b = s["color"]

            cr.set_source_rgba(r, g, b, 0.18)
            cr.move_to(0, h)
            for i, v in enumerate(data):
                cr.line_to(i * step, h - (min(v, y_max) / y_max) * h)
            cr.line_to((n - 1) * step, h)
            cr.close_path()
            cr.fill()

            cr.set_source_rgba(r, g, b, 0.95)
            cr.set_line_width(2)
            for i, v in enumerate(data):
                x, y = i * step, h - (min(v, y_max) / y_max) * h
                cr.move_to(x, y) if i == 0 else cr.line_to(x, y)
            cr.stroke()

        return False


# ------------------------------------------------------------- PIE GRAPH

class PieGraph(Gtk.DrawingArea):
    """Wedge per process, sized by an 'overall' consumption score. The
    legend (names + percentages) is built as normal GTK widgets by the
    window, not drawn here — text layout in raw Cairo is a pain to keep
    legible, GTK labels already handle it for free."""

    def __init__(self):
        super().__init__()
        self.slices = []  # list of (label, value), already sorted
        self.set_size_request(-1, 320)
        self.connect("draw", self._on_draw)

    def set_data(self, slices):
        self.slices = slices
        self.queue_draw()

    def _on_draw(self, widget, cr):
        alloc = widget.get_allocation()
        w, h = alloc.width, alloc.height
        cx, cy = w / 2, h / 2
        radius = max(min(w, h) / 2 - 12, 1)

        total = sum(v for _, v in self.slices)
        if total <= 0:
            return False

        start_angle = -math.pi / 2  # 12 o'clock
        for i, (_, value) in enumerate(self.slices):
            end_angle = start_angle + (value / total) * 2 * math.pi
            _, (r, g, b) = PIE_PALETTE[i % len(PIE_PALETTE)]
            cr.set_source_rgba(r, g, b, 0.92)
            cr.move_to(cx, cy)
            cr.arc(cx, cy, radius, start_angle, end_angle)
            cr.close_path()
            cr.fill()
            start_angle = end_angle

        return False


# ------------------------------------------------------------- MAIN WINDOW

class SystemMonitorWindow(Gtk.Window):

    COLUMNS = [
        ("PROCESS", 1), ("USER", 2), ("CPU", 3), ("CPUID", 4), ("MEMORY", 5),
        ("DISKREADTOTAL", 6), ("DISKWRITETOTAL", 7), ("DISKREAD", 8),
        ("DISKWRITE", 9), ("PRIORITY", 10), ("STATUS", 11), ("STARTED", 12),
        ("CPU TIME", 13),
    ]
    # 0=pid(int), 1-13=display strings, 14=background hex, 15=foreground hex
    BG_COL = 14
    FG_COL = 15
    STORE_SCHEMA = (int, *([str] * 15))

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

        self._load_css()
        self._build_ui()
        self.connect("destroy", self._on_destroy)

        GLib.timeout_add(PROCESS_REFRESH_MS, self._refresh_processes)
        GLib.timeout_add(RESOURCES_REFRESH_MS, self._refresh_resources)
        GLib.timeout_add(FS_REFRESH_MS, self._refresh_filesystems)

        self._on_active_tab_changed(self.stack, None)  # populate whichever tab is shown first

    def _on_destroy(self, *args):
        self._executor.shutdown(wait=False)

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
            self._show_error(f"No se encontró el archivo de tema: {path}")
            return
        # Reloading content on the SAME provider (already registered on the
        # screen) is enough — GTK re-applies styles to every widget live,
        # no need to remove/re-add providers or restart the app.
        self._css_provider.load_from_path(path)
        self.current_theme = theme_id
        self.app_config["theme"] = theme_id
        save_app_config(self.app_config)

    def _build_ui(self):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        root.get_style_context().add_class("root-bg")
        self.add(root)

        title = Gtk.Label(label="ZENTOP")
        title.get_style_context().add_class("title-label")
        title.set_margin_top(24)
        title.set_margin_bottom(16)
        root.pack_start(title, False, False, 0)

        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        self.stack.set_transition_duration(150)

        switcher = Gtk.StackSwitcher()
        switcher.set_stack(self.stack)
        switcher.set_halign(Gtk.Align.CENTER)
        switcher.get_style_context().add_class("pill-switcher")
        switcher.set_margin_bottom(20)
        root.pack_start(switcher, False, False, 0)

        self.stack.add_titled(self._build_processes_tab(), "processes", "PROCESSES")
        self.stack.add_titled(self._build_resources_tab(), "resources", "RESOURCES")
        self.stack.add_titled(self._build_piegraph_tab(), "piegraph", "PIE GRAPH")
        self.stack.add_titled(self._build_filesystems_tab(), "filesystems", "FILE SYSTEMS")
        self.stack.add_titled(self._build_themes_tab(), "themes", "THEMES")
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

    # ------------------------------------------------------------ PROCESSES

    def _build_processes_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_margin_start(24)
        box.set_margin_end(24)

        toolbar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)

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

        self.pause_toggle = Gtk.ToggleButton()
        self.pause_toggle.set_relief(Gtk.ReliefStyle.NONE)
        self.pause_toggle.set_tooltip_text("Pausar actualización de la tabla")
        self.pause_icon = Gtk.Image.new_from_icon_name("media-playback-pause-symbolic", Gtk.IconSize.SMALL_TOOLBAR)
        self.pause_toggle.add(self.pause_icon)
        self.pause_toggle.connect("toggled", self._on_pause_toggled)
        toolbar.pack_start(self.pause_toggle, False, False, 0)

        box.pack_start(toolbar, False, False, 4)

        self.flat_store = Gtk.ListStore(*self.STORE_SCHEMA)
        self.tree_store = Gtk.TreeStore(*self.STORE_SCHEMA)
        self._flat_pid_iters = {}
        self._flat_pid_values = {}  # pid -> last-written row tuple, for change detection

        self.process_filter = self.flat_store.filter_new()
        self.process_filter.set_visible_func(self._filter_func)

        self.process_view = Gtk.TreeView(model=self.process_filter)
        self.process_view.get_style_context().add_class("data-table")
        self.process_view.connect("button-press-event", self._on_process_button_press)

        for title, idx in self.COLUMNS:
            renderer = Gtk.CellRendererText(xalign=0.0 if idx in (1, 2, 11) else 1.0)
            col = Gtk.TreeViewColumn(title)
            col.pack_start(renderer, True)
            col.add_attribute(renderer, "text", idx)
            col.add_attribute(renderer, "background", self.BG_COL)
            col.add_attribute(renderer, "foreground", self.FG_COL)
            col.set_resizable(True)
            col.set_expand(idx == 1)
            col.set_clickable(True)
            col.connect("clicked", self._on_column_clicked, idx)
            self.process_view.append_column(col)

        self._update_sort_indicators()

        scroller = Gtk.ScrolledWindow()
        scroller.set_vexpand(True)
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
        name = r["name"]
        color = r["highlight_color"]
        cpuid = r["cpuid"]
        return (
            r["pid"], f"{PIN_MARKER}{name}" if r["pinned"] else name, r["user"] or "-", f"{r['cpu']:.1f}%",
            str(cpuid) if cpuid >= 0 else "-",
            format_bytes(r["mem"]), format_bytes(r["read_total"]), format_bytes(r["write_total"]),
            format_rate(r["read_rate"]), format_rate(r["write_rate"]),
            str(r["priority"]), r["status"], format_started(r["create_time"], now),
            format_duration(r["cputime"]), color if color else None,
            self._contrast_color(color) if color else None,
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
            button.set_tooltip_text("Reanudar actualización")
        else:
            self.pause_icon.set_from_icon_name("media-playback-pause-symbolic", Gtk.IconSize.SMALL_TOOLBAR)
            button.set_tooltip_text("Pausar actualización de la tabla")
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

        current_label = Gtk.MenuItem(label=f"Prioridad actual: {current_nice if current_nice is not None else '?'}")
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
            self._show_error("El proceso ya no existe.")
        except psutil.AccessDenied:
            self._show_error("Permiso denegado para esa acción sobre ese proceso.")

    def _action_kill_confirm(self, pid):
        dialog = Gtk.MessageDialog(transient_for=self, message_type=Gtk.MessageType.WARNING,
                                    buttons=Gtk.ButtonsType.YES_NO,
                                    text=f"¿Matar el proceso PID {pid} con SIGKILL?")
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
            self._show_error("El proceso ya no existe.")
        except psutil.AccessDenied:
            self._show_error("Permiso denegado para cambiar la prioridad de ese proceso.")

    def _action_custom_priority(self, pid, current_value=0):
        dialog = Gtk.Dialog(title="Prioridad personalizada", transient_for=self)
        dialog.add_buttons("Cancelar", Gtk.ResponseType.CANCEL, "Aplicar", Gtk.ResponseType.OK)
        content = dialog.get_content_area()
        content.set_border_width(12)
        content.set_spacing(6)
        content.add(Gtk.Label(label=f"Nice value (-20 a 19). Actual: {current_value if current_value is not None else '?'}"))
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
            self._show_error("Permiso denegado o proceso inexistente.")
            return
        except AttributeError:
            self._show_error("cpu_affinity() no está soportado en este sistema.")
            return

        core_count = psutil.cpu_count(logical=True) or 1

        dialog = Gtk.Dialog(title=f"CPU Affinity - PID {pid}", transient_for=self)
        dialog.add_buttons("Cancelar", Gtk.ResponseType.CANCEL, "Aplicar", Gtk.ResponseType.OK)
        content = dialog.get_content_area()
        content.set_border_width(12)
        content.set_spacing(8)
        content.add(Gtk.Label(label="Núcleos permitidos:", xalign=0))

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
        select_all = Gtk.Button(label="Todos")
        select_all.connect("clicked", lambda w: [c.set_active(True) for c in checks])
        select_none = Gtk.Button(label="Ninguno")
        select_none.connect("clicked", lambda w: [c.set_active(False) for c in checks])
        btn_box.pack_start(select_all, False, False, 0)
        btn_box.pack_start(select_none, False, False, 0)
        content.add(btn_box)

        dialog.show_all()
        response = dialog.run()
        if response == Gtk.ResponseType.OK:
            selected = [i for i, c in enumerate(checks) if c.get_active()]
            if not selected:
                self._show_error("Tenés que dejar al menos un núcleo seleccionado.")
            else:
                try:
                    proc.cpu_affinity(selected)
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    self._show_error("Permiso denegado para cambiar la afinidad de ese proceso.")
        dialog.destroy()

    def _action_open_folder(self, pid):
        try:
            exe = psutil.Process(pid).exe()
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            self._show_error("No se pudo obtener la ruta del ejecutable "
                              "(permiso denegado o es un hilo del kernel sin exe asociado).")
            return
        if not exe:
            self._show_error("Ese proceso no tiene una ruta de ejecutable asociada.")
            return
        folder = os.path.dirname(exe)
        try:
            subprocess.Popen(["xdg-open", folder])
        except FileNotFoundError:
            self._show_error("No se encontró 'xdg-open'. Instalalo con: sudo apt install xdg-utils")

    def _action_highlight_color(self, pid, proc_name):
        dialog = Gtk.ColorChooserDialog(title=f"Color para \"{proc_name}\"", transient_for=self)
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
            self._show_error("El proceso ya no existe.")
            return

        dialog = Gtk.Dialog(title=f"Propiedades - PID {pid}", transient_for=self)
        dialog.add_buttons("Cerrar", Gtk.ResponseType.CLOSE)
        dialog.set_default_size(440, 340)
        content = dialog.get_content_area()
        content.set_border_width(16)
        content.get_style_context().add_class("props-dialog")

        grid = Gtk.Grid(row_spacing=6, column_spacing=16)
        fields = [
            ("PID", str(pid)), ("Nombre", name), ("Estado", status), ("Usuario", user),
            ("Ejecutable", exe), ("Directorio", cwd), ("Comando", cmdline),
            ("Hilos", str(threads)), ("Iniciado", created), ("CPU Affinity", affinity),
            ("Archivos abiertos", str(open_files)), ("Conexiones", str(conns)),
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
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=24)
        box.set_margin_start(24)
        box.set_margin_end(24)
        box.set_margin_top(16)
        box.set_margin_bottom(24)

        self.pie_graph = PieGraph()
        self.pie_graph.set_hexpand(True)
        self.pie_graph.set_vexpand(True)
        box.pack_start(self.pie_graph, True, True, 0)

        legend_scroller = Gtk.ScrolledWindow()
        legend_scroller.set_size_request(300, -1)
        legend_scroller.set_vexpand(True)
        self.pie_legend_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.pie_legend_box.set_margin_top(4)
        legend_scroller.add(self.pie_legend_box)
        box.pack_start(legend_scroller, False, False, 0)

        return box

    def _apply_pie(self, rows):
        """'Overall' consumption = CPU% + memory% of total RAM, blended
        50/50 — both are already 0-100 scale, so a plain sum is a
        reasonable single 'how much of the machine is this using' score.
        Reuses the SAME row data the Processes tab fetches; no separate
        process scan just for this chart."""
        total_mem = psutil.virtual_memory().total
        scored = []
        for r in rows:
            mem_pct = (r["mem"] / total_mem * 100) if total_mem else 0.0
            score = r["cpu"] + mem_pct
            if score > 0:
                scored.append((r["name"], score))

        scored.sort(key=lambda t: t[1], reverse=True)
        top = scored[:PIE_TOP_N]
        rest = scored[PIE_TOP_N:]
        others_total = sum(s for _, s in rest)

        slices = list(top)
        if others_total > 0.05:
            slices.append((f"Otros ({len(rest)})", others_total))

        self.pie_graph.set_data(slices)
        self._update_pie_legend(slices)

    def _update_pie_legend(self, slices):
        for child in self.pie_legend_box.get_children():
            self.pie_legend_box.remove(child)

        total = sum(v for _, v in slices) or 1.0
        for i, (name, value) in enumerate(slices):
            hex_color, _ = PIE_PALETTE[i % len(PIE_PALETTE)]

            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            row.pack_start(self._make_color_chip(hex_color), False, False, 0)

            label = Gtk.Label(label=f"{name}  —  {value / total * 100:.1f}%", xalign=0)
            label.get_style_context().add_class("props-value")
            row.pack_start(label, True, True, 0)

            self.pie_legend_box.pack_start(row, False, False, 0)

        self.pie_legend_box.show_all()

    # ------------------------------------------------------------ RESOURCES

    def _build_resources_tab(self):
        outer = Gtk.ScrolledWindow()
        outer.set_vexpand(True)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        box.set_margin_start(24)
        box.set_margin_end(24)
        box.set_margin_top(12)
        box.set_margin_bottom(24)
        outer.add(box)

        box.pack_start(self._section_label("CPU"), False, False, 0)
        core_count = psutil.cpu_count(logical=True) or 1
        self.core_bars = []
        cores_grid = Gtk.Grid(row_spacing=6, column_spacing=16)
        cols = 2
        for i in range(core_count):
            lbl = Gtk.Label(label=f"CORE {i}", xalign=0)
            lbl.get_style_context().add_class("bar-label")
            bar = Gtk.ProgressBar()
            bar.get_style_context().add_class("cpu-bar")
            bar.set_hexpand(True)
            bar.set_show_text(True)
            r, c = divmod(i, cols)
            cores_grid.attach(lbl, c * 2, r, 1, 1)
            cores_grid.attach(bar, c * 2 + 1, r, 1, 1)
            self.core_bars.append(bar)
        box.pack_start(cores_grid, False, False, 0)

        box.pack_start(self._section_label("CPU HISTORY"), False, False, 0)
        self.cpu_history = HistoryGraph(
            series=[{"color": (0.545, 0.361, 0.965), "data": deque(maxlen=HISTORY_LEN)}],
            y_max=100.0,
        )
        box.pack_start(self.cpu_history, False, False, 0)

        box.pack_start(self._section_label("MEMORY"), False, False, 0)
        self.ram_bar = Gtk.ProgressBar()
        self.ram_bar.get_style_context().add_class("ram-bar")
        self.ram_bar.set_show_text(True)
        box.pack_start(self.ram_bar, False, False, 0)

        box.pack_start(self._section_label("SWAP"), False, False, 0)
        self.swap_bar = Gtk.ProgressBar()
        self.swap_bar.get_style_context().add_class("swap-bar")
        self.swap_bar.set_show_text(True)
        box.pack_start(self.swap_bar, False, False, 0)

        box.pack_start(self._section_label("MEMORY & SWAP HISTORY"), False, False, 0)
        self.mem_history = HistoryGraph(
            series=[
                {"color": (0.655, 0.545, 0.980), "data": deque(maxlen=HISTORY_LEN)},
                {"color": (0.941, 0.533, 0.243), "data": deque(maxlen=HISTORY_LEN)},
            ],
            y_max=100.0,
        )
        box.pack_start(self.mem_history, False, False, 0)

        net_header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=16)
        net_header.pack_start(self._section_label("NETWORK"), False, False, 0)
        self.net_recv_label = Gtk.Label(label="↓ 0.0B/s")
        self.net_recv_label.get_style_context().add_class("net-recv-label")
        self.net_sent_label = Gtk.Label(label="↑ 0.0B/s")
        self.net_sent_label.get_style_context().add_class("net-sent-label")
        net_header.pack_end(self.net_sent_label, False, False, 0)
        net_header.pack_end(self.net_recv_label, False, False, 0)
        box.pack_start(net_header, False, False, 0)

        self.net_history = HistoryGraph(
            series=[
                {"color": (0.545, 0.361, 0.965), "data": deque(maxlen=HISTORY_LEN)},
                {"color": (0.957, 0.447, 0.714), "data": deque(maxlen=HISTORY_LEN)},
            ],
            auto_scale=True,
        )
        box.pack_start(self.net_history, False, False, 0)

        return outer

    def _section_label(self, text):
        lbl = Gtk.Label(label=text, xalign=0)
        lbl.get_style_context().add_class("section-label")
        lbl.set_margin_top(6)
        return lbl

    def _refresh_resources(self):
        if self.active_tab != "resources":
            return True

        per_core = psutil.cpu_percent(percpu=True)
        for bar, pct in zip(self.core_bars, per_core):
            bar.set_fraction(pct / 100.0)
            bar.set_text(f"{pct:.0f}%")

        overall_cpu = sum(per_core) / len(per_core) if per_core else 0.0
        self.cpu_history.push([overall_cpu])

        vm = psutil.virtual_memory()
        self.ram_bar.set_fraction(vm.percent / 100.0)
        self.ram_bar.set_text(f"{format_bytes(vm.used)} / {format_bytes(vm.total)} ({vm.percent:.0f}%)")

        sm = psutil.swap_memory()
        self.swap_bar.set_fraction((sm.percent / 100.0) if sm.total else 0.0)
        self.swap_bar.set_text(
            f"{format_bytes(sm.used)} / {format_bytes(sm.total)} ({sm.percent:.0f}%)" if sm.total else "No swap"
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
        self.net_recv_label.set_text(f"↓ {format_rate(recv_rate)}")
        self.net_sent_label.set_text(f"↑ {format_rate(sent_rate)}")

        return True

    # ---------------------------------------------------------- FILESYSTEMS

    def _build_filesystems_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_margin_start(24)
        box.set_margin_end(24)
        box.set_margin_top(12)

        self.fs_store = Gtk.ListStore(str, str, str, str, str, str, int)
        self.fs_view = Gtk.TreeView(model=self.fs_store)
        self.fs_view.get_style_context().add_class("data-table")

        titles = ["DEVICE", "MOUNTPOINT", "TYPE", "TOTAL", "USED", "FREE"]
        for i, title in enumerate(titles):
            renderer = Gtk.CellRendererText(xalign=0.0 if i < 2 else 1.0)
            col = Gtk.TreeViewColumn(title, renderer, text=i)
            col.set_resizable(True)
            col.set_expand(i == 1)
            self.fs_view.append_column(col)

        pct_renderer = Gtk.CellRendererProgress()
        pct_col = Gtk.TreeViewColumn("USED %", pct_renderer, value=6)
        pct_col.set_min_width(140)
        self.fs_view.append_column(pct_col)

        scroller = Gtk.ScrolledWindow()
        scroller.set_vexpand(True)
        scroller.add(self.fs_view)
        box.pack_start(scroller, True, True, 0)

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

    # -------------------------------------------------------------- THEMES

    def _build_themes_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        box.set_margin_start(24)
        box.set_margin_end(24)
        box.set_margin_top(12)

        box.pack_start(self._section_label("SELECCIONÁ UN TEMA"), False, False, 0)

        self.theme_radios = {}
        group = None
        for theme in THEMES:
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14)
            row.set_margin_top(4)
            row.set_margin_bottom(4)

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

            chips = Gtk.Box(spacing=6)
            for hex_color in theme["colors"]:
                chips.pack_start(self._make_color_chip(hex_color), False, False, 0)
            row.pack_start(chips, False, False, 0)

            # clicking anywhere on the row selects the theme, not just the radio dot
            event_box = Gtk.EventBox()
            event_box.add(row)
            theme_id = theme["id"]
            event_box.connect("button-press-event", lambda w, e, tid=theme_id: self.theme_radios[tid].set_active(True))
            radio.connect("toggled", self._on_theme_radio_toggled, theme_id)

            box.pack_start(event_box, False, False, 0)

        return box

    def _make_color_chip(self, hex_color):
        """Small color swatch that always shows ITS OWN theme's color,
        regardless of which theme is currently active — done with a
        provider scoped to this one widget instead of the app-wide CSS."""
        chip = Gtk.Box()
        chip.set_size_request(22, 22)
        provider = Gtk.CssProvider()
        css = (f"box {{ background-color: {hex_color}; border-radius: 4px; "
               f"border: 1px solid rgba(128,128,128,0.45); }}").encode()
        provider.load_from_data(css)
        chip.get_style_context().add_provider(provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        return chip

    def _on_theme_radio_toggled(self, widget, theme_id):
        if widget.get_active():
            self._apply_theme(theme_id)


def main():
    win = SystemMonitorWindow()
    win.connect("destroy", Gtk.main_quit)
    win.show_all()
    Gtk.main()


if __name__ == "__main__":
    main()
