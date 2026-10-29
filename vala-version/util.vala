/* util.vala -- formatting, shared UI helpers and the AppContext every tab
 * receives. Nothing here touches /proc. */

namespace Fmt {
    public string bytes(int64 n) {
        if (n < 0) return "-";
        double v = (double) n;
        if (v < 1024.0) return "%.1fB".printf(v);
        v /= 1024.0;
        if (v < 1024.0) return "%.1fKB".printf(v);
        v /= 1024.0;
        if (v < 1024.0) return "%.1fMB".printf(v);
        v /= 1024.0;
        if (v < 1024.0) return "%.1fGB".printf(v);
        v /= 1024.0;
        if (v < 1024.0) return "%.1fTB".printf(v);
        return "%.1fPB".printf(v / 1024.0);
    }

    public string rate(double n) {
        return n < 0 ? "-" : bytes((int64) n) + "/s";
    }

    public string duration(double seconds) {
        int s = (int) seconds;
        int h = s / 3600, m = (s % 3600) / 60, sec = s % 60;
        return h > 0 ? "%d:%02d:%02d".printf(h, m, sec) : "%d:%02d".printf(m, sec);
    }

    /* HH:MM:SS for today, "Mon DD" otherwise. `today` is computed once per
     * tick by the caller, never per row. */
    public string started(int64 epoch, int today_ymd) {
        if (epoch <= 0) return "-";
        var dt = new DateTime.from_unix_local(epoch);
        int ymd = dt.get_year() * 1000 + dt.get_day_of_year();
        return ymd == today_ymd ? dt.format("%H:%M:%S") : dt.format("%b %d");
    }

    public int today_ymd() {
        var now = new DateTime.now_local();
        return now.get_year() * 1000 + now.get_day_of_year();
    }

    /* Black or white ink for a highlight colour; memoised, a row's
     * highlight colour is re-read every tick. */
    private Gee.HashMap<string, string>? contrast_cache = null;
    public string contrast_ink(string hex) {
        if (contrast_cache == null) contrast_cache = new Gee.HashMap<string, string>();
        var hit = contrast_cache[hex];
        if (hit != null) return hit;
        Gdk.RGBA c = Gdk.RGBA();
        string ink = "#FFFFFF";
        if (c.parse(hex) && 0.299 * c.red + 0.587 * c.green + 0.114 * c.blue > 0.6) ink = "#000000";
        contrast_cache[hex] = ink;
        return ink;
    }
}

/* State every tab needs, built once by the window. */
public class AppContext : Object {
    public ThemeColors theme = new ThemeColors();
    public ProcessConfig process_config = new ProcessConfig();
    public Pango.AttrList tnum;        // tabular figures, shared by all numeric text
    public string current_user;
    public string? pin_icon = null;
    public uint64 total_mem = 1;
    public unowned Gtk.Window window;

    public AppContext(Gtk.Window window, uint64 total_mem) {
        this.window = window;
        this.total_mem = uint64.max(total_mem, 1);
        current_user = Environment.get_user_name();
        tnum = new Pango.AttrList();
        tnum.insert(Pango.AttrFontFeatures.@new("tnum 1"));
        foreach (unowned string icon in new string[] {"view-pin-symbolic", "starred-symbolic"}) {
            if (Gtk.IconTheme.get_default().has_icon(icon)) { pin_icon = icon; break; }
        }
    }

    public void show_error(string message) {
        var d = new Gtk.MessageDialog(window, Gtk.DialogFlags.MODAL, Gtk.MessageType.ERROR,
                                      Gtk.ButtonsType.OK, "%s", message);
        d.run();
        d.destroy();
    }
}

namespace Ui {
    /* Setting a label to the text it already has still queues a resize;
     * skipping it keeps idle ticks free. */
    public void set_text(Gtk.Label l, string text) {
        if (l.label != text) l.label = text;
    }

    public Gtk.Label label(string text, string css_class, float xalign = 0) {
        var l = new Gtk.Label(text);
        l.xalign = xalign;
        l.get_style_context().add_class(css_class);
        return l;
    }

    public Gtk.Label section_label(string text) {
        return label(text, "section-label");
    }

    /* Section name on the left, its live figure on the right, like a
     * timetable's line name and departure time on one rule. */
    public Gtk.Box section_header(Gtk.Box parent, string text, int margin_top,
                                  Pango.AttrList tnum, out Gtk.Label? value, bool with_value = true) {
        var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 12);
        row.margin_top = margin_top;
        row.pack_start(section_label(text), false, false, 0);
        value = null;
        if (with_value) {
            value = label("-", "zt-stat-value", 1);
            value.attributes = tnum;
            row.pack_end(value, false, false, 0);
        }
        parent.pack_start(row, false, false, 0);
        return row;
    }

    public void margins(Gtk.Widget w, int start, int end, int top, int bottom) {
        w.margin_start = start;
        w.margin_end = end;
        w.margin_top = top;
        w.margin_bottom = bottom;
    }

    public Gtk.Button text_button(string text) {
        var b = new Gtk.Button.with_label(text);
        b.get_style_context().add_class("tree-toggle");
        return b;
    }
}
