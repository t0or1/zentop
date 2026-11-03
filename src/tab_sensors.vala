/* tab_sensors.vala -- the Power Consumption and Temperatures pages inside
 * Resources. One history graph (a line per group: CPU, GPU, NVMe...) above
 * a table of every sensor with its live, lowest, average and peak figures;
 * temperatures add the driver's own warning and critical thresholds and
 * turn hot past them. Built once per sensor discovery; a tick only rewrites
 * the cells whose text changed. */

const double TEMP_HOT_FALLBACK = 85.0;  // when a driver gives no threshold

public class SensorsPage : Gtk.Box {
    enum Col { CHIP, NAME, SOURCE, NOW, C1, C2, C3, C4, ST_NAME, ST_NOW, CHIP_PIX, N }

    private AppContext ctx;
    private SensorHub hub;
    private SensorKind kind;
    private HistoryGraph? graph = null;
    private Gtk.Box graph_holder;
    private Gtk.TreeStore store;
    private Gtk.TreeView view;
    private Gtk.Label note;
    private Gtk.Label empty;
    private Gee.ArrayList<Sensor> ordered = new Gee.ArrayList<Sensor>();
    private Gee.ArrayList<Gtk.TreeIter?> iters = new Gee.ArrayList<Gtk.TreeIter?>();
    private Gee.ArrayList<Sensor> leads = new Gee.ArrayList<Sensor>();  // graphed, one per group

    public SensorsPage(AppContext ctx, SensorHub hub, SensorKind kind) {
        Object(orientation: Gtk.Orientation.VERTICAL, spacing: 10);
        this.ctx = ctx;
        this.hub = hub;
        this.kind = kind;
        Ui.margins(this, 20, 20, 16, 20);

        pack_start(Ui.section_label(kind == SensorKind.POWER ? "POWER DRAW  ·  LAST 60 S"
                                                              : "TEMPERATURE  ·  LAST 60 S"), false, false, 0);
        graph_holder = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        pack_start(graph_holder, false, false, 0);

        var types = new Type[Col.N];
        for (int i = 0; i < Col.N; i++) types[i] = typeof(string);
        types[Col.ST_NAME] = types[Col.ST_NOW] = typeof(int);
        types[Col.CHIP_PIX] = typeof(Gdk.Pixbuf);
        store = new Gtk.TreeStore.newv(types);
        view = new Gtk.TreeView.with_model(store);
        view.get_style_context().add_class("data-table");
        view.show_expanders = false;
        view.level_indentation = 0;
        view.get_selection().mode = Gtk.SelectionMode.NONE;
        view.has_tooltip = true;
        view.query_tooltip.connect(on_tooltip);
        build_columns();
        view.fixed_height_mode = true;
        var scroller = new Gtk.ScrolledWindow(null, null);
        scroller.vexpand = true;
        scroller.add(view);
        pack_start(scroller, true, true, 0);

        empty = Ui.label("", "bar-label");
        empty.wrap = true;
        empty.no_show_all = true;
        pack_start(empty, false, false, 0);
        note = Ui.label("", "bar-label");
        note.wrap = true;
        note.selectable = true;
        note.no_show_all = true;
        pack_start(note, false, false, 0);
    }

    private void build_columns() {
        string[] heads = kind == SensorKind.POWER
            ? new string[] {"", "SENSOR", "SOURCE", "NOW", "MIN", "AVG", "PEAK", ""}
            : new string[] {"", "SENSOR", "SOURCE", "NOW", "MIN", "PEAK", "HIGH", "CRIT"};
        for (int i = 0; i < heads.length; i++) {
            if (i > 0 && heads[i] == "") continue;
            var col = new Gtk.TreeViewColumn();
            col.title = heads[i];
            if (i == Col.CHIP) {
                // the graph line's colour, as the same 10 px swatch the legends use
                var chip = new Gtk.CellRendererPixbuf();
                chip.set_padding(2, 0);
                col.pack_start(chip, false);
                col.add_attribute(chip, "pixbuf", Col.CHIP_PIX);
                col.sizing = Gtk.TreeViewColumnSizing.FIXED;
                col.fixed_width = 18;
                view.append_column(col);
                continue;
            }
            bool numeric = i >= Col.NOW;
            var r = new TableText(ctx.theme, numeric ? 1.0f : 0.0f, numeric ? ctx.tnum : null);
            col.pack_start(r, true);
            r.bind(col, i, i == Col.NAME ? (int) Col.ST_NAME : (i == Col.NOW ? (int) Col.ST_NOW : -1));
            // Fixed widths + fixed-height mode: a changed figure redraws its row
            // without GTK re-measuring rows and columns (that was ~1/4 of
            // this page's CPU). The widths fit "142.35 W" and "100.0°C".
            col.sizing = Gtk.TreeViewColumnSizing.FIXED;
            col.fixed_width = i == Col.NAME ? 260 : (i == Col.SOURCE ? 140 : 96);
            col.expand = i == Col.NAME;
            col.resizable = true;
            view.append_column(col);
        }
    }

    /* Rebuild everything from the hub's current sensor list. */
    public void rebuild() {
        var list = kind == SensorKind.POWER ? hub.power : hub.temps;
        // groups in display order; sensors keep discovery order inside a group
        var groups = new Gee.ArrayList<string>();
        foreach (var s in list) if (!groups.contains(s.group)) groups.add(s.group);
        groups.sort((a, b) => {
            int d = SensorHub.group_rank(a) - SensorHub.group_rank(b);
            return d != 0 ? d : strcmp(a, b);
        });
        store.clear();
        ordered.clear();
        iters.clear();
        leads.clear();
        foreach (var g in groups) {
            Gtk.TreeIter parent;
            store.append(out parent, null);
            store.set(parent, Col.NAME, g, Col.ST_NAME, cell_style(Ink.DEFAULT, WEIGHT_BOLD), Col.ST_NOW, 0, -1);
            Sensor? lead = null;
            foreach (var s in list) {
                if (s.group != g) continue;
                if (lead == null && !s.locked && leads.size < 8) { lead = s; leads.add(s); }
                Gtk.TreeIter it;
                store.append(out it, parent);
                store.set(it, Col.NAME, s.label, Col.SOURCE, s.source, Col.ST_NAME, 0, Col.ST_NOW, 0,
                          Col.CHIP_PIX, lead == s ? swatch(SERIES[leads.size - 1]) : null, -1);
                ordered.add(s);
                iters.add(it);
            }
        }
        view.expand_all();

        if (graph != null) graph.destroy();
        graph = null;
        if (leads.size > 0) {
            var roles = new string[leads.size];
            for (int i = 0; i < leads.size; i++) roles[i] = SERIES[i];
            graph = new HistoryGraph(ctx.theme, roles, 1.0, true, 140);
            graph.min_top = 5.0;
            graph.fill = leads.size <= 2;                  // many overlapping fills turn to mud
            graph.float_bottom = kind == SensorKind.TEMP;  // 35-60 °C shouldn't sit in the top fifth
            graph_holder.pack_start(graph, false, false, 0);
            graph.show();
        }

        bool none = list.size == 0;
        empty.label = kind == SensorKind.POWER
            ? "No power sensors found. They come from RAPL, hwmon drivers (amdgpu, zenpower, i915), batteries and NVIDIA's NVML."
            : "No temperature sensors found. They come from hwmon drivers; running \"sudo sensors-detect\" (lm-sensors) can load the right ones.";
        empty.visible = none;
        bool hint = kind == SensorKind.POWER && hub.rapl_locked;
        if (hint) {
            switch (SensorHub.rapl_setup()) {
                case RaplSetup.NOT_SET_UP:
                    note.label = "RAPL counters (CPU package, cores, DRAM) are root-only since 2020, a fix for the PLATYPUS "
                               + "power side-channel. To read them as your user, run once in the zentop folder: bash install.sh --rapl";
                    break;
                case RaplSetup.NEEDS_RELOGIN:
                    note.label = "RAPL access is set up. Log out and back in (or reboot) so this session joins the rapl group.";
                    break;
                case RaplSetup.NEEDS_APPLY:
                    note.label = "You're in the rapl group but the counters are still locked. Reboot once, or run: "
                               + "sudo udevadm trigger --subsystem-match=powercap --action=add";
                    break;
            }
        }
        note.visible = hint;
    }

    /* 10 px square in a series colour; one pixbuf per colour, reused. */
    private Gee.HashMap<string, Gdk.Pixbuf> swatches = new Gee.HashMap<string, Gdk.Pixbuf>();
    private Gdk.Pixbuf swatch(string role) {
        string hex = ctx.theme.hex(role);
        var hit = swatches[hex];
        if (hit != null) return hit;
        var px = new Gdk.Pixbuf(Gdk.Colorspace.RGB, false, 8, 10, 10);
        px.fill((uint32) uint64.parse("0x" + hex.substring(1) + "ff"));
        swatches[hex] = px;
        return px;
    }

    private static string fmt_value(double v, SensorKind kind) {
        if (v.is_nan() || v.is_infinity() != 0) return "-";
        if (kind == SensorKind.TEMP) return "%.1f°C".printf(v);
        return v < 10 ? "%.2f W".printf(v) : "%.1f W".printf(v);
    }

    private bool is_hot(Sensor s) {
        if (s.value.is_nan()) return false;
        // drivers' "max" is often the throttle point (Intel reports TjMax, 100 °C),
        // so hot starts at whichever comes first
        double limit = TEMP_HOT_FALLBACK;
        if (!s.high.is_nan()) limit = double.min(limit, s.high);
        if (!s.crit.is_nan()) limit = double.min(limit, s.crit - 10);
        return s.value >= limit;
    }

    private void set_cell(Gtk.TreeIter it, int col, string text) {
        Value v;
        store.get_value(it, col, out v);
        if ((string?) v != text) store.set(it, col, text, -1);
    }

    /* A write redraws the row: only when the look really changes. */
    private void set_now_style(Gtk.TreeIter it, int style) {
        Value v;
        store.get_value(it, Col.ST_NOW, out v);
        if ((int) v != style) store.set(it, Col.ST_NOW, style, -1);
    }

    /* One sample of this page's kind, then only the changed cells. */
    public void refresh() {
        hub.sample(kind);
        for (int i = 0; i < ordered.size; i++) {
            var s = ordered[i];
            var it = iters[i];
            if (s.locked) {
                set_cell(it, Col.NOW, "no access");
                set_now_style(it, cell_style(Ink.IDLE));
                continue;
            }
            string label = s.note != null && s.note != "" && s.note != "unknown" ? "%s (%s)".printf(s.label, s.note) : s.label;
            set_cell(it, Col.NAME, label);
            set_cell(it, Col.NOW, fmt_value(s.value, kind));
            set_cell(it, Col.C1, fmt_value(s.low, kind));
            if (kind == SensorKind.POWER) {
                set_cell(it, Col.C2, fmt_value(s.avg(), kind));
                set_cell(it, Col.C3, fmt_value(s.peak, kind));
            } else {
                set_cell(it, Col.C2, fmt_value(s.peak, kind));
                set_cell(it, Col.C3, fmt_value(s.high, kind));
                set_cell(it, Col.C4, fmt_value(s.crit, kind));
                set_now_style(it, is_hot(s) ? cell_style(Ink.HOT, WEIGHT_BOLD) : 0);
            }
        }
        if (graph != null) {
            var vals = new double[leads.size];
            for (int i = 0; i < leads.size; i++) vals[i] = leads[i].value;  // NaN breaks the line, never a fake 0
            graph.push(vals);
        }
    }

    /* Hovering a sensor shows the file it comes from. */
    private bool on_tooltip(int x, int y, bool keyboard, Gtk.Tooltip tip) {
        Gtk.TreeModel m;
        Gtk.TreePath path;
        Gtk.TreeIter it;
        if (!view.get_tooltip_context(ref x, ref y, keyboard, out m, out path, out it)) return false;
        for (int i = 0; i < iters.size; i++) {
            if (store.get_path(iters[i]).compare(path) != 0) continue;
            tip.set_text(ordered[i].path);
            view.set_tooltip_row(tip, path);
            return true;
        }
        return false;
    }

    /* Theme changed: the swatches are pixbufs in the theme's colours; the
     * text inks are codes, resolved at draw time. */
    public void redraw() {
        for (int i = 0, lead = 0; i < ordered.size && lead < leads.size; i++)
            if (ordered[i] == leads[lead]) store.set(iters[i], Col.CHIP_PIX, swatch(SERIES[lead++]), -1);
        view.queue_draw();
        if (graph != null) graph.queue_draw();
    }
}
