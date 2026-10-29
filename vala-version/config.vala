/* config.vala -- per-process config (pinned / highlight_color), same
 * JSON shape and same file location as the Python version, so switching
 * between them (or running both during the transition) doesn't lose
 * your pins/highlights. */

public class ProcessConfig : Object {
    private const string CONFIG_DIR_NAME = ".config/system-monitor-pp";
    private const string CONFIG_FILE_NAME = "process_config.json";

    // process_name -> {"pinned": bool, "highlight_color": string}
    private Gee.HashMap<string, bool> pinned_map = new Gee.HashMap<string, bool>();
    private Gee.HashMap<string, string> color_map = new Gee.HashMap<string, string>();
    private string path;

    public ProcessConfig() {
        path = Path.build_filename(Environment.get_home_dir(), CONFIG_DIR_NAME, CONFIG_FILE_NAME);
        load();
    }

    public bool is_pinned(string name) {
        return pinned_map.has_key(name) && pinned_map[name];
    }

    public string? highlight_color(string name) {
        return color_map.has_key(name) ? color_map[name] : null;
    }

    public void toggle_pin(string name) {
        bool now_pinned = !is_pinned(name);
        if (now_pinned) pinned_map[name] = true;
        else pinned_map.unset(name);
        save();
    }

    public void set_highlight(string name, string hex_color) {
        color_map[name] = hex_color;
        save();
    }

    public void remove_highlight(string name) {
        color_map.unset(name);
        save();
    }

    private void load() {
        if (!FileUtils.test(path, FileTest.EXISTS)) return;
        var parser = new Json.Parser();
        try {
            parser.load_from_file(path);
        } catch (Error e) {
            return; // corrupt/missing -- start fresh rather than crash
        }
        var root = parser.get_root();
        if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return;
        var obj = root.get_object();
        obj.foreach_member((o, name, node) => {
            if (node.get_node_type() != Json.NodeType.OBJECT) return;
            var entry = node.get_object();
            if (entry.has_member("pinned") && entry.get_boolean_member("pinned")) {
                pinned_map[name] = true;
            }
            if (entry.has_member("highlight_color")) {
                color_map[name] = entry.get_string_member("highlight_color");
            }
        });
    }

    private void save() {
        var builder = new Json.Builder();
        builder.begin_object();

        var names = new Gee.HashSet<string>();
        names.add_all(pinned_map.keys);
        names.add_all(color_map.keys);

        foreach (var name in names) {
            bool pinned = is_pinned(name);
            string? color = highlight_color(name);
            if (!pinned && color == null) continue;
            builder.set_member_name(name);
            builder.begin_object();
            if (pinned) {
                builder.set_member_name("pinned");
                builder.add_boolean_value(true);
            }
            if (color != null) {
                builder.set_member_name("highlight_color");
                builder.add_string_value(color);
            }
            builder.end_object();
        }
        builder.end_object();

        try {
            DirUtils.create_with_parents(Path.get_dirname(path), 0755);
            var generator = new Json.Generator();
            generator.set_root(builder.get_root());
            generator.pretty = true;
            generator.to_file(path);
        } catch (Error e) {
            stderr.printf("Could not save config to %s: %s\n", path, e.message);
        }
    }
}
