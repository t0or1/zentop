/* tab_themes.vala -- the theme list. Choosing a row emits `chosen`; the
 * window reloads the stylesheet in place and every widget restyles live. */

public class ThemesTab : Gtk.Box {
    public signal void chosen(string id);

    private Gee.ArrayList<ColorChip> chips = new Gee.ArrayList<ColorChip>();

    public ThemesTab(AppContext ctx, string current) {
        Object(orientation: Gtk.Orientation.VERTICAL, spacing: 0);
        Ui.margins(this, 20, 20, 16, 0);
        var heading = Ui.section_label("SELECT A THEME");
        heading.margin_bottom = 6;
        pack_start(heading, false, false, 0);

        Gtk.RadioButton? group = null;
        foreach (var t in THEMES) {
            string id = t.id;
            var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 14);
            row.get_style_context().add_class("zt-theme-row");
            var radio = new Gtk.RadioButton.from_widget(group);
            group = radio;
            radio.active = id == current;           // before connecting: no reload at start
            radio.toggled.connect(() => { if (radio.active) chosen(id); });
            row.pack_start(radio, false, false, 0);

            var text = new Gtk.Box(Gtk.Orientation.VERTICAL, 2);
            text.pack_start(Ui.label(t.name, "theme-name"), false, false, 0);
            text.pack_start(Ui.label(t.desc, "theme-desc"), false, false, 0);
            row.pack_start(text, true, true, 0);

            var swatches = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 4);
            foreach (unowned string hex in new string[] {t.c1, t.c2, t.c3}) {
                var chip = new ColorChip.fixed(ctx.theme, hex, 16, true);
                chips.add(chip);
                swatches.pack_start(chip, false, false, 0);
            }
            row.pack_start(swatches, false, false, 0);

            // the whole row is the hit target, not just the radio dot
            var hit = new Gtk.EventBox();
            hit.add(row);
            hit.button_press_event.connect(() => { radio.active = true; return true; });
            pack_start(hit, false, false, 0);
        }
    }

    /* Swatch outlines use the theme's ink. */
    public void redraw() {
        foreach (var c in chips) c.queue_draw();
    }
}
