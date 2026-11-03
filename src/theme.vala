/* theme.vala -- the theme catalogue, the active theme's colour roles read
 * from the loaded CSS (".zt-c-<role> { color }"), app paths and the
 * bundled font. Code never names a hex value: it asks for a role. */

public const string[] COLOR_ROLES = {
    "ink", "idle", "hot", "bg", "g-bg", "g-grid", "g-cpu", "g-mem", "g-swap", "g-rx", "g-tx",
    "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7"
};

public struct ThemeInfo {
    public unowned string id;
    public unowned string name;
    public unowned string desc;
    public unowned string c1;
    public unowned string c2;
    public unowned string c3;
}

public const ThemeInfo[] THEMES = {
    {"default", "DEFAULT — GitHub Dark", "background #0D1117, violet accents.", "#0D1117", "#8B5CF6", "#161B22"},
    {"eva01", "EVA-01", "Deep Violet, Light green, Red.", "#0F0A1F", "#7B2FD9", "#8CFF6B"},
    {"magi", "MAGI", "Black Monochromatic terminal, amber CRT.", "#060606", "#FFB000", "#FFCC66"},
    {"eva00", "EVA-00", "Pale Blue / White, Orange Stripes.", "#0A1420", "#FF8C1A", "#7FD4F0"},
    {"eva02", "EVA-02", "Red/Orange, Made in Germany, cream.", "#150808", "#E8412C", "#F4C95D"},
    {"pastel", "PASTEL PINK", "Pale pink background, fuchsia and lavender tones.", "#FDF0F5", "#E85CA6", "#C9A0DC"}
};

public class ThemeColors : Object {
    private Gee.HashMap<string, Gdk.RGBA?> colors = new Gee.HashMap<string, Gdk.RGBA?>();
    private Gee.HashMap<string, string> hexes = new Gee.HashMap<string, string>();
    private Gdk.RGBA fallback = Gdk.RGBA() { red = 0.5, green = 0.5, blue = 0.5, alpha = 1 };
    /* Table ink by Ink code, filled from the roles; read per cell. */
    public Gdk.RGBA[] inks = new Gdk.RGBA[Ink.N];
    /* Bumped on every style update (theme switch, focus in/out), so
     * anything caching a style lookup knows to look again. */
    public uint generation = 0;

    public ThemeColors() {
        inks[Ink.BLACK] = Gdk.RGBA() { red = 0, green = 0, blue = 0, alpha = 1 };
        inks[Ink.WHITE] = Gdk.RGBA() { red = 1, green = 1, blue = 1, alpha = 1 };
        inks[Ink.IDLE] = inks[Ink.HOT] = fallback;
    }

    public Gdk.RGBA get_role(string role) {
        var c = colors[role];
        return c != null ? c : fallback;
    }

    /* "#RRGGBB", for pixbuf swatches. */
    public string hex(string role) {
        var h = hexes[role];
        return h != null ? h : "#808080";
    }

    /* ~20 style lookups; runs at start and when the stylesheet changes,
     * never per tick. Returns true if any colour moved. */
    public bool read_from(Gtk.StyleContext ctx) {
        generation++;
        bool changed = false;
        foreach (unowned string role in COLOR_ROLES) {
            ctx.save();
            ctx.add_class("zt-c-" + role);
            Gdk.RGBA c = ctx.get_color(Gtk.StateFlags.NORMAL);
            ctx.restore();
            var old = colors[role];
            if (old != null && old.equal(c)) continue;
            colors[role] = c;
            hexes[role] = "#%02X%02X%02X".printf((int) Math.round(c.red * 255),
                (int) Math.round(c.green * 255), (int) Math.round(c.blue * 255));
            changed = true;
        }
        if (changed) {
            inks[Ink.IDLE] = get_role("idle");
            inks[Ink.HOT] = get_role("hot");
        }
        return changed;
    }
}

namespace AppPaths {
    /* Folder holding the binary (via /proc/self/exe), so ./zentop works
     * from any working directory. */
    public string app_dir() {
        string? exe = Native.get_exe_path((int) Posix.getpid());
        return exe != null ? Path.get_dirname(exe) : Environment.get_current_dir();
    }

    public string theme_file(string id) {
        return Path.build_filename(app_dir(), "themes", id + ".css");
    }

    /* fonts/ next to the binary (the repo root, or the install folder). */
    public string? fonts_dir() {
        string dir = Path.build_filename(app_dir(), "fonts");
        return FileUtils.test(Path.build_filename(dir, "Inter-Regular.otf"), FileTest.EXISTS) ? dir : null;
    }
}

[CCode (cheader_filename = "fontconfig/fontconfig.h", cname = "FcConfigAppFontAddDir")]
private extern int fc_app_font_add_dir(void* config, string dir);

/* Registers Inter for this process only; nothing is installed system-wide. */
public void register_app_fonts() {
    string? dir = AppPaths.fonts_dir();
    if (dir != null) fc_app_font_add_dir(null, dir);
}
