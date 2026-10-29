/* window.vala -- the shell: stylesheet, header strip (wordmark, tabs, live
 * CPU/MEM), the five tabs and one 1 s scheduler.
 *
 * Scheduling: a single timer drives everything; each tick only does the
 * work for the visible tab (Resources every 1 s, Processes/Pie every 2 s,
 * File Systems every 5 s) plus the header every 2 s. While the window is
 * minimised nothing runs at all. */

public class ZentopWindow : Gtk.ApplicationWindow {
    private AppContext ctx;
    private Gtk.CssProvider css = new Gtk.CssProvider();
    private string theme_id;
    private ProcessFeed feed = new ProcessFeed();
    private ResourcesSampler header_sampler = new ResourcesSampler();
    private Gtk.Label hdr_cpu;
    private Gtk.Label hdr_mem;
    private bool hdr_hot = false;
    private ProcessesTab processes;
    private ResourcesTab resources;
    private PieTab pie;
    private FilesystemsTab filesystems;
    private ThemesTab themes;
    private string active = "processes";
    private uint ticks = 0;
    private bool minimised = false;

    public ZentopWindow(Gtk.Application app) {
        Object(application: app, title: "zentop", default_width: 1440, default_height: 900);
        ctx = new AppContext(this, new ResourcesSampler().sample_memory().total);
        theme_id = AppConfig.get_theme();
        load_theme(theme_id);
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css,
                                                 Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        build();
        ctx.theme.read_from(get_style_context());
        style_updated.connect(on_style_updated);
        window_state_event.connect((e) => {
            bool was = minimised;
            minimised = (e.new_window_state & Gdk.WindowState.ICONIFIED) != 0;
            if (was && !minimised) refresh_now();   // back on screen: catch up at once
            return false;
        });
        feed.rows_ready.connect(on_rows);
        destroy.connect(() => { filesystems.cancel_scan(); feed.shutdown(); });

        header_sampler.sample_cpu();
        refresh_header();
        refresh_now();
        Timeout.add_seconds(1, on_tick);
    }

    private bool load_theme(string id) {
        string path = AppPaths.theme_file(id);
        try {
            css.load_from_path(path);
            return true;
        } catch (Error e) {
            if (id != "default") return load_theme("default");
            stderr.printf("Could not load theme %s: %s\n", path, e.message);
            return false;
        }
    }

    private void build() {
        var root = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        root.get_style_context().add_class("root-bg");
        add(root);

        // one-line header strip: wordmark, tabs, live figures
        var header = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        header.get_style_context().add_class("zt-header");
        var title = Ui.label("ZENTOP", "title-label");
        title.margin_end = 28;
        header.pack_start(title, false, false, 0);
        var stack = new Gtk.Stack();
        stack.transition_type = Gtk.StackTransitionType.NONE; // instant: zero animation frames
        var switcher = new Gtk.StackSwitcher();
        switcher.stack = stack;
        switcher.halign = Gtk.Align.START;
        switcher.get_style_context().add_class("pill-switcher");
        header.pack_start(switcher, false, false, 0);
        hdr_mem = header_stat(header, "MEM");
        hdr_cpu = header_stat(header, "CPU");
        root.pack_start(header, false, false, 0);

        processes = new ProcessesTab(ctx);
        processes.refresh_wanted.connect(() => feed.request());
        resources = new ResourcesTab(ctx);
        pie = new PieTab(ctx);
        filesystems = new FilesystemsTab(ctx);
        themes = new ThemesTab(ctx, theme_id);
        themes.chosen.connect(apply_theme);
        stack.add_titled(processes, "processes", "PROCESSES");
        stack.add_titled(resources, "resources", "RESOURCES");
        stack.add_titled(pie, "piegraph", "PIE GRAPH");
        stack.add_titled(filesystems, "filesystems", "FILE SYSTEMS");
        stack.add_titled(themes, "themes", "THEMES");
        switcher.homogeneous = false; // after the pages exist: tabs as wide as their words
        stack.notify["visible-child-name"].connect(() => {
            active = stack.visible_child_name;
            refresh_now();
        });
        root.pack_start(stack, true, true, 0);
        root.show_all();
    }

    private Gtk.Label header_stat(Gtk.Box header, string key) {
        var box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
        box.margin_start = 20;
        box.pack_start(Ui.label(key, "zt-stat-key"), false, false, 0);
        var v = Ui.label("-", "zt-stat-value");
        v.attributes = ctx.tnum;
        box.pack_start(v, false, false, 0);
        header.pack_end(box, false, false, 0);
        return v;
    }

    // ------------------------------------------------------------- schedule

    private bool on_tick() {
        if (minimised) return true;
        ticks++;
        if (ticks % 2 == 0) refresh_header();
        switch (active) {
            case "resources": resources.refresh(); break;
            case "processes": if (ticks % 2 == 0 && !processes.paused) feed.request(); break;
            case "piegraph": if (ticks % 2 == 0) feed.request(); break;
            case "filesystems": if (ticks % 5 == 0) filesystems.refresh(); break;
        }
        return true;
    }

    /* Tab switch, un-minimise: show fresh data now, not on the next tick. */
    private void refresh_now() {
        switch (active) {
            case "resources": resources.refresh(); break;
            case "processes": case "piegraph": feed.request(); break;
            case "filesystems": filesystems.refresh(); break;
        }
    }

    private void on_rows(Gee.ArrayList<ProcessRow> rows) {
        if (active == "processes") processes.apply(rows);
        else if (active == "piegraph") pie.apply(rows);
    }

    /* Always-visible figures: two tiny /proc reads every 2 s. */
    private void refresh_header() {
        header_sampler.sample_cpu();
        var m = header_sampler.sample_memory();
        double cpu = header_sampler.cpu_total;
        Ui.set_text(hdr_cpu, "%.0f%%".printf(cpu));
        Ui.set_text(hdr_mem, "%s / %s".printf(Fmt.bytes((int64) m.used), Fmt.bytes((int64) m.total)));
        bool hot = cpu >= 80;
        if (hot == hdr_hot) return;
        hdr_hot = hot;
        if (hot) hdr_cpu.get_style_context().add_class("zt-hot");
        else hdr_cpu.get_style_context().remove_class("zt-hot");
    }

    // ------------------------------------------------------------- theme

    /* Reloading the same provider restyles every widget live; colours are
     * then re-read in on_style_updated. */
    private void apply_theme(string id) {
        if (id == theme_id) return;
        if (!FileUtils.test(AppPaths.theme_file(id), FileTest.EXISTS)) {
            ctx.show_error("Could not find theme file: " + AppPaths.theme_file(id));
            return;
        }
        if (!load_theme(id)) return;
        theme_id = id;
        AppConfig.set_theme(id);
    }

    /* Also fires on focus in/out (backdrop): only act when the colours
     * really changed, so that stays free. */
    private void on_style_updated() {
        if (!ctx.theme.read_from(get_style_context())) return;
        processes.invalidate();
        resources.redraw();
        pie.redraw();
        filesystems.redraw();
        themes.redraw();
        refresh_now();
    }
}
