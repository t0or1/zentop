/* table_text.vala -- the text cell every table uses.
 *
 * The stock GtkCellRendererText is the expensive part of a table redraw.
 * Per cell and per draw it maps each bound model column onto a GObject
 * property (lookup by name, copy, notify), then builds a new PangoLayout,
 * shapes it with HarfBuzz and measures it -- for a figure like "0.0%" that
 * was already on screen a second ago. Measured: a full redraw of the
 * process table cost ~15 ms; the shaping and property traffic was ~3/4.
 *
 * TableText takes its values through plain fields set by one cell data
 * function (no properties), and keeps the shaped layout of every
 * (text, weight) it has drawn. Ink is not part of the layout: it is a code
 * resolved against the theme at draw time, so idle, hot, highlighted and
 * selected ink all share one layout, and a theme switch needs no rewrite.
 *
 * A cell can carry a small symbolic icon right after its text (the pin on
 * a pinned process), drawn in the cell's own ink. One renderer per column
 * keeps GTK from measuring every row's cells again while it draws.
 *
 * Single line only, no ellipsizing: a cell that overflows is clipped.
 * Table text is not exposed to accessibility tools. */

/* What colour a cell's text takes. DEFAULT follows the table's own CSS
 * colour (and its selected state); the rest come from the theme. */
public enum Ink { DEFAULT, IDLE, HOT, BLACK, WHITE, N }

/* A cell's look as one model int: ink in the low bits, weight / 100 above. */
public int cell_style(Ink ink, int weight = 400) {
    return (int) ink | ((weight / 100) << 4);
}

public class TableText : Gtk.CellRenderer {
    private const uint MAX_LAYOUTS = 600;   // per column; the cache restarts when full
    private const int ICON_SIZE = 16;
    private const int ICON_GAP = 6;

    [Compact]
    private class Shaped {
        public Pango.Layout layout;
        public int width;     // logical, px
        public int height;
    }

    // set by the data function before each measure or draw
    public Value text_value;
    public int style = 0;
    public bool has_bg = false;
    public Gdk.RGBA bg;
    public bool has_icon = false;

    private unowned ThemeColors theme;
    private Pango.AttrList? attrs;
    private float align;
    private int pad_x;
    private int pad_y;

    // one table per weight (index weight / 100), keyed by the text
    private HashTable<string, Shaped>?[] shaped = new HashTable<string, Shaped>?[10];
    private uint shaped_count = 0;
    private unowned Pango.Context? pango = null;
    private uint pango_serial = 0;

    // DEFAULT ink per widget state (normal, selected, backdrop...), for one
    // style generation: a CSS lookup per cell otherwise
    private Gtk.StateFlags[] ink_state = new Gtk.StateFlags[4];
    private Gdk.RGBA[] ink_rgba = new Gdk.RGBA[4];
    private int ink_used = 0;
    private uint ink_generation = 0;

    private string? icon_name = null;
    // the icon, recoloured per ink: "rgba(...)@scale" -> surface
    private HashTable<string, Cairo.Surface> icons = new HashTable<string, Cairo.Surface>(str_hash, str_equal);

    public TableText(ThemeColors theme, float align, Pango.AttrList? attrs = null, int pad_x = 8, int pad_y = 3) {
        this.theme = theme;
        this.align = align;
        this.attrs = attrs;
        this.pad_x = pad_x;
        this.pad_y = pad_y;
        set_padding(pad_x, pad_y);
    }

    /* Text from `text_col`; ink and weight from `style_col` (a cell_style()
     * int) and a highlight "#RRGGBB" from `bg_col`, when given (>= 0). */
    public void bind(Gtk.TreeViewColumn col, int text_col, int style_col = -1, int bg_col = -1) {
        bind_with_icon(col, text_col, style_col, bg_col, -1, null);
    }

    /* As bind(), plus `icon` (a symbolic icon name) after the text on rows
     * whose `icon_col` (a string column) is not null. */
    public void bind_with_icon(Gtk.TreeViewColumn col, int text_col, int style_col, int bg_col,
                               int icon_col, string? icon) {
        icon_name = icon;
        col.set_cell_data_func(this, (c, cell, model, it) => {
            model.get_value(it, text_col, out text_value);
            if (style_col >= 0) {
                Value v;
                model.get_value(it, style_col, out v);
                style = v.get_int();
            }
            if (bg_col >= 0) {
                Value v;
                model.get_value(it, bg_col, out v);
                unowned string? hex = v.get_string();
                has_bg = hex != null && bg.parse(hex);
            }
            if (icon_col >= 0 && icon_name != null) {
                Value v;
                model.get_value(it, icon_col, out v);
                has_icon = v.get_string() != null;
            }
        });
    }

    /* For cells whose text isn't a model column (a formatted figure). */
    public void set_text(string? t) {
        if (!text_value.holds(typeof(string))) text_value = Value(typeof(string));
        text_value.set_string(t);
    }

    private unowned Shaped shape(Gtk.Widget widget) {
        var ctx = widget.get_pango_context();
        if (ctx != pango || ctx.get_serial() != pango_serial) {
            // font, size or screen changed: every kept layout is stale
            forget();
            pango = ctx;
            pango_serial = ctx.get_serial();
        }
        unowned string t = text_value.holds(typeof(string)) ? (text_value.get_string() ?? "") : "";
        int w = ((style >> 4) & 0xF) * 100;
        if (w == 0) w = 400;
        var table = shaped[w / 100];
        if (table == null) {
            table = new HashTable<string, Shaped>(str_hash, str_equal);
            shaped[w / 100] = table;
        }
        unowned Shaped? hit = table.lookup(t);
        if (hit != null) return hit;
        if (shaped_count >= MAX_LAYOUTS) forget();
        shaped_count++;
        var s = new Shaped();
        s.layout = widget.create_pango_layout(t);
        var list = attrs != null ? attrs.copy() : new Pango.AttrList();
        if (w != 400) list.insert(Pango.attr_weight_new((Pango.Weight) w));
        s.layout.set_attributes(list);
        Pango.Rectangle logical;
        s.layout.get_pixel_extents(null, out logical);
        s.width = logical.width;
        s.height = logical.height;
        table.insert(t, (owned) s);
        return table.lookup(t);
    }

    private void forget() {
        foreach (var t in shaped) if (t != null) t.remove_all();
        shaped_count = 0;
    }

    private Gdk.RGBA ink(Gtk.Widget widget) {
        int code = style & 0xF;
        if (code != Ink.DEFAULT && code < Ink.N) return theme.inks[code];
        var sc = widget.get_style_context();
        var state = sc.get_state();
        if (ink_generation != theme.generation) {
            ink_used = 0;
            ink_generation = theme.generation;
        }
        for (int i = 0; i < ink_used; i++) if (ink_state[i] == state) return ink_rgba[i];
        var c = sc.get_color(state);
        int slot = ink_used < ink_state.length ? ink_used++ : 0;
        ink_state[slot] = state;
        ink_rgba[slot] = c;
        return c;
    }

    public override Gtk.SizeRequestMode get_request_mode() {
        return Gtk.SizeRequestMode.CONSTANT_SIZE;
    }

    public override void get_preferred_width(Gtk.Widget widget, out int minimum, out int natural) {
        minimum = natural = shape(widget).width + 2 * pad_x + (has_icon ? ICON_GAP + ICON_SIZE : 0);
    }

    public override void get_preferred_height(Gtk.Widget widget, out int minimum, out int natural) {
        minimum = natural = int.max(shape(widget).height + 2 * pad_y, icon_name != null ? ICON_SIZE : 0);
    }

    public override void get_preferred_height_for_width(Gtk.Widget widget, int width,
                                                         out int minimum, out int natural) {
        get_preferred_height(widget, out minimum, out natural);
    }

    public override void get_preferred_width_for_height(Gtk.Widget widget, int height,
                                                         out int minimum, out int natural) {
        get_preferred_width(widget, out minimum, out natural);
    }

    public override void render(Cairo.Context cr, Gtk.Widget widget, Gdk.Rectangle background_area,
                                Gdk.Rectangle cell_area, Gtk.CellRendererState flags) {
        // highlight colour where the stock renderer paints it: not under the selection
        if (has_bg && (flags & Gtk.CellRendererState.SELECTED) == 0) {
            Gdk.cairo_rectangle(cr, background_area);
            Gdk.cairo_set_source_rgba(cr, bg);
            cr.fill();
        }
        unowned Shaped s = shape(widget);
        int free_w = cell_area.width - (s.width + 2 * pad_x);
        int free_h = cell_area.height - (s.height + 2 * pad_y);
        float xa = widget.get_direction() == Gtk.TextDirection.RTL ? 1.0f - align : align;
        int x = cell_area.x + pad_x + (free_w > 0 ? (int) (xa * free_w) : 0);
        int y = cell_area.y + pad_y + (free_h > 0 ? free_h / 2 : 0);
        bool clip = free_w < 0;
        if (clip) {
            cr.save();
            Gdk.cairo_rectangle(cr, cell_area);
            cr.clip();
        }
        Gdk.RGBA c = ink(widget);
        Gdk.cairo_set_source_rgba(cr, c);
        cr.move_to(x, y);
        Pango.cairo_show_layout(cr, s.layout);
        if (clip) cr.restore();
        if (has_icon) draw_icon(cr, widget, c, x + s.width + ICON_GAP, cell_area);
    }

    private void draw_icon(Cairo.Context cr, Gtk.Widget widget, Gdk.RGBA c, int x, Gdk.Rectangle area) {
        if (x + ICON_SIZE > area.x + area.width) return;   // no room: the name comes first
        int scale = widget.get_scale_factor();
        string key = "%s@%d".printf(c.to_string(), scale);
        unowned Cairo.Surface? surface = icons.lookup(key);
        if (surface == null) {
            var info = Gtk.IconTheme.get_default().lookup_icon_for_scale(icon_name, ICON_SIZE, scale,
                Gtk.IconLookupFlags.FORCE_SYMBOLIC | Gtk.IconLookupFlags.FORCE_SIZE);
            if (info == null) return;
            Gdk.Pixbuf pb;
            try { pb = info.load_symbolic(c, null, null, null, null); } catch (Error e) { return; }
            icons.insert(key, Gdk.cairo_surface_create_from_pixbuf(pb, scale, null));
            surface = icons.lookup(key);
        }
        cr.set_source_surface(surface, x, area.y + (area.height - ICON_SIZE) / 2);
        cr.paint();
    }
}
