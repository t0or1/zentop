/* window.vala -- the shell: stylesheet, header strip (wordmark, tabs, live
 * CPU/MEM), the five tabs and one 1 s scheduler.
 *
 * Scheduling: a single timer drives everything; each tick only does the
 * work for the visible tab (Resources every 1 s, Processes/Pie every 2 s,
 * File Systems every 5 s) plus the header every 2 s, which reuses the
 * Resources sample when that tab is on screen. While the window is
 * minimised the timer is removed altogether: no work and no wake-ups.
 *
 * Tabs other than Processes are built the first time they are opened: an
 * empty box holds each one's place in the stack until then, so start-up
 * builds one tab, not five, and an unvisited tab costs nothing. */

public class ZentopWindow : Gtk.ApplicationWindow {
    private AppContext ctx;
    private Gtk.CssProvider css = new Gtk.CssProvider();
    private string theme_id;
    private ProcessFeed feed = new ProcessFeed();
    private Gtk.Label hdr_cpu;
    private Gtk.Label hdr_mem;
    private bool hdr_hot = false;
    private Gtk.Stack stack;
    private ProcessesTab processes;
    private ResourcesTab? resources = null;
    private PieTab? pie = null;
    private FilesystemsTab? filesystems = null;
    private ThemesTab? themes = null;
    private string active = "processes";
    private uint ticks = 0;
    private bool minimised = false;
    private uint timer = 0;

    public ZentopWindow(Gtk.Application app) {
        Object(application: app, title: "zentop", default_width: 1440, default_height: 900);
        ctx = new AppContext(this);
        theme_id = AppConfig.get_theme();
        load_theme(theme_id);
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css,
                                                 Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        build();
        ctx.theme.read_from(get_style_context());
        style_updated.connect(on_style_updated);
        window_state_event.connect((e) => {
            bool now_min = (e.new_window_state & Gdk.WindowState.ICONIFIED) != 0;
            if (now_min == minimised) return false;
            minimised = now_min;
            if (minimised) {
                // no timer at all while minimised: zero wake-ups, not cheap ones
                Source.remove(timer);
                timer = 0;
            } else {
                refresh_now();   // back on screen: catch up at once
                timer = Timeout.add_seconds(1, on_tick);
            }
            return false;
        });
        feed.rows_ready.connect(on_rows);
        destroy.connect(() => {
            if (filesystems != null) filesystems.cancel_scan();
            feed.shutdown();
        });
        refresh_header(false);
        refresh_now();
        timer = Timeout.add_seconds(1, on_tick);
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
        stack = new Gtk.Stack();
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
        stack.add_titled(processes, "processes", "PROCESSES");
        stack.add_titled(placeholder(), "resources", "RESOURCES");
        stack.add_titled(placeholder(), "piegraph", "PIE GRAPH");
        stack.add_titled(placeholder(), "filesystems", "FILE SYSTEMS");
        stack.add_titled(placeholder(), "themes", "THEMES");
        switcher.homogeneous = false; // after the pages exist: tabs as wide as their words
        stack.notify["visible-child-name"].connect(() => {
            active = stack.visible_child_name;
            ensure_tab(active);
            refresh_now();
        });
        root.pack_start(stack, true, true, 0);
        root.show_all();
    }

    private static Gtk.Box placeholder() {
        return new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
    }

    /* Builds a tab into its placeholder the first time it's shown. */
    private void ensure_tab(string name) {
        Gtk.Widget? tab = null;
        switch (name) {
            case "resources":
                if (resources != null) return;
                tab = resources = new ResourcesTab(ctx);
                break;
            case "piegraph":
                if (pie != null) return;
                tab = pie = new PieTab(ctx);
                break;
            case "filesystems":
                if (filesystems != null) return;
                tab = filesystems = new FilesystemsTab(ctx);
                break;
            case "themes":
                if (themes != null) return;
                themes = new ThemesTab(ctx, theme_id);
                themes.chosen.connect(apply_theme);
                tab = themes;
                break;
            default:
                return;
        }
        var holder = (Gtk.Box) stack.get_child_by_name(name);
        holder.pack_start(tab, true, true, 0);
        tab.show_all();
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
        ticks++;
        bool resources_sampled = false;
        switch (active) {
            case "resources": resources_sampled = resources.refresh(); break;
            case "processes": if (ticks % 2 == 0 && !processes.paused) feed.request(); break;
            case "piegraph": if (ticks % 2 == 0) feed.request(); break;
            case "filesystems": if (ticks % 5 == 0) filesystems.refresh(); break;
        }
        if (ticks % 2 == 0) refresh_header(resources_sampled);
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

    /* Always-visible figures. `fresh`: Resources sampled this tick already,
     * so reuse that instead of reading /proc/stat and meminfo again. */
    private void refresh_header(bool fresh) {
        var s = ctx.sampler;
        if (!fresh) {
            s.sample_cpu();
            s.sample_memory();
        }
        double cpu = s.cpu_total;
        Ui.set_text(hdr_cpu, "%.0f%%".printf(cpu));
        Ui.set_text(hdr_mem, "%s / %s".printf(Fmt.bytes((int64) s.mem.used), Fmt.bytes((int64) s.mem.total)));
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
     * really changed, so that stays free. Unbuilt tabs read the colours
     * when they are built. */
    private void on_style_updated() {
        if (!ctx.theme.read_from(get_style_context())) return;
        processes.invalidate();
        if (resources != null) resources.redraw();
        if (pie != null) pie.redraw();
        if (filesystems != null) filesystems.redraw();
        if (themes != null) themes.redraw();
        refresh_now();
    }
}
