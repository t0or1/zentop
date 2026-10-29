/* main.vala -- Phase 2: full Processes tab (context menu, TREE VIEW,
 * pin/highlight persistence). Other 4 tabs still placeholders. */

const string APP_TITLE = "zentop";
const string PIN_MARKER = "\xF0\x9F\x93\x8C "; // pin emoji, UTF-8 bytes

string format_bytes(int64 n) {
    if (n < 0) return "-";
    double v = (double) n;
    string[] units = {"B", "KB", "MB", "GB", "TB"};
    foreach (var unit in units) {
        if (v < 1024.0) return "%.1f%s".printf(v, unit);
        v /= 1024.0;
    }
    return "%.1fPB".printf(v);
}

string format_rate(double n) {
    if (n < 0) return "-";
    return format_bytes((int64) n) + "/s";
}

string format_duration(double seconds) {
    int s = (int) seconds;
    int h = s / 3600, m = (s % 3600) / 60, sec = s % 60;
    if (h > 0) return "%d:%02d:%02d".printf(h, m, sec);
    return "%d:%02d".printf(m, sec);
}

string format_started(int64 epoch) {
    if (epoch <= 0) return "-";
    var dt = new DateTime.from_unix_local(epoch);
    var now = new DateTime.now_local();
    if (dt.get_year() == now.get_year() && dt.get_day_of_year() == now.get_day_of_year())
        return dt.format("%H:%M:%S");
    return dt.format("%b %d");
}

string contrast_color(string hex) {
    Gdk.RGBA rgba = Gdk.RGBA();
    if (!rgba.parse(hex)) return "#FFFFFF";
    double lum = 0.299 * rgba.red + 0.587 * rgba.green + 0.114 * rgba.blue;
    return lum > 0.6 ? "#000000" : "#FFFFFF";
}

public class ZentopWindow : Gtk.ApplicationWindow {
    enum Col {
        PID, PROCESS, USER, CPU, CPUID, MEMORY, DISKREADTOTAL, DISKWRITETOTAL,
        DISKREAD, DISKWRITE, PRIORITY, STATUS, STARTED, CPUTIME, BG, FG, N_COLUMNS
    }

    private ProcessCache process_cache = new ProcessCache();
    private ProcessConfig process_config = new ProcessConfig();

    private Gtk.ListStore flat_store;
    private Gtk.TreeStore tree_store;
    private Gtk.TreeModelFilter process_filter;
    private Gtk.TreeView process_view;
    private Gtk.SearchEntry search_entry;
    private Gtk.ComboBoxText filter_combo;

    private Gee.HashMap<int, Gtk.TreeIter?> pid_iters = new Gee.HashMap<int, Gtk.TreeIter?>();
    private Gee.HashMap<int, string> pid_signatures = new Gee.HashMap<int, string>();
    private Gee.HashMap<int, ProcessRow> current_rows = new Gee.HashMap<int, ProcessRow>();

    private string search_text = "";
    private string filter_mode = "all"; // all | mine | active
    private int sort_column = (int) Col.CPU;
    private bool sort_reverse = true;
    private bool tree_mode = false;
    private bool paused = false;
    private bool refresh_in_flight = false;
    private string active_tab = "processes";
    private Gtk.Image pause_icon;
    private string current_user;

    public ZentopWindow(Gtk.Application app) {
        Object(application: app, title: APP_TITLE, default_width: 1440, default_height: 900);
        current_user = Environment.get_user_name();
        load_css();
        build_ui();
        GLib.Timeout.add(2000, on_refresh_tick);
    }

    private void load_css() {
        var provider = new Gtk.CssProvider();
        string path = "themes/default.css";
        try {
            provider.load_from_path(path);
            Gtk.StyleContext.add_provider_for_screen(
                Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        } catch (Error e) {
            stderr.printf("Could not load theme CSS from %s: %s\n", path, e.message);
        }
    }

    private void build_ui() {
        var root = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        root.get_style_context().add_class("root-bg");
        add(root);

        var title = new Gtk.Label(APP_TITLE.up());
        title.get_style_context().add_class("title-label");
        title.margin_top = 24;
        title.margin_bottom = 16;
        root.pack_start(title, false, false, 0);

        var stack = new Gtk.Stack();
        stack.transition_type = Gtk.StackTransitionType.CROSSFADE;

        var switcher = new Gtk.StackSwitcher();
        switcher.stack = stack;
        switcher.halign = Gtk.Align.CENTER;
        switcher.margin_bottom = 20;
        root.pack_start(switcher, false, false, 0);

        stack.add_titled(build_processes_tab(), "processes", "PROCESSES");
        stack.add_titled(placeholder_tab("Resources -- coming in a later phase"), "resources", "RESOURCES");
        stack.add_titled(placeholder_tab("Pie Graph -- coming in a later phase"), "piegraph", "PIE GRAPH");
        stack.add_titled(placeholder_tab("File Systems -- coming in a later phase"), "filesystems", "FILE SYSTEMS");
        stack.add_titled(placeholder_tab("Themes -- coming in a later phase"), "themes", "THEMES");

        stack.notify["visible-child-name"].connect(() => {
            active_tab = stack.visible_child_name;
            if (active_tab == "processes") refresh_processes();
        });

        root.pack_start(stack, true, true, 0);
        show_all();
    }

    private Gtk.Widget placeholder_tab(string text) {
        var lbl = new Gtk.Label(text);
        lbl.get_style_context().add_class("bar-label");
        return lbl;
    }

    private Gtk.Widget build_processes_tab() {
        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 8);
        box.margin_start = 24;
        box.margin_end = 24;

        var toolbar = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);

        filter_combo = new Gtk.ComboBoxText();
        filter_combo.append("all", "All Processes");
        filter_combo.append("mine", "My Processes");
        filter_combo.append("active", "Active Processes");
        filter_combo.active_id = "all";
        filter_combo.get_style_context().add_class("tree-toggle");
        filter_combo.changed.connect(() => { filter_mode = filter_combo.active_id ?? "all"; });
        toolbar.pack_start(filter_combo, false, false, 0);

        var tree_toggle = new Gtk.ToggleButton.with_label("TREE VIEW");
        tree_toggle.get_style_context().add_class("tree-toggle");
        tree_toggle.toggled.connect(() => {
            tree_mode = tree_toggle.active;
            search_entry.sensitive = !tree_mode;
            if (tree_mode) {
                search_entry.text = "";
                search_text = "";
                process_filter = new Gtk.TreeModelFilter(tree_store, null);
            } else {
                process_filter = new Gtk.TreeModelFilter(flat_store, null);
            }
            wire_filter_func();
            process_view.model = process_filter;
            refresh_processes();
        });
        toolbar.pack_start(tree_toggle, false, false, 0);

        search_entry = new Gtk.SearchEntry();
        search_entry.placeholder_text = "Filter by process name...";
        search_entry.get_style_context().add_class("search-entry");
        search_entry.search_changed.connect(() => {
            search_text = search_entry.text.strip().down();
            process_filter.refilter();
        });
        toolbar.pack_start(search_entry, true, true, 0);

        var pause_toggle = new Gtk.ToggleButton();
        pause_toggle.relief = Gtk.ReliefStyle.NONE;
        pause_toggle.tooltip_text = "Pause table updates";
        pause_icon = new Gtk.Image.from_icon_name("media-playback-pause-symbolic", Gtk.IconSize.SMALL_TOOLBAR);
        pause_toggle.add(pause_icon);
        pause_toggle.toggled.connect(() => {
            paused = pause_toggle.active;
            pause_icon.set_from_icon_name(
                paused ? "media-playback-start-symbolic" : "media-playback-pause-symbolic",
                Gtk.IconSize.SMALL_TOOLBAR);
            if (!paused) refresh_processes();
        });
        toolbar.pack_start(pause_toggle, false, false, 0);

        box.pack_start(toolbar, false, false, 4);

        Type[] types = new Type[(int) Col.N_COLUMNS];
        types[(int) Col.PID] = typeof(int);
        for (int i = 1; i < (int) Col.N_COLUMNS; i++) types[i] = typeof(string);
        flat_store = new Gtk.ListStore.newv(types);
        tree_store = new Gtk.TreeStore.newv(types);
        process_filter = new Gtk.TreeModelFilter(flat_store, null);
        wire_filter_func();

        process_view = new Gtk.TreeView.with_model(process_filter);
        process_view.get_style_context().add_class("data-table");
        process_view.button_press_event.connect(on_button_press);

        string[] titles = {
            "PROCESS", "USER", "CPU", "CPUID", "MEMORY", "DISKREADTOTAL", "DISKWRITETOTAL",
            "DISKREAD", "DISKWRITE", "PRIORITY", "STATUS", "STARTED", "CPU TIME"
        };
        for (int i = 0; i < titles.length; i++) {
            int col_index = i + 1;
            var renderer = new Gtk.CellRendererText();
            renderer.xalign = (col_index == (int) Col.PROCESS || col_index == (int) Col.USER || col_index == (int) Col.STATUS) ? 0.0f : 1.0f;
            var col = new Gtk.TreeViewColumn();
            col.title = titles[i];
            col.pack_start(renderer, true);
            col.add_attribute(renderer, "text", col_index);
            col.add_attribute(renderer, "background", (int) Col.BG);
            col.add_attribute(renderer, "foreground", (int) Col.FG);
            col.resizable = true;
            col.expand = (col_index == (int) Col.PROCESS);
            col.clickable = true;
            int captured_index = col_index;
            col.clicked.connect(() => { on_column_clicked(captured_index); });
            process_view.append_column(col);
        }

        var scroller = new Gtk.ScrolledWindow(null, null);
        scroller.vexpand = true;
        scroller.add(process_view);
        box.pack_start(scroller, true, true, 0);

        return box;
    }

    private void wire_filter_func() {
        process_filter.set_visible_func((model, iter) => {
            if (search_text == "") return true;
            GLib.Value v;
            model.get_value(iter, (int) Col.PROCESS, out v);
            string name = ((string) v) ?? "";
            return name.down().contains(search_text);
        });
    }

    // ---------------------------------------------------- sort/refresh

    private void on_column_clicked(int col_index) {
        if (sort_column == col_index) sort_reverse = !sort_reverse;
        else { sort_column = col_index; sort_reverse = true; }
        refresh_processes();
    }

    private bool on_refresh_tick() {
        refresh_processes();
        return true;
    }

    private void refresh_processes() {
        if (active_tab != "processes") return;
        if (paused) return;
        if (refresh_in_flight) return;
        refresh_in_flight = true;

        new Thread<void*>("proc-gather", () => {
            var rows = process_cache.refresh();
            Idle.add(() => {
                apply_rows(rows);
                return false;
            });
            return null;
        });
    }

    private static double sort_key(ProcessRow r, int col_index) {
        switch (col_index) {
            case (int) Col.CPU: return r.cpu;
            case (int) Col.MEMORY: return (double) r.mem;
            case (int) Col.DISKREADTOTAL: return (double) (r.read_total > 0 ? r.read_total : 0);
            case (int) Col.DISKWRITETOTAL: return (double) (r.write_total > 0 ? r.write_total : 0);
            case (int) Col.DISKREAD: return r.read_rate > 0 ? r.read_rate : 0;
            case (int) Col.DISKWRITE: return r.write_rate > 0 ? r.write_rate : 0;
            case (int) Col.PRIORITY: return (double) r.priority;
            case (int) Col.CPUTIME: return r.cputime;
            case (int) Col.CPUID: return (double) r.cpuid;
            default: return 0;
        }
    }

    /* Pins always go first. Partition once instead of sorting the whole
     * list twice -- pins are rare, so this sorts a tiny group and one big
     * group, instead of two full-size sorts. Same idea as the Python
     * version's _ordered_pids, and it still pays off here: this is
     * regular comparison work, not something the language switch makes
     * free. */
    private int[] ordered_pids(Gee.Collection<int> pids, Gee.HashMap<int, ProcessRow> by_pid) {
        var pinned = new Gee.ArrayList<int>();
        var unpinned = new Gee.ArrayList<int>();
        foreach (var pid in pids) {
            if (by_pid[pid].pinned) pinned.add(pid); else unpinned.add(pid);
        }
        CompareDataFunc<int> cmp = (a, b) => {
            double ka = sort_key(by_pid[a], sort_column);
            double kb = sort_key(by_pid[b], sort_column);
            int c = (ka < kb) ? -1 : (ka > kb ? 1 : 0);
            return sort_reverse ? -c : c;
        };
        pinned.sort(cmp);
        unpinned.sort(cmp);
        var result = new int[pinned.size + unpinned.size];
        int i = 0;
        foreach (var p in pinned) result[i++] = p;
        foreach (var p in unpinned) result[i++] = p;
        return result;
    }

    private void apply_rows(owned Gee.ArrayList<ProcessRow> rows) {
        refresh_in_flight = false;

        string my_user = current_user;
        if (filter_mode == "mine") {
            var filtered = new Gee.ArrayList<ProcessRow>();
            foreach (var r in rows) if (r.user == my_user) filtered.add(r);
            rows = filtered;
        } else if (filter_mode == "active") {
            var filtered = new Gee.ArrayList<ProcessRow>();
            foreach (var r in rows) if (r.status == "running" || r.status == "sleeping") filtered.add(r);
            rows = filtered;
        }

        var rows_by_pid = new Gee.HashMap<int, ProcessRow>();
        foreach (var r in rows) {
            r.pinned = process_config.is_pinned(r.name);
            r.highlight_color = process_config.highlight_color(r.name);
            rows_by_pid[r.pid] = r;
        }
        current_rows = rows_by_pid;

        if (tree_mode) apply_tree(rows_by_pid);
        else apply_flat(rows_by_pid);
    }

    private string row_signature(ProcessRow r) {
        return "%s|%s|%.1f|%d|%llu|%lld|%lld|%.0f|%.0f|%d|%s|%d|%.0f|%s|%s".printf(
            r.name, r.user, r.cpu, r.cpuid, r.mem, r.read_total, r.write_total,
            r.read_rate, r.write_rate, r.priority, r.status, (int) r.create_time,
            r.cputime, r.pinned.to_string(), r.highlight_color ?? "");
    }

    private void set_row_values(Gtk.TreeStore? store_or_null, Gtk.ListStore? list_or_null, Gtk.TreeIter it, ProcessRow r) {
        string? bg = r.highlight_color;
        string? fg = bg != null ? contrast_color(bg) : null;
        string display_name = r.pinned ? PIN_MARKER + r.name : r.name;
        if (list_or_null != null) {
            list_or_null.set(it,
                (int) Col.PID, r.pid, (int) Col.PROCESS, display_name, (int) Col.USER, r.user,
                (int) Col.CPU, "%.1f%%".printf(r.cpu), (int) Col.CPUID, r.cpuid >= 0 ? r.cpuid.to_string() : "-",
                (int) Col.MEMORY, format_bytes((int64) r.mem), (int) Col.DISKREADTOTAL, format_bytes(r.read_total),
                (int) Col.DISKWRITETOTAL, format_bytes(r.write_total), (int) Col.DISKREAD, format_rate(r.read_rate),
                (int) Col.DISKWRITE, format_rate(r.write_rate), (int) Col.PRIORITY, r.priority.to_string(),
                (int) Col.STATUS, r.status, (int) Col.STARTED, format_started(r.create_time),
                (int) Col.CPUTIME, format_duration(r.cputime), (int) Col.BG, bg, (int) Col.FG, fg, -1);
        } else {
            store_or_null.set(it,
                (int) Col.PID, r.pid, (int) Col.PROCESS, display_name, (int) Col.USER, r.user,
                (int) Col.CPU, "%.1f%%".printf(r.cpu), (int) Col.CPUID, r.cpuid >= 0 ? r.cpuid.to_string() : "-",
                (int) Col.MEMORY, format_bytes((int64) r.mem), (int) Col.DISKREADTOTAL, format_bytes(r.read_total),
                (int) Col.DISKWRITETOTAL, format_bytes(r.write_total), (int) Col.DISKREAD, format_rate(r.read_rate),
                (int) Col.DISKWRITE, format_rate(r.write_rate), (int) Col.PRIORITY, r.priority.to_string(),
                (int) Col.STATUS, r.status, (int) Col.STARTED, format_started(r.create_time),
                (int) Col.CPUTIME, format_duration(r.cputime), (int) Col.BG, bg, (int) Col.FG, fg, -1);
        }
    }

    private void apply_flat(Gee.HashMap<int, ProcessRow> rows_by_pid) {
        var stale = new Gee.ArrayList<int>();
        foreach (var pid in pid_iters.keys) if (!rows_by_pid.has_key(pid)) stale.add(pid);
        foreach (var pid in stale) {
            Gtk.TreeIter it = pid_iters[pid];
            flat_store.remove(ref it);
            pid_iters.unset(pid);
            pid_signatures.unset(pid);
        }

        foreach (var r in rows_by_pid.values) {
            string sig = row_signature(r);
            if (pid_iters.has_key(r.pid)) {
                // Only touch the store when the row actually changed -- a
                // write fires row-changed, which makes the TreeModelFilter
                // re-run visible_func for that row. This still matters in
                // native code: it's GTK's own signal/redraw machinery doing
                // the work, not something the language switch speeds up.
                if (pid_signatures[r.pid] != sig) {
                    set_row_values(null, flat_store, pid_iters[r.pid], r);
                    pid_signatures[r.pid] = sig;
                }
            } else {
                Gtk.TreeIter it;
                flat_store.append(out it);
                pid_iters[r.pid] = it;
                set_row_values(null, flat_store, it, r);
                pid_signatures[r.pid] = sig;
            }
        }

        var desired = ordered_pids(rows_by_pid.keys, rows_by_pid);
        int[] new_order = new int[desired.length];
        for (int i = 0; i < desired.length; i++) {
            var path = flat_store.get_path(pid_iters[desired[i]]);
            new_order[i] = path.get_indices()[0];
        }
        if (new_order.length > 0) flat_store.reorder(new_order);
    }

    private void apply_tree(Gee.HashMap<int, ProcessRow> rows_by_pid) {
        // Full rebuild each tick -- tree mode is occasional-use, and
        // reparenting-aware diffing isn't worth the complexity here either,
        // same call the Python version made.
        tree_store.clear();

        var children_map = new Gee.HashMap<int, Gee.ArrayList<int>>();
        var roots = new Gee.ArrayList<int>();
        foreach (var pid in rows_by_pid.keys) {
            int ppid = rows_by_pid[pid].ppid;
            if (rows_by_pid.has_key(ppid) && ppid != pid) {
                if (!children_map.has_key(ppid)) children_map[ppid] = new Gee.ArrayList<int>();
                children_map[ppid].add(pid);
            } else {
                roots.add(pid);
            }
        }

        insert_tree_nodes(null, ordered_pids(roots, rows_by_pid), rows_by_pid, children_map);
    }

    private void insert_tree_nodes(Gtk.TreeIter? parent, int[] pids, Gee.HashMap<int, ProcessRow> rows_by_pid, Gee.HashMap<int, Gee.ArrayList<int>> children_map) {
        foreach (var pid in pids) {
            Gtk.TreeIter it;
            tree_store.append(out it, parent);
            set_row_values(tree_store, null, it, rows_by_pid[pid]);
            if (children_map.has_key(pid)) {
                insert_tree_nodes(it, ordered_pids(children_map[pid], rows_by_pid), rows_by_pid, children_map);
            }
        }
    }

    // ---------------------------------------------------- context menu

    private bool on_button_press(Gdk.EventButton event) {
        if (event.button != 3) return false;
        Gtk.TreePath path;
        if (process_view.get_path_at_pos((int) event.x, (int) event.y, out path, null, null, null)) {
            process_view.get_selection().unselect_all();
            process_view.get_selection().select_path(path);
            show_context_menu(event);
        }
        return true;
    }

    private int? selected_pid() {
        Gtk.TreeIter iter;
        Gtk.TreeModel model;
        if (!process_view.get_selection().get_selected(out model, out iter)) return null;
        GLib.Value v;
        model.get_value(iter, (int) Col.PID, out v);
        return (int) v;
    }

    private void show_context_menu(Gdk.EventButton event) {
        int? pid_n = selected_pid();
        if (pid_n == null) return;
        int pid = pid_n;
        if (!current_rows.has_key(pid)) return;
        var row = current_rows[pid];
        string proc_name = row.name;

        var menu = new Gtk.Menu();

        var pin_item = new Gtk.MenuItem.with_label(row.pinned ? "Unpin" : "Pin to Top");
        pin_item.activate.connect(() => { process_config.toggle_pin(proc_name); refresh_processes(); });
        menu.append(pin_item);
        menu.append(new Gtk.SeparatorMenuItem());

        add_action_item(menu, "End Process", () => action_signal(pid, Posix.Signal.TERM));
        add_action_item(menu, "Kill Process", () => confirm_kill(pid));
        menu.append(new Gtk.SeparatorMenuItem());
        add_action_item(menu, "Stop", () => action_signal(pid, Posix.Signal.STOP));
        add_action_item(menu, "Continue", () => action_signal(pid, Posix.Signal.CONT));
        menu.append(new Gtk.SeparatorMenuItem());

        var priority_item = new Gtk.MenuItem.with_label("Change Priority");
        var priority_menu = new Gtk.Menu();
        int current_nice = get_priority_safe(pid);
        var current_label = new Gtk.MenuItem.with_label("Current priority: %d".printf(current_nice));
        current_label.sensitive = false;
        priority_menu.append(current_label);
        priority_menu.append(new Gtk.SeparatorMenuItem());

        string[] preset_labels = {"Very High (-20)", "High (-10)", "Normal (0)", "Low (10)", "Very Low (19)"};
        int[] preset_values = {-20, -10, 0, 10, 19};
        Gtk.RadioMenuItem? group = null;
        var radios = new Gtk.RadioMenuItem[preset_labels.length];
        for (int i = 0; i < preset_labels.length; i++) {
            radios[i] = new Gtk.RadioMenuItem.with_label_from_widget(group, preset_labels[i]);
            group = radios[i];
            priority_menu.append(radios[i]);
        }
        for (int i = 0; i < radios.length; i++) {
            if (preset_values[i] == current_nice) radios[i].active = true;
        }
        for (int i = 0; i < radios.length; i++) {
            int value = preset_values[i];
            radios[i].toggled.connect(() => { if (radios_active(radios[value_index(preset_values, value)])) action_set_priority(pid, value); });
        }
        priority_menu.append(new Gtk.SeparatorMenuItem());
        var custom_item = new Gtk.MenuItem.with_label("Custom...");
        custom_item.activate.connect(() => custom_priority_dialog(pid, current_nice));
        priority_menu.append(custom_item);
        priority_item.submenu = priority_menu;
        menu.append(priority_item);

        add_action_item(menu, "CPU Affinity...", () => cpu_affinity_dialog(pid));
        menu.append(new Gtk.SeparatorMenuItem());
        add_action_item(menu, "Open File Location", () => open_file_location(pid));
        menu.append(new Gtk.SeparatorMenuItem());
        add_action_item(menu, "Highlight Color...", () => highlight_color_dialog(pid, proc_name));
        if (process_config.highlight_color(proc_name) != null) {
            add_action_item(menu, "Remove Highlight", () => { process_config.remove_highlight(proc_name); refresh_processes(); });
        }
        menu.append(new Gtk.SeparatorMenuItem());
        add_action_item(menu, "Properties...", () => properties_dialog(pid));

        menu.show_all();
        menu.popup_at_pointer(event);
    }

    private static int value_index(int[] arr, int value) {
        for (int i = 0; i < arr.length; i++) if (arr[i] == value) return i;
        return 0;
    }
    private static bool radios_active(Gtk.RadioMenuItem item) { return item.active; }

    private delegate void ActionFn();

    private void add_action_item(Gtk.Menu menu, string label, owned ActionFn action) {
        var item = new Gtk.MenuItem.with_label(label);
        item.activate.connect(() => action());
        menu.append(item);
    }

    private void show_error(string message) {
        var dialog = new Gtk.MessageDialog(this, Gtk.DialogFlags.MODAL, Gtk.MessageType.ERROR, Gtk.ButtonsType.OK, "%s", message);
        dialog.run();
        dialog.destroy();
    }

    private void action_signal(int pid, int signum) {
        if (Posix.kill(pid, signum) != 0) {
            if (Posix.errno == Posix.ESRCH) show_error("The process does not exist.");
            else if (Posix.errno == Posix.EPERM) show_error("Permission denied for that action on that process.");
            else show_error("Could not signal that process.");
        }
    }

    private void confirm_kill(int pid) {
        var dialog = new Gtk.MessageDialog(this, Gtk.DialogFlags.MODAL, Gtk.MessageType.WARNING, Gtk.ButtonsType.YES_NO,
            "Kill process PID %d with SIGKILL?", pid);
        var response = dialog.run();
        dialog.destroy();
        if (response == Gtk.ResponseType.YES) action_signal(pid, Posix.Signal.KILL);
    }

    private int get_priority_safe(int pid) {
        Posix.errno = 0;
        return Posix.getpriority(Posix.PRIO_PROCESS, pid);
    }

    private void action_set_priority(int pid, int value) {
        if (Posix.setpriority(Posix.PRIO_PROCESS, pid, value) != 0) {
            if (Posix.errno == Posix.ESRCH) show_error("The process does not exist.");
            else show_error("Permission denied.");
        }
    }

    private void custom_priority_dialog(int pid, int current_value) {
        var dialog = new Gtk.Dialog.with_buttons("Custom priority", this, Gtk.DialogFlags.MODAL,
            "Cancel", Gtk.ResponseType.CANCEL, "Apply", Gtk.ResponseType.OK);
        var content = dialog.get_content_area();
        content.border_width = 12;
        content.spacing = 6;
        content.add(new Gtk.Label("Nice value (-20 to 19). Current: %d".printf(current_value)));
        var adj = new Gtk.Adjustment(current_value, -20, 19, 1, 1, 0);
        var spin = new Gtk.SpinButton(adj, 1, 0);
        content.add(spin);
        dialog.show_all();
        if (dialog.run() == Gtk.ResponseType.OK) action_set_priority(pid, spin.get_value_as_int());
        dialog.destroy();
    }

    private void cpu_affinity_dialog(int pid) {
        int core_count = (int) GLib.get_num_processors();
        var current = Native.get_affinity(pid, core_count);
        var current_set = new Gee.HashSet<int>();
        foreach (var c in current) current_set.add(c);

        var dialog = new Gtk.Dialog.with_buttons("CPU Affinity - PID %d".printf(pid), this, Gtk.DialogFlags.MODAL,
            "Cancel", Gtk.ResponseType.CANCEL, "Apply", Gtk.ResponseType.OK);
        var content = dialog.get_content_area();
        content.border_width = 12;
        content.spacing = 8;
        content.add(new Gtk.Label.with_mnemonic("Allowed cores:"));

        var checks = new Gtk.CheckButton[core_count];
        var grid = new Gtk.Grid();
        grid.row_spacing = 4;
        grid.column_spacing = 12;
        int cols = 4;
        for (int i = 0; i < core_count; i++) {
            checks[i] = new Gtk.CheckButton.with_label("CORE %d".printf(i));
            checks[i].active = current_set.contains(i);
            grid.attach(checks[i], i % cols, i / cols, 1, 1);
        }
        content.add(grid);

        var btn_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        var all_btn = new Gtk.Button.with_label("All");
        all_btn.clicked.connect(() => { foreach (var c in checks) c.active = true; });
        var none_btn = new Gtk.Button.with_label("None");
        none_btn.clicked.connect(() => { foreach (var c in checks) c.active = false; });
        btn_box.pack_start(all_btn, false, false, 0);
        btn_box.pack_start(none_btn, false, false, 0);
        content.add(btn_box);

        dialog.show_all();
        if (dialog.run() == Gtk.ResponseType.OK) {
            var selected = new Gee.ArrayList<int>();
            for (int i = 0; i < core_count; i++) if (checks[i].active) selected.add(i);
            if (selected.size == 0) {
                show_error("Leave at least one core selected.");
            } else if (!Native.set_affinity(pid, selected.to_array())) {
                show_error("Permission denied.");
            }
        }
        dialog.destroy();
    }

    private void open_file_location(int pid) {
        string? exe = Native.get_exe_path(pid);
        if (exe == null) {
            show_error("Could not obtain the executable path (permission denied, or it's a kernel thread).");
            return;
        }
        string folder = Path.get_dirname(exe);
        try {
            Process.spawn_command_line_async("xdg-open \"%s\"".printf(folder));
        } catch (SpawnError e) {
            show_error("Could not find 'xdg-open'. Install with: sudo apt install xdg-utils");
        }
    }

    private void highlight_color_dialog(int pid, string proc_name) {
        var dialog = new Gtk.ColorChooserDialog("Color for \"%s\"".printf(proc_name), this);
        string? existing = process_config.highlight_color(proc_name);
        if (existing != null) {
            Gdk.RGBA rgba = Gdk.RGBA();
            if (rgba.parse(existing)) dialog.rgba = rgba;
        }
        if (dialog.run() == Gtk.ResponseType.OK) {
            var rgba = dialog.rgba;
            string hex = "#%02X%02X%02X".printf(
                (int) Math.round(rgba.red * 255), (int) Math.round(rgba.green * 255), (int) Math.round(rgba.blue * 255));
            process_config.set_highlight(proc_name, hex);
            refresh_processes();
        }
        dialog.destroy();
    }

    private void properties_dialog(int pid) {
        string cmdline = "-";
        try {
            string raw;
            FileUtils.get_contents("/proc/%d/cmdline".printf(pid), out raw);
            cmdline = raw.replace("\0", " ").strip();
            if (cmdline == "") cmdline = "-";
        } catch (Error e) {}

        string cwd = "-";
        uint8[] buf = new uint8[4096];
        ssize_t n = Posix.readlink("/proc/%d/cwd".printf(pid), (char[]) buf);
        if (n > 0) cwd = (string) buf[0:n];

        string exe = Native.get_exe_path(pid) ?? "-";

        int open_files = 0;
        try {
            var dir = Dir.open("/proc/%d/fd".printf(pid), 0);
            string? e;
            while ((e = dir.read_name()) != null) open_files++;
        } catch (Error e) { open_files = -1; }

        var affinity_list = Native.get_affinity(pid, (int) GLib.get_num_processors());
        var affinity_strs = new string[affinity_list.length];
        for (int i = 0; i < affinity_list.length; i++) affinity_strs[i] = affinity_list[i].to_string();
        string affinity = string.joinv(",", affinity_strs);

        var row = current_rows.has_key(pid) ? current_rows[pid] : null;

        var dialog = new Gtk.Dialog.with_buttons("Properties - PID %d".printf(pid), this, Gtk.DialogFlags.MODAL,
            "Close", Gtk.ResponseType.CLOSE);
        dialog.set_default_size(440, 340);
        var content = dialog.get_content_area();
        content.border_width = 16;

        var grid = new Gtk.Grid();
        grid.row_spacing = 6;
        grid.column_spacing = 16;
        string[,] fields = {
            {"PID", pid.to_string()},
            {"Name", row != null ? row.name : "-"},
            {"Status", row != null ? row.status : "-"},
            {"User", row != null ? row.user : "-"},
            {"Executable", exe},
            {"Directory", cwd},
            {"Command", cmdline},
            {"Started", row != null ? format_started(row.create_time) : "-"},
            {"CPU Affinity", affinity},
            {"Open files", open_files >= 0 ? open_files.to_string() : "N/A"},
        };
        for (int i = 0; i < fields.length[0]; i++) {
            var lbl = new Gtk.Label(fields[i, 0]);
            lbl.halign = Gtk.Align.START;
            var val = new Gtk.Label(fields[i, 1]);
            val.halign = Gtk.Align.START;
            val.wrap = true;
            val.max_width_chars = 42;
            grid.attach(lbl, 0, i, 1, 1);
            grid.attach(val, 1, i, 1, 1);
        }
        content.add(grid);
        dialog.show_all();
        dialog.run();
        dialog.destroy();
    }
}

int main(string[] args) {
    var app = new Gtk.Application("com.zentop.app", GLib.ApplicationFlags.FLAGS_NONE);
    app.activate.connect(() => {
        var win = new ZentopWindow(app);
        win.present();
    });
    return app.run(args);
}
