/* tab_processes.vala -- the process table (flat or tree), its toolbar and
 * the "load band" typesetting: idle figures fade back, hot ones go bold in
 * the theme's hot ink. Each cell's ink and weight is one int column (see
 * table_text.vala): resolved against the theme when drawn, so a theme
 * switch rewrites nothing.
 *
 * Flat mode never reorders the store. Its rows are screen positions
 * ("slots"): each tick writes into slot i the process that now sorts i-th,
 * and only when that slot's content would look different. GTK then redraws
 * just the visible rows that changed; a reorder would redraw (and re-shape
 * the text of) every visible cell. Drawing is ~2/3 of this app's CPU, so
 * this is the main saving. The selection follows the pid, not the slot. */

// Load bands.
const double CPU_IDLE_BELOW = 0.5;  // % of one core
const double CPU_HOT_FROM = 20.0;
const double MEM_IDLE_BELOW = 0.5;  // % of total RAM
const double MEM_HOT_FROM = 5.0;
const int WEIGHT_NORMAL = 400;
const int WEIGHT_SEMIBOLD = 600;
const int WEIGHT_BOLD = 700;

public class ProcessesTab : Gtk.Box {
    enum Col {
        PID, PROCESS, USER, CPU, CPUID, MEMORY, DISKREADTOTAL, DISKWRITETOTAL,
        DISKREAD, DISKWRITE, PRIORITY, STATUS, STARTED, CPUTIME, BG, PIN,
        // cell_style() ints: the row's plain ink, then the cells that differ
        ST_ROW, ST_NAME, ST_CPU, ST_MEM, ST_RD, ST_WR, N
    }
    private const string[] TITLES = {
        "PROCESS", "USER", "CPU", "CPUID", "MEMORY", "DISKREADTOTAL", "DISKWRITETOTAL",
        "DISKREAD", "DISKWRITE", "PRIORITY", "STATUS", "STARTED", "CPU TIME"
    };


    public signal void refresh_wanted();

    private AppContext ctx;
    private ProcessActions actions;
    private Gtk.ListStore flat_store;
    private Gtk.TreeStore tree_store;
    private Gtk.TreeModelFilter filter;
    private Gtk.TreeView view;
    private Gtk.TreeViewColumn[] columns;
    private Gtk.SearchEntry search;
    private Gtk.Label count_label;
    private Gtk.Image pause_icon;
    private int[] all_cols;

    private Gee.ArrayList<ProcessRow?> slots = new Gee.ArrayList<ProcessRow?>(); // flat mode: what each row shows
    private Gee.HashMap<int, ProcessRow> current = new Gee.HashMap<int, ProcessRow>(); // this tick, for menus/search
    private int selected_pid = -1;
    private bool widths_locked = false;
    private Gee.HashSet<int> expanded = new Gee.HashSet<int>(); // tree mode: survives the rebuild
    private bool rebuilding = false;
    private int last_count = -1;

    private string search_text = "";
    private string filter_mode = "all";
    private int sort_column = Col.CPU;
    private bool sort_reverse = true;
    private bool tree_mode = false;
    public bool paused { get; private set; default = false; }

    public ProcessesTab(AppContext ctx) {
        Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);
        this.ctx = ctx;
        actions = new ProcessActions(ctx);
        actions.changed.connect(() => refresh_wanted());
        all_cols = new int[Col.N];
        for (int i = 0; i < Col.N; i++) all_cols[i] = i;
        build_toolbar();
        build_table();
    }

    // ------------------------------------------------------------- build

    private void build_toolbar() {
        var bar = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        Ui.margins(bar, 20, 20, 12, 10);

        var combo = new Gtk.ComboBoxText();
        combo.append("all", "All Processes");
        combo.append("mine", "My Processes");
        combo.append("active", "Active Processes");
        combo.active_id = "all";
        combo.changed.connect(() => { filter_mode = combo.active_id ?? "all"; refresh_wanted(); });
        bar.pack_start(combo, false, false, 0);

        var tree_toggle = new Gtk.ToggleButton.with_label("TREE VIEW");
        tree_toggle.get_style_context().add_class("tree-toggle");
        tree_toggle.toggled.connect(() => set_tree_mode(tree_toggle.active));
        bar.pack_start(tree_toggle, false, false, 0);

        search = new Gtk.SearchEntry();
        search.placeholder_text = "Filter by process name...";
        search.get_style_context().add_class("search-entry");
        search.search_changed.connect(() => {
            search_text = search.text.strip().down();
            filter.refilter();
        });
        bar.pack_start(search, true, true, 0);

        count_label = Ui.label("", "zt-count");
        count_label.margin_start = 6;
        bar.pack_start(count_label, false, false, 0);

        var pause = new Gtk.ToggleButton();
        pause.get_style_context().add_class("zt-icon-btn");
        pause.tooltip_text = "Pause table updates";
        pause_icon = new Gtk.Image.from_icon_name("media-playback-pause-symbolic", Gtk.IconSize.SMALL_TOOLBAR);
        pause.add(pause_icon);
        pause.toggled.connect(() => {
            paused = pause.active;
            pause_icon.set_from_icon_name(paused ? "media-playback-start-symbolic" : "media-playback-pause-symbolic",
                                          Gtk.IconSize.SMALL_TOOLBAR);
            if (!paused) refresh_wanted();
        });
        bar.pack_start(pause, false, false, 0);
        pack_start(bar, false, false, 0);
    }

    private void build_table() {
        var types = new Type[Col.N];
        for (int i = 0; i < Col.N; i++) types[i] = typeof(string);
        types[Col.PID] = typeof(int);
        for (int i = Col.ST_ROW; i < Col.N; i++) types[i] = typeof(int);
        flat_store = new Gtk.ListStore.newv(types);
        tree_store = new Gtk.TreeStore.newv(types);
        filter = new Gtk.TreeModelFilter(flat_store, null);
        filter.set_visible_func(row_visible);

        view = new Gtk.TreeView.with_model(filter);
        view.get_style_context().add_class("data-table");
        view.button_press_event.connect(on_button_press);
        view.get_selection().changed.connect(() => {
            if (rebuilding) return;
            Gtk.TreeModel m;
            Gtk.TreeIter it;
            selected_pid = view.get_selection().get_selected(out m, out it) ? pid_at(it) : -1;
        });
        view.row_expanded.connect((it, path) => { if (!rebuilding) expanded.add(pid_at(it)); });
        view.row_collapsed.connect((it, path) => { if (!rebuilding) expanded.remove(pid_at(it)); });

        columns = new Gtk.TreeViewColumn[TITLES.length];
        for (int i = 0; i < TITLES.length; i++) {
            int idx = i + 1;
            bool text_col = idx == Col.PROCESS || idx == Col.USER || idx == Col.STATUS;
            var r = new TableText(ctx.theme, text_col ? 0.0f : 1.0f, text_col ? null : ctx.tnum);
            var col = new Gtk.TreeViewColumn();
            col.title = TITLES[i];
            col.pack_start(r, true);
            int style_col;
            switch (idx) {
                case Col.PROCESS: style_col = Col.ST_NAME; break;
                case Col.CPU: style_col = Col.ST_CPU; break;
                case Col.MEMORY: style_col = Col.ST_MEM; break;
                case Col.DISKREAD: style_col = Col.ST_RD; break;
                case Col.DISKWRITE: style_col = Col.ST_WR; break;
                default: style_col = Col.ST_ROW; break;
            }
            if (idx == Col.PROCESS) r.bind_with_icon(col, idx, style_col, Col.BG, Col.PIN, ctx.pin_icon);
            else r.bind(col, idx, style_col, Col.BG);
            col.resizable = true;
            col.expand = idx == Col.PROCESS;
            col.clickable = true;
            col.clicked.connect(() => on_column_clicked(idx));
            view.append_column(col);
            columns[i] = col;
        }
        update_sort_indicators();

        var scroller = new Gtk.ScrolledWindow(null, null);
        scroller.vexpand = true;
        // 12px + the cells' 8px padding lines the first column up with the toolbar
        scroller.margin_start = 12;
        scroller.margin_end = 12;
        scroller.add(view);
        pack_start(scroller, true, true, 0);
    }

    private bool row_visible(Gtk.TreeModel model, Gtk.TreeIter it) {
        if (search_text == "") return true;
        Value v;
        model.get_value(it, Col.PID, out v);
        var r = current[(int) v];
        return r != null && r.name_key.contains(search_text);
    }

    private int pid_at(Gtk.TreeIter it) {
        Value v;
        filter.get_value(it, Col.PID, out v);
        return (int) v;
    }

    private void set_tree_mode(bool on) {
        tree_mode = on;
        search.sensitive = !on;
        if (on) { search.text = ""; search_text = ""; }
        flat_store.clear();
        slots.clear();
        selected_pid = -1;
        filter = new Gtk.TreeModelFilter(on ? (Gtk.TreeModel) tree_store : (Gtk.TreeModel) flat_store, null);
        filter.set_visible_func(row_visible);
        view.model = filter;
        refresh_wanted();
    }

    /* Theme colours changed. Cells hold ink codes, not colours: a redraw
     * picks up the new theme, nothing is rewritten. */
    public void invalidate() {
        view.queue_draw();
    }

    // ------------------------------------------------------------- sort

    private void on_column_clicked(int idx) {
        if (sort_column == idx) sort_reverse = !sort_reverse;
        else { sort_column = idx; sort_reverse = idx != Col.PROCESS && idx != Col.USER && idx != Col.STATUS; }
        update_sort_indicators();
        refresh_wanted();
    }

    private void update_sort_indicators() {
        for (int i = 0; i < columns.length; i++) {
            bool on = i + 1 == sort_column;
            columns[i].sort_indicator = on;
            if (on) columns[i].sort_order = sort_reverse ? Gtk.SortType.DESCENDING : Gtk.SortType.ASCENDING;
        }
    }

    /* Sorts by what is on screen (one decimal of CPU, the shown byte
     * figure), ties broken by pid. Invisible jitter can't reorder rows, and
     * a reorder makes GTK redraw the whole table. */
    private int compare_rows(ProcessRow a, ProcessRow b) {
        int c;
        switch (sort_column) {
            case Col.PROCESS: c = strcmp(a.name_key, b.name_key); break;
            case Col.USER: c = strcmp(a.user, b.user); break;
            case Col.STATUS: c = strcmp(a.status, b.status); break;
            case Col.STARTED: c = cmp_num(a.create_time, b.create_time); break;
            case Col.CPU: c = cmp_num(Math.round(a.cpu * 10), Math.round(b.cpu * 10)); break;
            case Col.CPUID: c = cmp_num(a.cpuid, b.cpuid); break;
            case Col.MEMORY: c = cmp_num(bytes_key((int64) a.mem), bytes_key((int64) b.mem)); break;
            case Col.DISKREADTOTAL: c = cmp_num(bytes_key(a.read_total), bytes_key(b.read_total)); break;
            case Col.DISKWRITETOTAL: c = cmp_num(bytes_key(a.write_total), bytes_key(b.write_total)); break;
            case Col.DISKREAD: c = cmp_num(bytes_key((int64) a.read_rate), bytes_key((int64) b.read_rate)); break;
            case Col.DISKWRITE: c = cmp_num(bytes_key((int64) a.write_rate), bytes_key((int64) b.write_rate)); break;
            case Col.PRIORITY: c = cmp_num(a.priority, b.priority); break;
            case Col.CPUTIME: c = cmp_num((int) a.cputime, (int) b.cputime); break;
            default: c = 0; break;
        }
        if (c != 0) return sort_reverse ? -c : c;
        return a.pid - b.pid; // stable, and the same in both directions: no flicker
    }

    private static int cmp_num(double a, double b) { return a < b ? -1 : (a > b ? 1 : 0); }

    /* Pinned rows first. Two small sorts instead of one sort with a
     * compound key: pins are rare. */
    private int[] ordered(Gee.Collection<ProcessRow> rows) {
        var pinned = new Gee.ArrayList<ProcessRow>();
        var rest = new Gee.ArrayList<ProcessRow>();
        foreach (var r in rows) (r.pinned ? pinned : rest).add(r);
        pinned.sort((a, b) => compare_rows(a, b));
        rest.sort((a, b) => compare_rows(a, b));
        var out_pids = new int[rows.size];
        int i = 0;
        foreach (var r in pinned) out_pids[i++] = r.pid;
        foreach (var r in rest) out_pids[i++] = r.pid;
        return out_pids;
    }

    // ------------------------------------------------------------- apply

    public void apply(Gee.ArrayList<ProcessRow> all) {
        var rows = new Gee.HashMap<int, ProcessRow>();
        var cfg = ctx.process_config;
        foreach (var r in all) {
            if (filter_mode == "mine" && r.user != ctx.current_user) continue;
            if (filter_mode == "active" && r.status != "running" && r.status != "sleeping") continue;
            r.pinned = cfg.is_pinned(r.name);
            r.highlight_color = cfg.highlight_color(r.name);
            rows[r.pid] = r;
        }
        current = rows;
        if (rows.size != last_count) {
            last_count = rows.size;
            count_label.label = "%d processes".printf(last_count);
        }
        if (tree_mode) apply_tree(rows); else apply_flat(rows);
    }

    /* Same text on screen = no write. Quantised the way the cells format. */
    private static bool same_display(ProcessRow a, ProcessRow b) {
        return a.ppid == b.ppid && a.cpuid == b.cpuid && a.priority == b.priority
            && a.pinned == b.pinned && a.status == b.status && a.user == b.user
            && a.highlight_color == b.highlight_color
            && Math.round(a.cpu * 10) == Math.round(b.cpu * 10)
            && (int) a.cputime == (int) b.cputime
            && bytes_key((int64) a.mem) == bytes_key((int64) b.mem)
            && bytes_key(a.read_total) == bytes_key(b.read_total)
            && bytes_key(a.write_total) == bytes_key(b.write_total)
            && bytes_key((int64) a.read_rate) == bytes_key((int64) b.read_rate)
            && bytes_key((int64) a.write_rate) == bytes_key((int64) b.write_rate)
            && a.started == b.started;
    }

    /* Changes exactly when Fmt.bytes() output changes (unit + one decimal). */
    private static int64 bytes_key(int64 n) {
        if (n < 0) return -1;
        double v = n;
        int unit = 0;
        while (v >= 1024.0 && unit < 5) { v /= 1024.0; unit++; }
        return unit * 100000000 + (int64) Math.round(v * 10);
    }

    private Value[] values_for(ProcessRow r) {
        string? bg = r.highlight_color;
        double mem_pct = r.mem * 100.0 / ctx.total_mem;
        bool cpu_hot = r.cpu >= CPU_HOT_FROM, mem_hot = mem_pct >= MEM_HOT_FROM;
        Ink row = Ink.DEFAULT, cpu, mem, rd, wr;
        if (bg != null) {
            // highlighted row: one readable ink for every cell on its colour
            row = cpu = mem = rd = wr = Fmt.contrast_ink(bg);
        } else {
            cpu = r.cpu < CPU_IDLE_BELOW ? Ink.IDLE : (cpu_hot ? Ink.HOT : Ink.DEFAULT);
            mem = mem_pct < MEM_IDLE_BELOW ? Ink.IDLE : (mem_hot ? Ink.HOT : Ink.DEFAULT);
            rd = r.read_rate > 0 ? Ink.DEFAULT : Ink.IDLE;
            wr = r.write_rate > 0 ? Ink.DEFAULT : Ink.IDLE;
        }
        Value[] v = {
            r.pid, r.name, r.user, "%.1f%%".printf(r.cpu), r.cpuid >= 0 ? r.cpuid.to_string() : "-",
            Fmt.bytes((int64) r.mem), Fmt.bytes(r.read_total), Fmt.bytes(r.write_total),
            Fmt.rate(r.read_rate), Fmt.rate(r.write_rate), r.priority.to_string(), r.status,
            r.started, Fmt.duration(r.cputime), bg, r.pinned ? ctx.pin_icon : null,
            cell_style(row), cell_style(row, r.pinned ? WEIGHT_SEMIBOLD : WEIGHT_NORMAL),
            cell_style(cpu, cpu_hot ? WEIGHT_BOLD : WEIGHT_NORMAL),
            cell_style(mem, mem_hot ? WEIGHT_BOLD : WEIGHT_NORMAL),
            cell_style(rd), cell_style(wr)
        };
        return v;
    }

    private void apply_flat(Gee.HashMap<int, ProcessRow> rows) {
        var order = ordered(rows.values);
        rebuilding = true;   // keep the selection handler quiet while slots move
        // grow or shrink the slot list to the row count (rows leave from the end)
        while (slots.size < order.length) {
            Gtk.TreeIter n;
            flat_store.append(out n);
            slots.add(null);
        }
        if (slots.size > order.length) {
            Gtk.TreeIter it;
            flat_store.iter_nth_child(out it, null, order.length);
            while (flat_store.remove(ref it)) {}
            while (slots.size > order.length) slots.remove_at(slots.size - 1);
        }
        int selected_slot = -1;
        Gtk.TreeIter it;
        bool ok = flat_store.get_iter_first(out it);
        for (int i = 0; ok && i < order.length; i++) {
            var r = rows[order[i]];
            var old = slots[i];
            if (old == null || old.pid != r.pid || !same_display(old, r)) {
                flat_store.set_valuesv(it, all_cols, values_for(r));
                slots[i] = r;
            }
            if (r.pid == selected_pid) selected_slot = i;
            ok = flat_store.iter_next(ref it);
        }
        follow_selection(selected_slot);
        rebuilding = false;
        if (!widths_locked) Idle.add(() => { lock_widths(); return false; });
    }

    /* Once the first real rows have been laid out, freeze each column at the
     * width GTK picked for them and switch to fixed-height mode: from then on
     * a changed row is redrawn without re-measuring its 13 cells, and nothing
     * is measured off-screen. Columns stay user-resizable. */
    private void lock_widths() {
        if (widths_locked || !view.get_realized()) return;
        widths_locked = true;
        for (int i = 0; i < columns.length; i++) {
            var col = columns[i];
            int w = col.width;
            col.sizing = Gtk.TreeViewColumnSizing.FIXED;
            // PROCESS keeps expanding into whatever is left; the rest get a
            // little room for wider values later ("1023.9MB" after "88.2MB")
            col.fixed_width = i == 0 ? 200 : w + 8;
        }
        view.fixed_height_mode = true;
        // GTK only recomputes the expanding column's share of spare width
        // after a row validation; without one it keeps the share it gave
        // the autosized layout, and the columns overflow the view. Asking
        // for a resize validates once and settles it.
        columns[0].queue_resize();
    }

    /* Move the highlight to wherever the selected process went. */
    private void follow_selection(int slot) {
        var sel = view.get_selection();
        if (slot < 0) {
            if (selected_pid >= 0) { sel.unselect_all(); selected_pid = -1; }
            return;
        }
        var path = filter.convert_child_path_to_path(new Gtk.TreePath.from_indices(slot));
        if (path != null && !sel.path_is_selected(path)) sel.select_path(path);
    }

    /* Full rebuild each tick: tree mode is occasional use, and reparenting-
     * aware diffing isn't worth the complexity. */
    private void apply_tree(Gee.HashMap<int, ProcessRow> rows) {
        rebuilding = true;
        tree_store.clear();
        var children = new Gee.HashMap<int, Gee.ArrayList<ProcessRow>>();
        var roots = new Gee.ArrayList<ProcessRow>();
        foreach (var r in rows.values) {
            if (r.ppid != r.pid && rows.has_key(r.ppid)) {
                var list = children[r.ppid];
                if (list == null) { list = new Gee.ArrayList<ProcessRow>(); children[r.ppid] = list; }
                list.add(r);
            } else {
                roots.add(r);
            }
        }
        var reopen = new Gee.ArrayList<Gtk.TreePath>();
        insert_nodes(null, ordered(roots), rows, children, reopen);
        // re-open what the user had open, parents first (insertion order)
        foreach (var child_path in reopen) {
            var path = filter.convert_child_path_to_path(child_path);
            if (path != null) view.expand_row(path, false);
        }
        rebuilding = false;
    }

    private void insert_nodes(Gtk.TreeIter? parent, int[] pids, Gee.HashMap<int, ProcessRow> rows,
                              Gee.HashMap<int, Gee.ArrayList<ProcessRow>> children,
                              Gee.ArrayList<Gtk.TreePath> reopen) {
        foreach (var pid in pids) {
            Gtk.TreeIter it;
            tree_store.append(out it, parent);
            tree_store.set_valuesv(it, all_cols, values_for(rows[pid]));
            var kids = children[pid];
            if (kids == null) continue;
            if (expanded.contains(pid)) reopen.add(tree_store.get_path(it));
            insert_nodes(it, ordered(kids), rows, children, reopen);
        }
    }

    // ------------------------------------------------------------- menu

    private bool on_button_press(Gdk.EventButton event) {
        if (event.button != 3) return false;
        Gtk.TreePath path;
        if (!view.get_path_at_pos((int) event.x, (int) event.y, out path, null, null, null)) return true;
        view.get_selection().unselect_all();
        view.get_selection().select_path(path);
        Gtk.TreeIter it;
        if (!filter.get_iter(out it, path)) return true;
        Value v;
        filter.get_value(it, Col.PID, out v);
        var row = current[(int) v];
        if (row != null) actions.popup(row, event);
        return true;
    }
}
