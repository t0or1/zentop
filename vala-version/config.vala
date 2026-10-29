/* config.vala -- persisted settings, same files and JSON shape as the
 * Python version (~/.config/system-monitor-pp/), so both versions share
 * pins, highlights and the chosen theme. */

namespace ConfigPaths {
    public string dir() {
        return Path.build_filename(Environment.get_home_dir(), ".config", "system-monitor-pp");
    }
}

/* Per process name: {"pinned": bool, "highlight_color": "#RRGGBB"}. */
public class ProcessConfig : Object {
    private Gee.HashSet<string> pinned = new Gee.HashSet<string>();
    private Gee.HashMap<string, string> colors = new Gee.HashMap<string, string>();
    private string path;

    public ProcessConfig() {
        path = Path.build_filename(ConfigPaths.dir(), "process_config.json");
        load();
    }

    public bool is_pinned(string name) { return pinned.contains(name); }
    public string? highlight_color(string name) { return colors[name]; }

    public void toggle_pin(string name) {
        if (!pinned.remove(name)) pinned.add(name);
        save();
    }

    public void set_highlight(string name, string hex) {
        colors[name] = hex;
        save();
    }

    public void remove_highlight(string name) {
        colors.unset(name);
        save();
    }

    private void load() {
        var parser = new Json.Parser();
        try { parser.load_from_file(path); } catch (Error e) { return; } // missing or corrupt: start fresh
        var root = parser.get_root();
        if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return;
        root.get_object().foreach_member((o, name, node) => {
            if (node.get_node_type() != Json.NodeType.OBJECT) return;
            var entry = node.get_object();
            if (entry.has_member("pinned") && entry.get_boolean_member("pinned")) pinned.add(name);
            if (entry.has_member("highlight_color")) colors[name] = entry.get_string_member("highlight_color");
        });
    }

    private void save() {
        var b = new Json.Builder();
        b.begin_object();
        var names = new Gee.HashSet<string>();
        names.add_all(pinned);
        names.add_all(colors.keys);
        foreach (var name in names) {
            b.set_member_name(name);
            b.begin_object();
            if (pinned.contains(name)) { b.set_member_name("pinned"); b.add_boolean_value(true); }
            var c = colors[name];
            if (c != null) { b.set_member_name("highlight_color"); b.add_string_value(c); }
            b.end_object();
        }
        b.end_object();
        write_json(path, b.get_root());
    }
}

/* app_config.json: read-modify-write, so keys this version doesn't know
 * about (written by the Python version, or a future one) survive. */
namespace AppConfig {
    private string path() { return Path.build_filename(ConfigPaths.dir(), "app_config.json"); }

    private Json.Object read_all() {
        var parser = new Json.Parser();
        try {
            parser.load_from_file(path());
            var root = parser.get_root();
            if (root != null && root.get_node_type() == Json.NodeType.OBJECT) return root.get_object();
        } catch (Error e) {}
        return new Json.Object();
    }

    public string get_theme() {
        var obj = read_all();
        return obj.has_member("theme") ? obj.get_string_member("theme") : "default";
    }

    public void set_theme(string id) {
        var obj = read_all();
        obj.set_string_member("theme", id);
        var node = new Json.Node(Json.NodeType.OBJECT);
        node.set_object(obj);
        write_json(path(), node);
    }
}

private void write_json(string path, Json.Node root) {
    try {
        DirUtils.create_with_parents(Path.get_dirname(path), 0755);
        var gen = new Json.Generator();
        gen.pretty = true;
        gen.set_root(root);
        gen.to_file(path);
    } catch (Error e) {
        stderr.printf("Could not save %s: %s\n", path, e.message);
    }
}
