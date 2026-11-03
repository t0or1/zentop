/* tab_resources.vala -- the Resources tab: three sub-pages behind a
 * GENERAL MEASUREMENTS | POWER CONSUMPTION | TEMPERATURES switcher.
 * GENERAL samples whenever Resources is open; the sensor pages only while
 * shown. Sensor discovery runs the
 * first time a sensor page is opened, and again when devices appear or
 * go away (a battery, a USB drive). */

public class ResourcesTab : Gtk.Box {
    private AppContext ctx;
    private Gtk.Stack pages;
    private GeneralPage general;
    private SensorHub? hub = null;
    private SensorsPage? power = null;
    private SensorsPage? temps = null;
    private uint ticks = 0;

    public ResourcesTab(AppContext ctx) {
        Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);
        this.ctx = ctx;
        pages = new Gtk.Stack();
        pages.transition_type = Gtk.StackTransitionType.NONE;
        var switcher = new Gtk.StackSwitcher();
        switcher.stack = pages;
        switcher.halign = Gtk.Align.START;
        switcher.get_style_context().add_class("zt-subtabs");
        Ui.margins(switcher, 20, 20, 12, 0);
        pack_start(switcher, false, false, 0);

        general = new GeneralPage(ctx);
        pages.add_titled(general, "general", "GENERAL MEASUREMENTS");
        pages.add_titled(new Gtk.Box(Gtk.Orientation.VERTICAL, 0), "power", "POWER CONSUMPTION");
        pages.add_titled(new Gtk.Box(Gtk.Orientation.VERTICAL, 0), "temps", "TEMPERATURES");
        switcher.homogeneous = false;
        pages.notify["visible-child-name"].connect(() => { ensure_sensors(); refresh_page(true); });
        pack_start(pages, true, true, 0);
    }

    private void ensure_sensors() {
        string page = pages.visible_child_name;
        if (page == "general") return;
        if (hub == null) {
            hub = new SensorHub();
            hub.discover();
        }
        if (page == "power" && power == null) power = add_sensor_page("power", SensorKind.POWER);
        if (page == "temps" && temps == null) temps = add_sensor_page("temps", SensorKind.TEMP);
    }

    private SensorsPage add_sensor_page(string name, SensorKind kind) {
        var p = new SensorsPage(ctx, hub, kind);
        var holder = (Gtk.Box) pages.get_child_by_name(name);
        holder.pack_start(p, true, true, 0);
        p.show_all();
        p.rebuild();   // after show_all: shows only the notes that apply
        return p;
    }

    /* Called every second by the window. Returns true when the shared
     * CPU/memory sampler was read (the header can reuse it). */
    public bool refresh() {
        ticks++;
        return refresh_page(false);
    }

    /* GENERAL keeps sampling behind the sensor pages (a 12 us read; hidden
     * graphs take the point without drawing), so its 60 s history has no
     * hole when you come back. Sensor pages only read while shown. */
    private bool refresh_page(bool now) {
        if (!now || pages.visible_child_name == "general") general.refresh();
        switch (pages.visible_child_name) {
            case "power":
                check_devices();
                power.refresh();
                break;
            case "temps":
                check_devices();
                if (now || ticks % 2 == 0) temps.refresh();   // temperatures move slowly: every 2 s
                break;
        }
        return true;
    }

    /* Every 10 s while a sensor page is open: did devices come or go? */
    private void check_devices() {
        if (ticks % 10 != 0 || !hub.topology_changed()) return;
        hub.discover();
        if (power != null) power.rebuild();
        if (temps != null) temps.rebuild();
    }

    public void redraw() {
        general.redraw();
        if (power != null) power.redraw();
        if (temps != null) temps.redraw();
    }
}

/* GENERAL MEASUREMENTS: CPU (model, total, per core with its clock),
 * memory (modules), swap (zram, partition, file) and network (the active
 * card), each a live figure, a history graph and bars, through the sampler
 * the header shares. */
public class GeneralPage : Gtk.ScrolledWindow {
    private AppContext ctx;
    private ResourcesSampler sampler;
    private HistoryGraph cpu_graph;
    private HistoryGraph mem_graph;
    private HistoryGraph net_graph;
    private Gtk.Label cpu_value;
    private Gtk.Label mem_value;
    private Gtk.Label swap_value;
    private Gtk.Label rx_label;
    private Gtk.Label tx_label;
    private Gtk.ProgressBar ram_bar;
    private Gtk.ProgressBar swap_bar;
    private Gtk.ProgressBar[] core_bars;
    private Gtk.Label[] core_values;
    private Gtk.Label[] core_freqs;
    private Gtk.Label swap_desc;
    private Gtk.Label net_desc;
    private uint ticks = 0;

    public GeneralPage(AppContext ctx) {
        Object(hadjustment: null, vadjustment: null);
        this.ctx = ctx;
        sampler = ctx.sampler;
        vexpand = true;
        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 10);
        Ui.margins(box, 20, 20, 14, 24);
        add(box);

        // CPU: the model and the figure, its history, then the per-core board
        var cpu_row = Ui.section_header(box, "CPU", 0, ctx.tnum, out cpu_value);
        describe(cpu_row, HwInfo.cpu_model());
        cpu_graph = new HistoryGraph(ctx.theme, {"g-cpu"}, 100.0);
        box.pack_start(cpu_graph, false, false, 0);
        box.pack_start(build_core_grid(), false, false, 0);

        // MEMORY & SWAP
        describe(Ui.section_header(box, "MEMORY", 24, ctx.tnum, out mem_value), HwInfo.ram_summary());
        ram_bar = bar("ram-bar");
        box.pack_start(ram_bar, false, false, 0);
        swap_desc = describe(Ui.section_header(box, "SWAP", 8, ctx.tnum, out swap_value), HwInfo.swap_summary());
        swap_bar = bar("swap-bar");
        box.pack_start(swap_bar, false, false, 0);
        mem_graph = new HistoryGraph(ctx.theme, {"g-mem", "g-swap"}, 100.0);
        mem_graph.margin_top = 6;
        box.pack_start(mem_graph, false, false, 0);

        // NETWORK
        Gtk.Label? unused;
        var net_row = Ui.section_header(box, "NETWORK", 24, ctx.tnum, out unused, false);
        net_desc = describe(net_row, HwInfo.net_summary());
        tx_label = Ui.label("TX 0.0B/s", "net-sent-label");
        tx_label.attributes = ctx.tnum;
        rx_label = Ui.label("RX 0.0B/s", "net-recv-label");
        rx_label.attributes = ctx.tnum;
        rx_label.margin_end = 18;
        net_row.pack_end(tx_label, false, false, 0);
        net_row.pack_end(rx_label, false, false, 0);
        net_graph = new HistoryGraph(ctx.theme, {"g-rx", "g-tx"}, 1.0, true);
        net_graph.scale_text = (v) => Fmt.rate(v);
        box.pack_start(net_graph, false, false, 0);
    }

    /* The hardware behind a section, quiet, after its name: "DDR4 · 3200
     * MT/s · 2 × 16 GB". Cut with "…" when narrow; the tooltip has it all. */
    private static Gtk.Label describe(Gtk.Box row, string text) {
        var l = Ui.label(text, "bar-label");
        l.ellipsize = Pango.EllipsizeMode.END;
        l.tooltip_text = text != "" ? text : null;
        row.pack_start(l, false, false, 0);
        return l;
    }

    private static void set_description(Gtk.Label l, string text) {
        if (l.label == text) return;
        l.label = text;
        l.tooltip_text = text != "" ? text : null;
    }

    private static Gtk.ProgressBar bar(string css_class) {
        var b = new Gtk.ProgressBar();
        b.get_style_context().add_class(css_class);
        return b;
    }

    private Gtk.Grid build_core_grid() {
        int cores = (int) GLib.get_num_processors();
        core_bars = new Gtk.ProgressBar[cores];
        core_values = new Gtk.Label[cores];
        core_freqs = new Gtk.Label[cores];
        sampler.sample_freqs();   // finds the clock source, so unused labels stay hidden
        var grid = new Gtk.Grid();
        grid.row_spacing = 10;
        grid.column_spacing = 24;
        grid.margin_top = 6;
        int cols = cores <= 4 ? 2 : 4;
        for (int i = 0; i < cores; i++) {
            var name = Ui.label("CORE %d".printf(i), "bar-label");
            name.width_chars = 7;
            core_bars[i] = bar("cpu-bar");
            core_bars[i].hexpand = true;
            core_bars[i].valign = Gtk.Align.CENTER;
            core_values[i] = Ui.label("-", "bar-label", 1);
            core_values[i].width_chars = 4;
            core_values[i].attributes = ctx.tnum;
            // clock speed right after the name; wide enough for "5.25 GHz", so it never jitters
            core_freqs[i] = Ui.label("", "bar-label", 1);
            core_freqs[i].width_chars = 8;
            core_freqs[i].attributes = ctx.tnum;
            core_freqs[i].no_show_all = !sampler.has_freq;
            int r = i / cols, c = i % cols;
            grid.attach(name, c * 4, r, 1, 1);
            grid.attach(core_freqs[i], c * 4 + 1, r, 1, 1);
            grid.attach(core_bars[i], c * 4 + 2, r, 1, 1);
            grid.attach(core_values[i], c * 4 + 3, r, 1, 1);
        }
        return grid;
    }

    /* "3.42 GHz", or "800 MHz" below a gigahertz. */
    private static string fmt_mhz(double mhz) {
        if (mhz.is_nan()) return "-";
        return mhz >= 1000 ? "%.2f GHz".printf(mhz / 1000) : "%.0f MHz".printf(mhz);
    }

    /* Fractions are only set when they moved: set_fraction() always redraws. */
    private static void set_fraction(Gtk.ProgressBar b, double f) {
        if (Math.fabs(b.fraction - f) >= 0.001) b.fraction = f;
    }

    public void refresh() {
        // swap devices, the zram ratio and the active network card change
        // rarely: look again every 10 s, not every second
        if (++ticks % 10 == 0) {
            set_description(swap_desc, HwInfo.swap_summary());
            set_description(net_desc, HwInfo.net_summary());
        }
        sampler.sample_cpu();
        for (int i = 0; i < core_bars.length && i < sampler.cpu_cores.length; i++) {
            double p = sampler.cpu_cores[i];
            set_fraction(core_bars[i], p / 100.0);
            Ui.set_text(core_values[i], "%.0f%%".printf(p));
        }
        if (sampler.has_freq) {
            sampler.sample_freqs();
            for (int i = 0; i < core_freqs.length && i < sampler.core_mhz.length; i++)
                Ui.set_text(core_freqs[i], fmt_mhz(sampler.core_mhz[i]));
        }
        cpu_graph.push({sampler.cpu_total});
        Ui.set_text(cpu_value, "%.0f%%".printf(sampler.cpu_total));

        var m = sampler.sample_memory();
        set_fraction(ram_bar, m.percent / 100.0);
        Ui.set_text(mem_value, "%s / %s  ·  %.0f%%".printf(
            Fmt.bytes((int64) m.used), Fmt.bytes((int64) m.total), m.percent));
        bool has_swap = m.swap_total > 0;
        set_fraction(swap_bar, has_swap ? m.swap_percent / 100.0 : 0);
        Ui.set_text(swap_value, has_swap ? "%s / %s  ·  %.0f%%".printf(
            Fmt.bytes((int64) m.swap_used), Fmt.bytes((int64) m.swap_total), m.swap_percent) : "No swap");
        mem_graph.push({m.percent, has_swap ? m.swap_percent : 0});

        sampler.sample_network();
        net_graph.push({sampler.rx_rate, sampler.tx_rate});
        Ui.set_text(rx_label, "RX " + Fmt.rate(sampler.rx_rate));
        Ui.set_text(tx_label, "TX " + Fmt.rate(sampler.tx_rate));
    }

    public void redraw() {
        cpu_graph.queue_draw();
        mem_graph.queue_draw();
        net_graph.queue_draw();
    }
}
