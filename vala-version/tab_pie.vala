/* tab_pie.vala -- the top consumers as a ring. Fed by the same process
 * scan as the table (no second pass over /proc). */

const int PIE_TOP_N = 10; // wedges; the rest is grouped into "Others"

public class PieTab : Gtk.Box {
    private PieGraph pie;
    private Legend legend;
    private uint64 total_mem;

    public PieTab(AppContext ctx) {
        Object(orientation: Gtk.Orientation.HORIZONTAL, spacing: 32);
        total_mem = ctx.total_mem;
        Ui.margins(this, 20, 20, 20, 20);
        pie = new PieGraph(ctx.theme);
        pie.hexpand = true;
        pie.vexpand = true;
        pack_start(pie, true, true, 0);
        var side = new Gtk.Box(Gtk.Orientation.VERTICAL, 10);
        side.set_size_request(320, -1);
        side.pack_start(Ui.section_label("TOP CONSUMERS  ·  CPU% + MEM%"), false, false, 0);
        legend = new Legend(ctx, PIE_TOP_N + 1);
        side.pack_start(legend, false, false, 0);
        pack_start(side, false, false, 0);
    }

    /* Overall consumption = CPU% + memory% of total RAM. Both are 0-100,
     * so a plain sum is a fair "how much of the machine" score. */
    public void apply(Gee.ArrayList<ProcessRow> rows) {
        var scored = new Gee.ArrayList<Slice>();
        foreach (var r in rows) {
            double score = r.cpu + r.mem * 100.0 / total_mem;
            if (score > 0) scored.add(new Slice(r.name, score));
        }
        scored.sort((a, b) => a.value < b.value ? 1 : (a.value > b.value ? -1 : 0));
        int top = int.min(PIE_TOP_N, scored.size);
        double others = 0;
        for (int i = top; i < scored.size; i++) others += scored[i].value;
        bool with_others = others > 0.05;
        var slices = new Slice[top + (with_others ? 1 : 0)];
        for (int i = 0; i < top; i++) slices[i] = scored[i];
        if (with_others) slices[top] = new Slice("Others (%d)".printf(scored.size - top), others);
        // same names and the same one-decimal percentages = same picture
        string key = slices_key(slices);
        if (key == last_key) return;
        last_key = key;
        pie.set_slices(slices);
        legend.update(slices);
    }

    private string last_key = "";

    private static string slices_key(Slice[] slices) {
        double total = 0;
        foreach (var sl in slices) total += sl.value;
        var b = new StringBuilder();
        foreach (var sl in slices) b.append_printf("%s\x1f%.0f\x1e", sl.label, total > 0 ? sl.value / total * 1000 : 0);
        return b.str;
    }

    public void redraw() {
        last_key = "";
        pie.queue_draw();
        legend.redraw_swatches();
    }
}
