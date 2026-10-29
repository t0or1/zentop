/* tab_resources.vala -- CPU (total + per core), memory, swap and network,
 * each a live figure, a history graph and bars. Sampled only while the
 * tab is visible. */

public class ResourcesTab : Gtk.ScrolledWindow {
    private AppContext ctx;
    private ResourcesSampler sampler = new ResourcesSampler();
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

    public ResourcesTab(AppContext ctx) {
        Object(hadjustment: null, vadjustment: null);
        this.ctx = ctx;
        vexpand = true;
        var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 10);
        Ui.margins(box, 20, 20, 16, 24);
        add(box);
        sampler.sample_cpu();     // prime the deltas so the first tick is real
        sampler.sample_network();

        // CPU: the figure, its history, then the per-core board
        Ui.section_header(box, "CPU", 0, ctx.tnum, out cpu_value);
        cpu_graph = new HistoryGraph(ctx.theme, {"g-cpu"}, 100.0);
        box.pack_start(cpu_graph, false, false, 0);
        box.pack_start(build_core_grid(), false, false, 0);

        // MEMORY & SWAP
        Ui.section_header(box, "MEMORY", 24, ctx.tnum, out mem_value);
        ram_bar = bar("ram-bar");
        box.pack_start(ram_bar, false, false, 0);
        Ui.section_header(box, "SWAP", 8, ctx.tnum, out swap_value);
        swap_bar = bar("swap-bar");
        box.pack_start(swap_bar, false, false, 0);
        mem_graph = new HistoryGraph(ctx.theme, {"g-mem", "g-swap"}, 100.0);
        mem_graph.margin_top = 6;
        box.pack_start(mem_graph, false, false, 0);

        // NETWORK
        Gtk.Label? unused;
        var net_row = Ui.section_header(box, "NETWORK", 24, ctx.tnum, out unused, false);
        tx_label = Ui.label("TX 0.0B/s", "net-sent-label");
        tx_label.attributes = ctx.tnum;
        rx_label = Ui.label("RX 0.0B/s", "net-recv-label");
        rx_label.attributes = ctx.tnum;
        rx_label.margin_end = 18;
        net_row.pack_end(tx_label, false, false, 0);
        net_row.pack_end(rx_label, false, false, 0);
        net_graph = new HistoryGraph(ctx.theme, {"g-rx", "g-tx"}, 1.0, true);
        box.pack_start(net_graph, false, false, 0);
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
            int r = i / cols, c = i % cols;
            grid.attach(name, c * 3, r, 1, 1);
            grid.attach(core_bars[i], c * 3 + 1, r, 1, 1);
            grid.attach(core_values[i], c * 3 + 2, r, 1, 1);
        }
        return grid;
    }

    /* Fractions are only set when they moved: set_fraction() always redraws. */
    private static void set_fraction(Gtk.ProgressBar b, double f) {
        if (Math.fabs(b.fraction - f) >= 0.001) b.fraction = f;
    }

    public void refresh() {
        sampler.sample_cpu();
        for (int i = 0; i < core_bars.length && i < sampler.cpu_cores.length; i++) {
            double p = sampler.cpu_cores[i];
            set_fraction(core_bars[i], p / 100.0);
            Ui.set_text(core_values[i], "%.0f%%".printf(p));
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
