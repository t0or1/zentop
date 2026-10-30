/* scan_cache.vala -- remembers "Analyze Selected Disk" results between runs,
 * in $XDG_CACHE_HOME/zentop/disk_scans.json (~/.cache/zentop/ by default).
 * Only complete scans are stored; a cancelled scan never replaces a full
 * one. Each entry keeps when it was taken, how long it took and how full
 * the disk was then, so the tab can say when a result has gone stale.
 * No GTK in here. */

public class CachedScan {
    public string mountpoint;
    public int64 scanned_at;       // unix seconds
    public double seconds;         // how long the scan took
    public uint64 used_then;       // partition "used" bytes at scan time
    public Gee.ArrayList<ScanEntry> entries = new Gee.ArrayList<ScanEntry>();  // biggest first
}

public class ScanCache : Object {
    private const int MAX_ENTRIES = 2000;  // top-level items kept per disk; the tail is summed
    private const int MAX_DISKS = 32;
    private string path;
    private Gee.HashMap<string, CachedScan> scans = new Gee.HashMap<string, CachedScan>();
    public string? last = null;    // mountpoint of the most recent scan

    public ScanCache() {
        path = Path.build_filename(Environment.get_user_cache_dir(), "zentop", "disk_scans.json");
        load();
    }

    public CachedScan? get_scan(string mountpoint) { return scans[mountpoint]; }

    public void put(string mountpoint, Gee.ArrayList<ScanEntry> sorted, double seconds, uint64 used) {
        var c = new CachedScan();
        c.mountpoint = mountpoint;
        c.scanned_at = new DateTime.now_utc().to_unix();
        c.seconds = seconds;
        c.used_then = used;
        uint64 tail = 0;
        int tail_items = 0;
        for (int i = 0; i < sorted.size; i++) {
            if (i < MAX_ENTRIES) c.entries.add(sorted[i]);
            else { tail += sorted[i].size; tail_items++; }
        }
        if (tail_items > 0) c.entries.add(new ScanEntry("%d smaller items".printf(tail_items), tail, false));
        scans[mountpoint] = c;
        last = mountpoint;
        // forget the oldest disks past the cap (old USB drives, etc.)
        while (scans.size > MAX_DISKS) {
            CachedScan? oldest = null;
            foreach (var s in scans.values) if (oldest == null || s.scanned_at < oldest.scanned_at) oldest = s;
            scans.unset(oldest.mountpoint);
        }
        save();
    }

    private void load() {
        var parser = new Json.Parser();
        try { parser.load_from_file(path); } catch (Error e) { return; }  // none yet, or unreadable: start empty
        var root = parser.get_root();
        if (root == null || root.get_node_type() != Json.NodeType.OBJECT) return;
        var obj = root.get_object();
        if (obj.has_member("last")) last = obj.get_string_member("last");
        if (!obj.has_member("scans")) return;
        obj.get_object_member("scans").foreach_member((o, mp, node) => {
            if (node.get_node_type() != Json.NodeType.OBJECT) return;
            var s = node.get_object();
            var c = new CachedScan();
            c.mountpoint = mp;
            c.scanned_at = s.get_int_member_with_default("scanned_at", 0);
            c.seconds = s.get_double_member_with_default("seconds", 0);
            c.used_then = (uint64) s.get_int_member_with_default("used", 0);
            if (!s.has_member("entries")) return;
            s.get_array_member("entries").foreach_element((a, i, el) => {
                if (el.get_node_type() != Json.NodeType.ARRAY) return;
                var e = el.get_array();
                if (e.get_length() < 3) return;
                c.entries.add(new ScanEntry(e.get_string_element(0), (uint64) e.get_int_element(1),
                                            e.get_boolean_element(2)));
            });
            scans[mp] = c;
        });
    }

    /* Written whole to a temp file and renamed over the old one, so a crash
     * mid-write can never leave a half file behind. */
    private void save() {
        var b = new Json.Builder();
        b.begin_object();
        b.set_member_name("version");
        b.add_int_value(1);
        if (last != null) { b.set_member_name("last"); b.add_string_value(last); }
        b.set_member_name("scans");
        b.begin_object();
        foreach (var c in scans.values) {
            b.set_member_name(c.mountpoint);
            b.begin_object();
            b.set_member_name("scanned_at"); b.add_int_value(c.scanned_at);
            b.set_member_name("seconds"); b.add_double_value(c.seconds);
            b.set_member_name("used"); b.add_int_value((int64) c.used_then);
            b.set_member_name("entries");
            b.begin_array();
            foreach (var e in c.entries) {
                b.begin_array();
                b.add_string_value(e.name);
                b.add_int_value((int64) e.size);
                b.add_boolean_value(e.is_dir);
                b.end_array();
            }
            b.end_array();
            b.end_object();
        }
        b.end_object();
        b.end_object();
        var gen = new Json.Generator();
        gen.set_root(b.get_root());
        try {
            DirUtils.create_with_parents(Path.get_dirname(path), 0700);
            FileUtils.set_contents(path, gen.to_data(null));
        } catch (Error e) {
            stderr.printf("Could not save the disk scan cache: %s\n", e.message);
        }
    }

    /* "just now", "12 min ago", "3 h ago", "2 days ago", or the date. */
    public static string age(int64 then) {
        int64 d = new DateTime.now_utc().to_unix() - then;
        if (d < 60) return "just now";
        if (d < 3600) return "%lld min ago".printf(d / 60);
        if (d < 86400) return "%lld h ago".printf(d / 3600);
        if (d < 86400 * 14) return d < 86400 * 2 ? "yesterday" : "%lld days ago".printf(d / 86400);
        return new DateTime.from_unix_local(then).format("%b %d");
    }
}
