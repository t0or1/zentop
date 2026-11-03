/* tab_filesystems.vala -- partition table plus the disk breakdown
 * (treemap, or pie + legend). The table refreshes in place, so the
 * selected partition survives the 5 s refresh; the scan runs on its own
 * thread and can be cancelled. Complete scans are cached on disk: on start
 * the last analysed disk is selected and shown again, and selecting any
 * disk with a cached result shows it at once, with its age. */

const int FS_SCAN_TOP_N = 20; // tiles; the rest is grouped into "Others"

public class FilesystemsTab : Gtk.Box {
    private AppContext ctx;
    private Gtk.ListStore store;
    private Gtk.TreeView view;
    private Gtk.Button scan_button;
    private Gtk.Button cancel_button;
    private Gtk.Spinner spinner;
    private Gtk.Label status;
    private TreemapGraph treemap;
    private Gtk.Box pie_box;
    private PieGraph pie;
    private Legend legend;
    private Cancellable? scan_cancel = null;
    private string[] mount_order = new string[0];
    private ScanCache cache = new ScanCache();
    private Gee.HashMap<string, Partition> parts_now = new Gee.HashMap<string, Partition>();
    private bool restored = false;      // the last analysed disk has been re-selected once

    public FilesystemsTab(AppContext ctx) {
        Object(orientation: Gtk.Orientation.VERTICAL, spacing: 10);
        this.ctx = ctx;
        Ui.margins(this, 20, 20, 16, 20);
        build_table();
        build_breakdown();
    }

    private void build_table() {
        // device, mountpoint, type, total, used, free, used % (int)
        store = new Gtk.ListStore(7, typeof(string), typeof(string), typeof(string),
                                  typeof(string), typeof(string), typeof(string), typeof(int));
        view = new Gtk.TreeView.with_model(store);
        view.get_style_context().add_class("data-table");
        string[] titles = {"DEVICE", "MOUNTPOINT", "TYPE", "TOTAL", "USED", "FREE"};
        for (int i = 0; i < titles.length; i++) {
            var r = new TableText(ctx.theme, i < 3 ? 0.0f : 1.0f, i >= 3 ? ctx.tnum : null, 8, 4);
            var col = new Gtk.TreeViewColumn();
            col.title = titles[i];
            col.pack_start(r, true);
            r.bind(col, i);
            col.resizable = true;
            col.expand = i == 1;
            view.append_column(col);
        }
        // timetable style: the figure in tabular digits, then a thin bar
        var pct = new Gtk.TreeViewColumn();
        pct.title = "USED %";
        var pct_text = new TableText(ctx.theme, 1.0f, ctx.tnum);
        pct.pack_start(pct_text, false);
        pct.set_cell_data_func(pct_text, (c, cell, model, it) => {
            Value v;
            model.get_value(it, 6, out v);
            pct_text.set_text("%d%%".printf((int) v));
        });
        var pct_bar = new Gtk.CellRendererProgress();
        pct_bar.text = "";
        pct_bar.set_fixed_size(-1, 4);  // never sets the row height...
        pct_bar.set_padding(4, 8);      // ...and leaves a ~7px bar centred in it
        pct.pack_start(pct_bar, true);
        pct.add_attribute(pct_bar, "value", 6);
        pct.min_width = 160;
        view.append_column(pct);
        view.get_selection().changed.connect(on_selection_changed);
        var scroller = new Gtk.ScrolledWindow(null, null);
        scroller.set_size_request(-1, 170);
        scroller.add(view);
        pack_start(scroller, false, false, 0);
    }

    private void build_breakdown() {
        var heading = Ui.section_label("DISK USAGE BREAKDOWN");
        heading.margin_top = 14;
        pack_start(heading, false, false, 0);

        var bar = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
        scan_button = Ui.text_button("ANALYZE SELECTED DISK");
        scan_button.clicked.connect(start_scan);
        bar.pack_start(scan_button, false, false, 0);
        cancel_button = Ui.text_button("CANCEL");
        cancel_button.clicked.connect(() => { if (scan_cancel != null) scan_cancel.cancel(); });
        cancel_button.no_show_all = true;
        bar.pack_start(cancel_button, false, false, 0);
        var pie_toggle = new Gtk.ToggleButton.with_label("PIE VIEW");
        pie_toggle.get_style_context().add_class("tree-toggle");
        pie_toggle.toggled.connect(() => {
            treemap.visible = !pie_toggle.active;
            pie_box.visible = pie_toggle.active;
        });
        bar.pack_start(pie_toggle, false, false, 0);
        spinner = new Gtk.Spinner();
        bar.pack_start(spinner, false, false, 0);
        status = Ui.label("Select a partition above, then ANALYZE SELECTED DISK.", "bar-label");
        status.ellipsize = Pango.EllipsizeMode.END;
        bar.pack_start(status, true, true, 0);
        pack_start(bar, false, false, 4);

        var viz = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
        viz.vexpand = true;
        treemap = new TreemapGraph(ctx.theme);
        treemap.vexpand = true;
        viz.pack_start(treemap, true, true, 0);
        pie_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 24);
        pie_box.vexpand = true;
        pie = new PieGraph(ctx.theme);
        pie.hexpand = true;
        pie.vexpand = true;
        pie_box.pack_start(pie, true, true, 0);
        var legend_scroller = new Gtk.ScrolledWindow(null, null);
        legend_scroller.set_size_request(320, -1);
        legend_scroller.vexpand = true;
        legend = new Legend(ctx, FS_SCAN_TOP_N + 1);
        legend_scroller.add(legend);
        pie_box.pack_start(legend_scroller, false, false, 0);
        pie_box.show_all();
        pie_box.no_show_all = true;   // starts hidden; PIE VIEW reveals it
        pie_box.hide();
        viz.pack_start(pie_box, true, true, 0);
        pack_start(viz, true, true, 0);
    }

    /* In place while the mount list is unchanged, so the selection stays. */
    public void refresh() {
        var parts = FsData.partitions();
        parts_now.clear();
        foreach (var p in parts) parts_now[p.mountpoint] = p;
        var order = new string[parts.size];
        for (int i = 0; i < parts.size; i++) order[i] = parts[i].mountpoint;
        bool same = order.length == mount_order.length;
        for (int i = 0; same && i < order.length; i++) same = order[i] == mount_order[i];
        Gtk.TreeIter it;
        if (!same) {
            store.clear();
            for (int i = 0; i < parts.size; i++) store.append(out it);
            mount_order = order;
        }
        if (!store.get_iter_first(out it)) return;
        foreach (var p in parts) {
            // unchanged figures = no write: a write redraws (and re-measures) the row
            string used = Fmt.bytes((int64) p.used), free = Fmt.bytes((int64) p.free);
            Value old_used, old_free, old_pct;
            store.get_value(it, 4, out old_used);
            store.get_value(it, 5, out old_free);
            store.get_value(it, 6, out old_pct);
            if (!same || (string?) old_used != used || (string?) old_free != free || (int) old_pct != (int) p.percent)
                store.set(it, 0, p.device, 1, p.mountpoint, 2, p.fstype,
                          3, Fmt.bytes((int64) p.total), 4, used, 5, free, 6, (int) p.percent, -1);
            store.iter_next(ref it);
        }
        if (!restored) restore_last();
    }

    /* First fill of the table: select the disk analysed last time, which
     * shows its cached breakdown through on_selection_changed. */
    private void restore_last() {
        restored = true;
        if (cache.last == null) return;
        int i = 0;
        foreach (var mp in mount_order) {
            if (mp == cache.last) {
                view.get_selection().select_path(new Gtk.TreePath.from_indices(i));
                return;
            }
            i++;
        }
    }

    private string? selected_mountpoint() {
        Gtk.TreeModel model;
        Gtk.TreeIter it;
        if (!view.get_selection().get_selected(out model, out it)) return null;
        Value v;
        model.get_value(it, 1, out v);
        return (string) v;
    }

    /* Show the cached result for the selected disk, or say there is none. */
    private void on_selection_changed() {
        if (scan_cancel != null) return;           // a scan is running: its status stays
        string? mp = selected_mountpoint();
        if (mp == null) return;
        var c = cache.get_scan(mp);
        if (c == null) {
            show_entries(new Gee.ArrayList<ScanEntry>());
            status.label = "%s hasn't been analysed yet: press ANALYZE SELECTED DISK.".printf(mp);
            return;
        }
        show_entries(c.entries);
        string line = "%s: %s, analysed %s (took %.1fs).".printf(
            mp, items(c.entries.size), ScanCache.age(c.scanned_at), c.seconds);
        // flag results the disk has since moved away from
        var p = parts_now[mp];
        if (p != null) {
            int64 delta = (int64) p.used - (int64) c.used_then;
            uint64 threshold = uint64.max(p.total / 100, 50 * 1024 * 1024);   // 1% of the disk, at least 50 MB
            if ((uint64) (delta < 0 ? -delta : delta) >= threshold)
                line += " Usage changed by %s%s since; analyse again for current sizes.".printf(
                    delta > 0 ? "+" : "-", Fmt.bytes(delta < 0 ? -delta : delta));
        }
        status.label = line;
    }

    private static string items(int n) {
        return n == 1 ? "1 top-level item" : "%d top-level items".printf(n);
    }

    /* Top tiles plus one "Others" for the rest; entries arrive biggest first. */
    private void show_entries(Gee.List<ScanEntry> entries) {
        int top = int.min(FS_SCAN_TOP_N, entries.size);
        uint64 others = 0;
        int other_items = 0;
        for (int i = top; i < entries.size; i++) { others += entries[i].size; other_items++; }
        var shown = new ScanEntry[top + (others > 0 ? 1 : 0)];
        for (int i = 0; i < top; i++) shown[i] = entries[i];
        if (others > 0) shown[top] = new ScanEntry("Others (%d items)".printf(other_items), others, false);
        treemap.set_entries(shown);
        var slices = new Slice[shown.length];
        for (int i = 0; i < shown.length; i++) slices[i] = new Slice(shown[i].name, (double) shown[i].size);
        if (others > 0) slices[top].other = true;
        pie.set_slices(slices);
        legend.update(slices, true);
    }

    private void start_scan() {
        if (scan_cancel != null) return;
        Gtk.TreeModel model;
        Gtk.TreeIter it;
        if (!view.get_selection().get_selected(out model, out it)) {
            ctx.show_error("Select a partition from the table above first.");
            return;
        }
        Value v;
        model.get_value(it, 1, out v);
        string mountpoint = (string) v;
        var cancel = new Cancellable();
        scan_cancel = cancel;
        scan_button.sensitive = false;
        cancel_button.show();
        spinner.start();
        status.label = "Scanning %s... this can take a while on a big disk.".printf(mountpoint);
        // pure filesystem walk; no GTK calls on that thread
        new Thread<void*>("fs-scan", () => {
            var timer = new Timer();
            var entries = FsData.scan(mountpoint, cancel);
            double elapsed = timer.elapsed();
            Idle.add(() => { scan_done(entries, mountpoint, elapsed, cancel.is_cancelled()); return false; });
            return null;
        });
    }

    private void scan_done(Gee.ArrayList<ScanEntry>? entries, string mountpoint, double elapsed, bool cancelled) {
        scan_cancel = null;
        scan_button.sensitive = true;
        cancel_button.hide();
        spinner.stop();
        if (entries == null) {
            status.label = "Couldn't read %s (permission denied?).".printf(mountpoint);
            return;
        }
        entries.sort((a, b) => a.size < b.size ? 1 : (a.size > b.size ? -1 : 0));
        show_entries(entries);
        if (cancelled) {
            // partial: shown, but never cached over a complete result
            status.label = "Cancelled, partial results for %s (not saved).".printf(mountpoint);
            return;
        }
        var p = parts_now[mountpoint];
        cache.put(mountpoint, entries, elapsed, p != null ? p.used : 0);
        status.label = "%s: %s scanned in %.1fs. Saved for next time.".printf(
            mountpoint, items(entries.size), elapsed);
    }

    public void cancel_scan() {
        if (scan_cancel != null) scan_cancel.cancel();
    }

    public void redraw() {
        treemap.queue_draw();
        pie.queue_draw();
        legend.redraw_swatches();
    }
}
