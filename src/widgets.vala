/* widgets.vala -- Legend: a fixed set of rows (swatch, name, figure) built
 * once. An update only sets label text and shows or hides rows; no widget
 * is created or destroyed per tick. */

public class Legend : Gtk.Box {
    private Gtk.Box[] rows;
    private Gtk.Label[] names;
    private Gtk.Label[] values;
    private ColorChip[] chips;

    public Legend(AppContext ctx, int count) {
        Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);
        rows = new Gtk.Box[count];
        names = new Gtk.Label[count];
        values = new Gtk.Label[count];
        chips = new ColorChip[count];
        for (int i = 0; i < count; i++) {
            var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 10);
            row.get_style_context().add_class("zt-theme-row");
            chips[i] = new ColorChip.for_role(ctx.theme, SERIES[i % 8]);
            names[i] = Ui.label("", "props-value");
            names[i].ellipsize = Pango.EllipsizeMode.END;
            values[i] = Ui.label("", "props-value", 1);
            values[i].attributes = ctx.tnum;
            row.pack_start(chips[i], false, false, 0);
            row.pack_start(names[i], true, true, 0);
            row.pack_start(values[i], false, false, 0);
            row.show_all();
            row.no_show_all = true;   // hidden until it has data
            row.hide();
            pack_start(row, false, false, 0);
            rows[i] = row;
        }
    }

    /* Percent of the slices' total, or byte sizes. */
    public void update(Slice[] slices, bool as_bytes = false) {
        double total = 0;
        foreach (var s in slices) total += s.value;
        if (total <= 0) total = 1;
        for (int i = 0; i < rows.length; i++) {
            if (i < slices.length) {
                unowned string role = Slice.role_for(slices, i);
                if (chips[i].role != role) { chips[i].role = role; chips[i].queue_draw(); }
                Ui.set_text(names[i], slices[i].label);
                Ui.set_text(values[i], as_bytes ? Fmt.bytes((int64) slices[i].value)
                                                : "%.1f%%".printf(slices[i].value / total * 100));
                if (!rows[i].visible) rows[i].show();
            } else if (rows[i].visible) {
                rows[i].hide();
            }
        }
    }

    public void redraw_swatches() {
        foreach (var c in chips) c.queue_draw();
    }
}
