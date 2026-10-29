/* process_actions.vala -- the right-click menu on a process and every
 * dialog behind it: signals, priority, CPU affinity, open location,
 * highlight colour and properties. `changed` asks for an immediate refresh
 * after anything that alters what the table shows. */

public class ProcessActions : Object {
    public signal void changed();

    private AppContext ctx;

    public ProcessActions(AppContext ctx) {
        this.ctx = ctx;
    }

    private delegate void Action();

    private static void add_item(Gtk.Menu menu, string label, owned Action action) {
        var item = new Gtk.MenuItem.with_label(label);
        item.activate.connect(() => action());
        menu.append(item);
    }

    public void popup(ProcessRow row, Gdk.EventButton event) {
        int pid = row.pid;
        string name = row.name;
        var cfg = ctx.process_config;
        var menu = new Gtk.Menu();

        add_item(menu, row.pinned ? "Unpin" : "Pin to Top", () => { cfg.toggle_pin(name); changed(); });
        menu.append(new Gtk.SeparatorMenuItem());
        add_item(menu, "End Process", () => send_signal(pid, Posix.Signal.TERM));
        add_item(menu, "Kill Process", () => confirm_kill(pid));
        menu.append(new Gtk.SeparatorMenuItem());
        add_item(menu, "Stop", () => send_signal(pid, Posix.Signal.STOP));
        add_item(menu, "Continue", () => send_signal(pid, Posix.Signal.CONT));
        menu.append(new Gtk.SeparatorMenuItem());
        menu.append(priority_item(pid));
        add_item(menu, "CPU Affinity...", () => affinity_dialog(pid));
        menu.append(new Gtk.SeparatorMenuItem());
        add_item(menu, "Open File Location", () => open_location(pid));
        menu.append(new Gtk.SeparatorMenuItem());
        add_item(menu, "Highlight Color...", () => highlight_dialog(name));
        if (cfg.highlight_color(name) != null)
            add_item(menu, "Remove Highlight", () => { cfg.remove_highlight(name); changed(); });
        menu.append(new Gtk.SeparatorMenuItem());
        add_item(menu, "Properties...", () => properties_dialog(row));

        menu.show_all();
        menu.popup_at_pointer(event);
    }

    // ------------------------------------------------------------- signals

    private void send_signal(int pid, int signum) {
        if (Posix.kill(pid, signum) == 0) { changed(); return; }
        if (Posix.errno == Posix.ESRCH) ctx.show_error("The process does not exist.");
        else if (Posix.errno == Posix.EPERM) ctx.show_error("Permission denied for that action on that process.");
        else ctx.show_error("Could not signal that process.");
    }

    private void confirm_kill(int pid) {
        var d = new Gtk.MessageDialog(ctx.window, Gtk.DialogFlags.MODAL, Gtk.MessageType.WARNING,
                                      Gtk.ButtonsType.YES_NO, "Kill process PID %d with SIGKILL?", pid);
        var response = d.run();
        d.destroy();
        if (response == Gtk.ResponseType.YES) send_signal(pid, Posix.Signal.KILL);
    }

    // ------------------------------------------------------------- priority

    private Gtk.MenuItem priority_item(int pid) {
        Posix.errno = 0;
        int current = Posix.getpriority(Posix.PRIO_PROCESS, pid);
        var item = new Gtk.MenuItem.with_label("Change Priority");
        var sub = new Gtk.Menu();
        var now_label = new Gtk.MenuItem.with_label("Current priority: %d".printf(current));
        now_label.sensitive = false;
        sub.append(now_label);
        sub.append(new Gtk.SeparatorMenuItem());

        string[] labels = {"Very High (-20)", "High (-10)", "Normal (0)", "Low (10)", "Very Low (19)"};
        int[] values = {-20, -10, 0, 10, 19};
        Gtk.RadioMenuItem? group = null;
        for (int i = 0; i < labels.length; i++) {
            var radio = new Gtk.RadioMenuItem.with_label_from_widget(group, labels[i]);
            group = radio;
            int value = values[i];
            radio.active = value == current;          // before connecting: no spurious call
            radio.toggled.connect(() => { if (radio.active && value != current) set_priority(pid, value); });
            sub.append(radio);
        }
        sub.append(new Gtk.SeparatorMenuItem());
        add_item(sub, "Custom...", () => custom_priority(pid, current));
        item.submenu = sub;
        return item;
    }

    private void set_priority(int pid, int value) {
        if (Posix.setpriority(Posix.PRIO_PROCESS, pid, value) == 0) { changed(); return; }
        ctx.show_error(Posix.errno == Posix.ESRCH ? "The process does not exist."
                       : "Permission denied. Raising priority (a lower nice value) needs root.");
    }

    private void custom_priority(int pid, int current) {
        var d = new Gtk.Dialog.with_buttons("Custom priority", ctx.window, Gtk.DialogFlags.MODAL,
            "Cancel", Gtk.ResponseType.CANCEL, "Apply", Gtk.ResponseType.OK);
        var box = d.get_content_area();
        box.border_width = 12;
        box.spacing = 6;
        box.add(new Gtk.Label("Nice value (-20 to 19). Current: %d".printf(current)));
        var spin = new Gtk.SpinButton(new Gtk.Adjustment(current, -20, 19, 1, 1, 0), 1, 0);
        box.add(spin);
        d.show_all();
        if (d.run() == Gtk.ResponseType.OK) set_priority(pid, spin.get_value_as_int());
        d.destroy();
    }

    // ------------------------------------------------------------- affinity

    private void affinity_dialog(int pid) {
        int cores = (int) GLib.get_num_processors();
        var allowed = new Gee.HashSet<int>();
        foreach (var c in Native.get_affinity(pid, cores)) allowed.add(c);

        var d = new Gtk.Dialog.with_buttons("CPU Affinity - PID %d".printf(pid), ctx.window, Gtk.DialogFlags.MODAL,
            "Cancel", Gtk.ResponseType.CANCEL, "Apply", Gtk.ResponseType.OK);
        var box = d.get_content_area();
        box.border_width = 12;
        box.spacing = 8;
        box.add(new Gtk.Label("Allowed cores:"));
        var checks = new Gtk.CheckButton[cores];
        var grid = new Gtk.Grid();
        grid.row_spacing = 4;
        grid.column_spacing = 12;
        for (int i = 0; i < cores; i++) {
            checks[i] = new Gtk.CheckButton.with_label("CORE %d".printf(i));
            checks[i].active = allowed.contains(i);
            grid.attach(checks[i], i % 4, i / 4, 1, 1);
        }
        box.add(grid);
        var buttons = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        var all_btn = new Gtk.Button.with_label("All");
        all_btn.clicked.connect(() => { foreach (var c in checks) c.active = true; });
        var none_btn = new Gtk.Button.with_label("None");
        none_btn.clicked.connect(() => { foreach (var c in checks) c.active = false; });
        buttons.pack_start(all_btn, false, false, 0);
        buttons.pack_start(none_btn, false, false, 0);
        box.add(buttons);
        d.show_all();
        if (d.run() == Gtk.ResponseType.OK) {
            var chosen = new Gee.ArrayList<int>();
            for (int i = 0; i < cores; i++) if (checks[i].active) chosen.add(i);
            if (chosen.size == 0) ctx.show_error("Leave at least one core selected.");
            else if (!Native.set_affinity(pid, chosen.to_array())) ctx.show_error("Permission denied.");
        }
        d.destroy();
    }

    // ------------------------------------------------------------- location / colour

    private void open_location(int pid) {
        string? exe = Native.get_exe_path(pid);
        if (exe == null) {
            ctx.show_error("Could not obtain the executable path (permission denied, or it's a kernel thread).");
            return;
        }
        try {
            Process.spawn_async(null, {"xdg-open", Path.get_dirname(exe)}, null, SpawnFlags.SEARCH_PATH, null, null);
        } catch (SpawnError e) {
            ctx.show_error("Could not find 'xdg-open'. Install with: sudo apt install xdg-utils");
        }
    }

    private void highlight_dialog(string name) {
        var d = new Gtk.ColorChooserDialog("Color for \"%s\"".printf(name), ctx.window);
        string? existing = ctx.process_config.highlight_color(name);
        if (existing != null) {
            Gdk.RGBA c = Gdk.RGBA();
            if (c.parse(existing)) d.rgba = c;
        }
        if (d.run() == Gtk.ResponseType.OK) {
            var c = d.rgba;
            ctx.process_config.set_highlight(name, "#%02X%02X%02X".printf(
                (int) Math.round(c.red * 255), (int) Math.round(c.green * 255), (int) Math.round(c.blue * 255)));
            changed();
        }
        d.destroy();
    }

    // ------------------------------------------------------------- properties

    private void properties_dialog(ProcessRow row) {
        int pid = row.pid;
        string cmdline = "-";
        try {
            uint8[] raw;
            FileUtils.get_data("/proc/%d/cmdline".printf(pid), out raw);
            for (int i = 0; i < raw.length; i++) if (raw[i] == 0) raw[i] = ' ';
            string s = ((string) raw).strip();
            if (s != "") cmdline = s;
        } catch (Error e) {}
        string cwd = "-";
        try { cwd = FileUtils.read_link("/proc/%d/cwd".printf(pid)); } catch (Error e) {}
        int open_files = 0;
        try {
            var dir = Dir.open("/proc/%d/fd".printf(pid), 0);
            while (dir.read_name() != null) open_files++;
        } catch (Error e) { open_files = -1; }
        var cores = Native.get_affinity(pid, (int) GLib.get_num_processors());
        var core_strs = new string[cores.length];
        for (int i = 0; i < cores.length; i++) core_strs[i] = cores[i].to_string();

        string[,] fields = {
            {"PID", pid.to_string()},
            {"Name", row.name},
            {"Status", row.status},
            {"User", row.user},
            {"Executable", Native.get_exe_path(pid) ?? "-"},
            {"Directory", cwd},
            {"Command", cmdline},
            {"Started", row.started},
            {"CPU Affinity", core_strs.length > 0 ? string.joinv(",", core_strs) : "-"},
            {"Open files", open_files >= 0 ? open_files.to_string() : "N/A"}
        };
        var d = new Gtk.Dialog.with_buttons("Properties - PID %d".printf(pid), ctx.window, Gtk.DialogFlags.MODAL,
            "Close", Gtk.ResponseType.CLOSE);
        d.set_default_size(440, 340);
        var box = d.get_content_area();
        box.border_width = 16;
        var grid = new Gtk.Grid();
        grid.row_spacing = 6;
        grid.column_spacing = 16;
        for (int i = 0; i < fields.length[0]; i++) {
            var k = Ui.label(fields[i, 0], "props-key");
            var v = Ui.label(fields[i, 1], "props-value");
            v.wrap = true;
            v.max_width_chars = 42;
            v.selectable = true;
            grid.attach(k, 0, i, 1, 1);
            grid.attach(v, 1, i, 1, 1);
        }
        box.add(grid);
        d.show_all();
        d.run();
        d.destroy();
    }
}
