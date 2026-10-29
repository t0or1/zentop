/* graphs.vala -- every Cairo widget: HistoryGraph (Resources), PieGraph,
 * ColorChip and TreemapGraph. Colours are looked up from ThemeColors at
 * draw time, so a theme switch is a redraw, never a rebuild. Nothing here
 * allocates per tick. */

public const int HISTORY_LEN = 60; // ~1 minute at 1 s ticks
public const string[] SERIES = {"s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7"};

public class HistoryGraph : Gtk.DrawingArea {
    private ThemeColors theme;
    private string[] roles;
    private double[,] data;   // [series, slot]
    private int count = 0;    // samples stored, up to HISTORY_LEN
    private int head = 0;     // next slot to write
    private double y_max;
    private bool auto_scale;

    public HistoryGraph(ThemeColors theme, string[] roles, double y_max = 100.0, bool auto_scale = false, int height = 120) {
        this.theme = theme;
        this.roles = roles;
        this.y_max = y_max;
        this.auto_scale = auto_scale;
        data = new double[roles.length, HISTORY_LEN];
        set_size_request(-1, height);
    }

    public void push(double[] values) {
        for (int s = 0; s < roles.length && s < values.length; s++) data[s, head] = values[s];
        head = (head + 1) % HISTORY_LEN;
        if (count < HISTORY_LEN) count++;
        queue_draw();
    }

    private double at(int s, int i) {
        // i = 0 is the oldest stored sample
        return data[s, (head - count + i + 2 * HISTORY_LEN) % HISTORY_LEN];
    }

    private static void set_rgb(Cairo.Context cr, Gdk.RGBA c, double alpha = 1.0) {
        cr.set_source_rgba(c.red, c.green, c.blue, alpha);
    }

    public override bool draw(Cairo.Context cr) {
        int w = get_allocated_width();
        int h = get_allocated_height();
        set_rgb(cr, theme.get_role("g-bg"));
        cr.paint();
        // three hairlines on half pixels so they stay crisp
        set_rgb(cr, theme.get_role("g-grid"));
        cr.set_line_width(1);
        for (int i = 1; i < 4; i++) {
            double y = (int) (h * i / 4.0) + 0.5;
            cr.move_to(0, y);
            cr.line_to(w, y);
        }
        cr.stroke();
        if (count < 2) return false;

        double top = y_max;
        if (auto_scale) {
            double m = 0;
            for (int s = 0; s < roles.length; s++)
                for (int i = 0; i < count; i++) m = double.max(m, at(s, i));
            top = double.max(m * 1.25, 1);
        }
        double step = (double) w / (HISTORY_LEN - 1);
        double x0 = w - (count - 1) * step; // newest sample on the right edge
        double scale = h / top;

        for (int s = 0; s < roles.length; s++) {
            var c = theme.get_role(roles[s]);
            cr.move_to(x0, h);
            for (int i = 0; i < count; i++) cr.line_to(x0 + i * step, h - double.min(at(s, i), top) * scale);
            cr.line_to(x0 + (count - 1) * step, h);
            cr.close_path();
            set_rgb(cr, c, 0.16);
            cr.fill();
            for (int i = 0; i < count; i++) {
                double x = x0 + i * step, y = h - double.min(at(s, i), top) * scale;
                if (i == 0) cr.move_to(x, y); else cr.line_to(x, y);
            }
            set_rgb(cr, c);
            cr.set_line_width(1.5);
            cr.stroke();
        }
        return false;
    }
}

/* One slice of a pie: a label and a non-negative value. */
public class Slice {
    public string label;
    public double value;
    public Slice(string label, double value) { this.label = label; this.value = value; }
}

/* Ring of wedges, coloured s0..s7 from the theme. Gaps between wedges are
 * drawn in the ground colour, with a hollow centre, so it reads as a ring
 * of figures instead of a candy pie. The legend is plain GTK labels. */
public class PieGraph : Gtk.DrawingArea {
    private ThemeColors theme;
    private Slice[] slices = new Slice[0];

    public PieGraph(ThemeColors theme) {
        this.theme = theme;
        set_size_request(-1, 320);
    }

    public void set_slices(Slice[] data) {
        slices = data;
        queue_draw();
    }

    public override bool draw(Cairo.Context cr) {
        int w = get_allocated_width();
        int h = get_allocated_height();
        double cx = w / 2.0, cy = h / 2.0;
        double radius = double.max(double.min(w, h) / 2.0 - 12, 1);
        double total = 0;
        foreach (var s in slices) total += s.value;
        if (total <= 0) return false;

        double a = -Math.PI / 2; // 12 o'clock
        for (int i = 0; i < slices.length; i++) {
            double b = a + slices[i].value / total * 2 * Math.PI;
            var c = theme.get_role(SERIES[i % 8]);
            cr.set_source_rgb(c.red, c.green, c.blue);
            cr.move_to(cx, cy);
            cr.arc(cx, cy, radius, a, b);
            cr.close_path();
            cr.fill();
            a = b;
        }
        var g = theme.get_role("bg");
        cr.set_source_rgb(g.red, g.green, g.blue);
        if (slices.length > 1) {
            cr.set_line_width(2);
            a = -Math.PI / 2;
            foreach (var s in slices) {
                cr.move_to(cx, cy);
                cr.line_to(cx + radius * Math.cos(a), cy + radius * Math.sin(a));
                a += s.value / total * 2 * Math.PI;
            }
            cr.stroke();
        }
        cr.arc(cx, cy, radius * 0.58, 0, 2 * Math.PI);
        cr.fill();
        return false;
    }
}

/* Small colour swatch drawn with Cairo: changing colour is a redraw, not a
 * stylesheet parse. With an outline role it gets a hairline, for swatches
 * that might match the ground. */
public class ColorChip : Gtk.DrawingArea {
    private ThemeColors theme;
    public string role;               // theme role ("s3"), or "" for a fixed colour
    private Gdk.RGBA fixed_color;
    private bool outline;

    public ColorChip.for_role(ThemeColors theme, string role, int size = 10) {
        this.theme = theme;
        this.role = role;
        set_size_request(size, size);
        valign = Gtk.Align.CENTER;
    }

    public ColorChip.fixed(ThemeColors theme, string hex, int size = 16, bool outline = true) {
        this.theme = theme;
        this.role = "";
        fixed_color = Gdk.RGBA();
        fixed_color.parse(hex);
        this.outline = outline;
        set_size_request(size, size);
        valign = Gtk.Align.CENTER;
    }

    public override bool draw(Cairo.Context cr) {
        int w = get_allocated_width(), h = get_allocated_height();
        Gdk.RGBA c = role != "" ? theme.get_role(role) : fixed_color;
        cr.set_source_rgb(c.red, c.green, c.blue);
        cr.rectangle(0, 0, w, h);
        cr.fill();
        if (outline) {
            var ink = theme.get_role("ink");
            cr.set_source_rgba(ink.red, ink.green, ink.blue, 0.35);
            cr.set_line_width(1);
            cr.rectangle(0.5, 0.5, w - 1, h - 1);
            cr.stroke();
        }
        return false;
    }
}

/* ---------------------------------------------------------- treemap
 * Squarified layout (Bruls, Huizing, van Wijk 1999): rectangles sized by
 * value while keeping aspect ratios close to square. */

public struct Rect { public double x; public double y; public double w; public double h; }

namespace Squarify {
    private Rect[] layout(double[] sizes, int from, int to, double x, double y, double dx, double dy) {
        double covered = 0;
        for (int i = from; i < to; i++) covered += sizes[i];
        var rects = new Rect[to - from];
        if (dx >= dy) {
            double width = dy > 0 ? covered / dy : 0, cy = y;
            for (int i = from; i < to; i++) {
                double h = width > 0 ? sizes[i] / width : 0;
                rects[i - from] = Rect() { x = x, y = cy, w = width, h = h };
                cy += h;
            }
        } else {
            double height = dx > 0 ? covered / dx : 0, cx = x;
            for (int i = from; i < to; i++) {
                double w = height > 0 ? sizes[i] / height : 0;
                rects[i - from] = Rect() { x = cx, y = y, w = w, h = height };
                cx += w;
            }
        }
        return rects;
    }

    private double worst(double[] sizes, int from, int to, double x, double y, double dx, double dy) {
        double worst = 0;
        foreach (var r in layout(sizes, from, to, x, y, dx, dy)) {
            if (r.w <= 0 || r.h <= 0) return double.INFINITY;
            worst = double.max(worst, r.w > r.h ? r.w / r.h : r.h / r.w);
        }
        return worst;
    }

    /* sizes must already be scaled so they sum to dx*dy, sorted descending,
     * all > 0. Iterative: one row (or column) per pass. */
    public Rect[] squarify(double[] sizes, double x, double y, double dx, double dy) {
        var result = new Rect[0];
        int start = 0;
        while (start < sizes.length) {
            int end = start + 1;
            while (end < sizes.length &&
                   worst(sizes, start, end + 1, x, y, dx, dy) <= worst(sizes, start, end, x, y, dx, dy)) end++;
            foreach (var r in layout(sizes, start, end, x, y, dx, dy)) result += r;
            double covered = 0;
            for (int i = start; i < end; i++) covered += sizes[i];
            if (dx >= dy) { double w = dy > 0 ? covered / dy : 0; x += w; dx -= w; }
            else { double h = dx > 0 ? covered / dx : 0; y += h; dy -= h; }
            start = end;
        }
        return result;
    }
}

/* WizTree-style map of a disk scan. Folders take the series colours;
 * loose files read one step quieter. Labels only where they fit, with the
 * ink picked per tile for contrast. */
public class TreemapGraph : Gtk.DrawingArea {
    private ThemeColors theme;
    private ScanEntry[] entries = new ScanEntry[0];
    private Pango.FontDescription name_font = Pango.FontDescription.from_string("Inter 9");
    private Rect[] rects = new Rect[0];   // layout cache: redone only on resize or new data
    private int laid_w = -1;
    private int laid_h = -1;

    public TreemapGraph(ThemeColors theme) {
        this.theme = theme;
        set_size_request(-1, 380);
    }

    public void set_entries(ScanEntry[] data) {
        entries = data;
        laid_w = -1;
        queue_draw();
    }

    private static double lum(Gdk.RGBA c) { return 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue; }

    public override bool draw(Cairo.Context cr) {
        int w = get_allocated_width(), h = get_allocated_height();
        var gbg = theme.get_role("g-bg");
        cr.set_source_rgb(gbg.red, gbg.green, gbg.blue);
        cr.paint();
        if (entries.length == 0 || w <= 0 || h <= 0) return false;

        if (w != laid_w || h != laid_h) {
            double total = 0;
            foreach (var e in entries) total += (double) e.size;
            if (total <= 0) return false;
            var sizes = new double[entries.length];
            for (int i = 0; i < entries.length; i++) sizes[i] = (double) entries[i].size * w * h / total;
            rects = Squarify.squarify(sizes, 0, 0, w, h);
            laid_w = w;
            laid_h = h;
        }

        var dark = theme.get_role("bg");
        var layout = create_pango_layout("");
        layout.set_font_description(name_font);
        layout.set_ellipsize(Pango.EllipsizeMode.END);
        for (int i = 0; i < rects.length && i < entries.length; i++) {
            var r = rects[i];
            Gdk.RGBA tile = theme.get_role(SERIES[i % 8]);
            if (!entries[i].is_dir) {
                tile.red = tile.red * 0.7 + gbg.red * 0.3;
                tile.green = tile.green * 0.7 + gbg.green * 0.3;
                tile.blue = tile.blue * 0.7 + gbg.blue * 0.3;
            }
            cr.set_source_rgb(tile.red, tile.green, tile.blue);
            // 1px ground gutter between tiles instead of a stroked border
            cr.rectangle(r.x + 0.5, r.y + 0.5, double.max(r.w - 1, 0), double.max(r.h - 1, 0));
            cr.fill();
            if (r.w > 42 && r.h > 20) {
                Gdk.RGBA ink = Gdk.RGBA() { red = 1, green = 1, blue = 1, alpha = 1 };
                if (lum(tile) > 0.5) ink = dark;
                layout.set_width((int) ((r.w - 12) * Pango.SCALE));
                cr.save();
                cr.rectangle(r.x, r.y, r.w, r.h);
                cr.clip();
                cr.set_source_rgb(ink.red, ink.green, ink.blue);
                layout.set_text(entries[i].name, -1);
                cr.move_to(r.x + 6, r.y + 4);
                Pango.cairo_show_layout(cr, layout);
                if (r.h > 38) {
                    cr.set_source_rgba(ink.red, ink.green, ink.blue, 0.78);
                    layout.set_text(Fmt.bytes((int64) entries[i].size), -1);
                    cr.move_to(r.x + 6, r.y + 19);
                    Pango.cairo_show_layout(cr, layout);
                }
                cr.restore();
            }
        }
        return false;
    }
}
