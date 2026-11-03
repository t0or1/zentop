/* hw_info.vala -- what the hardware is, in words: CPU model, RAM modules,
 * swap devices, the network card, and the name of the device behind a
 * sysfs node (from the system's pci.ids). All of it is readable as a
 * normal user; nothing here needs root. Read when a page is built or every
 * few seconds, never per draw. No GTK in here.
 *
 * Test hooks: ZENTOP_SYSFS replaces /sys (as in sensors_data.vala), and
 * ZENTOP_TESTROOT is put in front of /proc/swaps, /proc/net/route and
 * /run/udev. */

namespace HwInfo {
    private string sys(string rel) {
        return Path.build_filename(Environment.get_variable("ZENTOP_SYSFS") ?? "/sys", rel);
    }

    private string rooted(string abs) {
        string? root = Environment.get_variable("ZENTOP_TESTROOT");
        return root != null ? root + abs : abs;
    }

    private string? read_line(string path) {
        string s;
        try { FileUtils.get_contents(path, out s); } catch (Error e) { return null; }
        return s.strip();
    }

    // ------------------------------------------------------------- CPU

    /* "Intel Core i3-10110U CPU @ 2.10GHz", "AMD Ryzen 7 5700G with Radeon
     * Graphics": the first model line of /proc/cpuinfo, trademarks dropped. */
    private string? cpu_model_memo = null;

    public string cpu_model() {
        if (cpu_model_memo == null) cpu_model_memo = read_cpu_model();
        return cpu_model_memo;
    }

    private string read_cpu_model() {
        string text;
        try { FileUtils.get_contents("/proc/cpuinfo", out text); } catch (Error e) { return ""; }
        string? found = null;
        // x86, then the names ARM and others use
        foreach (unowned string key in new string[] {"model name", "Hardware", "Model", "cpu model"}) {
            foreach (unowned string line in text.split("\n")) {
                if (!line.has_prefix(key)) continue;
                int colon = line.index_of(":");
                if (colon < 0 || line.substring(0, colon).strip() != key) continue;
                found = line.substring(colon + 1).strip();
                break;
            }
            if (found != null && found != "") break;
        }
        if (found == null) return "";
        foreach (unowned string mark in new string[] {"(R)", "(r)", "(TM)", "(tm)"}) found = found.replace(mark, "");
        while (found.contains("  ")) found = found.replace("  ", " ");
        return found.strip();
    }

    // ------------------------------------------------------------- devices

    /* "Intel Corporation" -> "Intel", "Advanced Micro Devices, Inc. [AMD/ATI]"
     * -> "AMD", "Realtek Semiconductor Co., Ltd." -> "Realtek". */
    public string short_vendor(string vendor) {
        int open = vendor.index_of("["), close = vendor.index_of("]");
        if (open >= 0 && close > open) return vendor.substring(open + 1, close - open - 1).split("/")[0];
        string v = vendor.split(",")[0].strip();
        string[] drop = {"Corporation", "Corp.", "Corp", "Inc.", "Inc", "Co.", "Co", "Ltd.", "Ltd", "Limited",
                         "Semiconductor", "Electronics", "Technology", "Technologies", "International"};
        bool cut = true;
        while (cut) {
            cut = false;
            foreach (unowned string d in drop) {
                if (v.has_suffix(" " + d)) { v = v.substring(0, v.length - d.length - 1).strip(); cut = true; }
            }
        }
        return v;
    }

    private string? hex_id(string dir, string file) {
        string? s = read_line(Path.build_filename(dir, file));
        if (s == null) return null;
        return s.has_prefix("0x") ? s.substring(2).down() : s.down();
    }

    private string[] pci_ids_files() {
        return {"/usr/share/hwdata/pci.ids", "/usr/share/misc/pci.ids", "/usr/share/pci.ids"};
    }

    /* Vendor, device and (same-vendor) subsystem names from pci.ids,
     * streamed: the file is ~1.3 MB and only one vendor's block matters. */
    private bool pci_lookup(string ven, string dev, string? sven, string? sdev,
                            out string vendor_name, out string device_name, out string? sub_name) {
        vendor_name = device_name = "";
        sub_name = null;
        foreach (var f in pci_ids_files()) {
            var fs = FileStream.open(f, "r");
            if (fs == null) continue;
            bool in_vendor = false, in_device = false;
            string? line;
            while ((line = fs.read_line()) != null) {
                if (line.length == 0 || line[0] == '#') continue;
                if (line[0] != '\t') {
                    if (in_vendor) break;                    // past our vendor: done
                    if (line.has_prefix(ven + "  ")) { in_vendor = true; vendor_name = line.substring(6); }
                    continue;
                }
                if (!in_vendor) continue;
                if (line.length > 1 && line[1] != '\t') {
                    if (in_device) break;                    // past our device
                    if (line.has_prefix("\t" + dev + "  ")) { in_device = true; device_name = line.substring(7); }
                } else if (in_device && sven != null && sdev != null
                           && line.has_prefix("\t\t" + sven + " " + sdev + "  ")) {
                    sub_name = line.substring(13);
                }
            }
            return vendor_name != "";
        }
        return false;
    }

    /* The product behind a sysfs device node: walks up from it to the PCI
     * function or USB device it hangs off. "Realtek RTL8111/8168/8211/8411
     * PCI Express Gigabit Ethernet Controller", "Intel Wi-Fi 6 AX201 160MHz".
     * Null when there is no such parent (virtual or platform devices). */
    private Gee.HashMap<string, string>? device_memo = null;   // realpath -> name ("" = none)

    public string? device_name(string node) {
        string? real = Posix.realpath(node);
        if (real == null) return null;
        if (device_memo == null) device_memo = new Gee.HashMap<string, string>();
        // devices don't change name: one pci.ids pass each (~3 ms), then free
        if (!device_memo.has_key(real)) device_memo[real] = find_device_name(real) ?? "";
        string hit = device_memo[real];
        return hit != "" ? hit : null;
    }

    private string? find_device_name(string start) {
        string? dir = start;
        for (int up = 0; dir != null && up < 5 && dir != "/"; up++) {
            string? subsys = null;
            try { subsys = Path.get_basename(FileUtils.read_link(Path.build_filename(dir, "subsystem"))); } catch (Error e) {}
            if (subsys == "pci") {
                string? ven = hex_id(dir, "vendor"), dev = hex_id(dir, "device");
                if (ven == null || dev == null) return null;
                string? sven = hex_id(dir, "subsystem_vendor"), sdev = hex_id(dir, "subsystem_device");
                string vname, dname;
                string? sname;
                if (!pci_lookup(ven, dev, sven, sdev, out vname, out dname, out sname)) return null;
                // a board maker's subsystem name says less than the chip's own
                string product = sname != null && sven == ven ? sname : dname;
                if (product == "") return short_vendor(vname);
                return short_vendor(vname) + " " + product;
            }
            if (subsys == "usb") {
                string? product = read_line(Path.build_filename(dir, "product"));
                if (product != null) {
                    string? maker = read_line(Path.build_filename(dir, "manufacturer"));
                    return maker != null && !product.has_prefix(maker) ? maker + " " + product : product;
                }
            }
            dir = Path.get_dirname(dir);
        }
        return null;
    }

    /* "ASRock A520M-HDV", from DMI; null if the firmware doesn't say. */
    public string? board_name() {
        string? vendor = read_line(sys("class/dmi/id/board_vendor"));
        string? name = read_line(sys("class/dmi/id/board_name"));
        if (name == null || name == "" || name.down().contains("to be filled")) return null;
        return vendor != null && vendor != "" ? short_vendor(vendor) + " " + name : name;
    }

    // ------------------------------------------------------------- memory

    private string size_words(uint64 bytes) {
        double gb = bytes / 1073741824.0;
        if (gb >= 1) return gb == Math.floor(gb) ? "%.0f GB".printf(gb) : "%.1f GB".printf(gb);
        return "%.0f MB".printf(bytes / 1048576.0);
    }

    /* "DDR4 · 3200 MT/s · 2 × 16 GB", "DDR4 · 2666 MT/s · 4 GB soldered +
     * 8 GB SODIMM". From the DMI memory records systemd's udev keeps
     * readable in /run/udev/data/+dmi:id (dmidecode itself needs root).
     * Empty when that isn't there. */
    public string ram_summary() {
        string text;
        try { FileUtils.get_contents(rooted("/run/udev/data/+dmi:id"), out text); } catch (Error e) { return ""; }
        var props = new Gee.HashMap<string, string>();
        foreach (unowned string line in text.split("\n")) {
            if (!line.has_prefix("E:")) continue;
            int eq = line.index_of("=");
            if (eq > 2) props[line.substring(2, eq - 2)] = line.substring(eq + 1);
        }
        var sizes = new Gee.ArrayList<uint64?>();
        var forms = new Gee.ArrayList<string>();
        string type = "";
        int speed = 0, slots = 0;
        for (int i = 0; i < 64; i++) {
            string k = "MEMORY_DEVICE_%d_".printf(i);
            if (!props.has_key(k + "PRESENT") && !props.has_key(k + "SIZE") && !props.has_key(k + "LOCATOR")) break;
            slots++;
            if (props[k + "PRESENT"] == "0" || !props.has_key(k + "SIZE")) continue;
            sizes.add(uint64.parse(props[k + "SIZE"]));
            string ff = props[k + "FORM_FACTOR"] ?? "";
            forms.add(ff == "Row Of Chips" ? "soldered" : ff);
            string t = props[k + "TYPE"] ?? "";
            if (type == "" && t != "" && t != "Unknown" && t != "Other") type = t;
            // the speed it actually runs at, else what the module is rated for
            int s = int.parse(props[k + "CONFIGURED_SPEED_MTS"] ?? props[k + "SPEED_MTS"] ?? "0");
            if (s > 0 && (speed == 0 || s < speed)) speed = s;
        }
        if (sizes.size == 0) return "";
        var parts = new Gee.ArrayList<string>();
        if (type != "") parts.add(type);
        if (speed > 0) parts.add("%d MT/s".printf(speed));
        bool same = true, same_form = true;
        for (int i = 1; i < sizes.size; i++) {
            if (sizes[i] != sizes[0]) same = false;
            if (forms[i] != forms[0]) same_form = false;
        }
        string modules;
        if (same && same_form) {
            modules = sizes.size == 1 ? size_words(sizes[0]) : "%d × %s".printf(sizes.size, size_words(sizes[0]));
        } else {
            var each = new string[sizes.size];
            for (int i = 0; i < sizes.size; i++)
                each[i] = size_words(sizes[i]) + (same_form || forms[i] == "" ? "" : " " + forms[i]);
            modules = string.joinv(" + ", each);
        }
        if (slots > sizes.size) modules += " (%d of %d slots)".printf(sizes.size, slots);
        parts.add(modules);
        return string.joinv(" · ", parts.to_array());
    }

    // ------------------------------------------------------------- swap

    /* "zram · zstd · 3.1:1", "partition nvme0n1p3", "file /swapfile", joined
     * with " + "; zswap (a compressed cache in front of swap) when enabled. */
    public string swap_summary() {
        var parts = new Gee.ArrayList<string>();
        string text;
        try { FileUtils.get_contents(rooted("/proc/swaps"), out text); } catch (Error e) { text = ""; }
        var lines = text.split("\n");
        for (int i = 1; i < lines.length; i++) {
            var f = Regex.split_simple("\\s+", lines[i].strip());
            if (f.length < 2 || f[0] == "") continue;
            string name = f[0].replace("\\040", " ");
            string base_name = Path.get_basename(name);
            if (base_name.has_prefix("zram")) {
                string desc = "zram";
                string? algo = read_line(sys("block/%s/comp_algorithm".printf(base_name)));
                if (algo != null) {
                    // "lzo lzo-rle lz4 [zstd]": the bracketed one is in use
                    int o = algo.index_of("["), c = algo.index_of("]");
                    if (o >= 0 && c > o) desc += " · " + algo.substring(o + 1, c - o - 1);
                }
                string? mm = read_line(sys("block/%s/mm_stat".printf(base_name)));
                if (mm != null) {
                    var m = Regex.split_simple("\\s+", mm);
                    double orig = m.length > 1 ? double.parse(m[0]) : 0, compr = m.length > 1 ? double.parse(m[1]) : 0;
                    if (orig > 0 && compr > 0) desc += " · %.1f:1".printf(orig / compr);
                }
                parts.add(desc);
            } else if (f[1] == "partition") {
                parts.add("partition " + base_name);
            } else {
                parts.add("file " + name);
            }
        }
        if (read_line(sys("module/zswap/parameters/enabled")) == "Y") {
            string? comp = read_line(sys("module/zswap/parameters/compressor"));
            parts.add(comp != null ? "zswap cache (%s)".printf(comp) : "zswap cache");
        }
        return string.joinv(" + ", parts.to_array());
    }

    // ------------------------------------------------------------- network

    /* The interface the default route uses (lowest metric), else the first
     * one that is up: "wlp2s0 · Intel Wi-Fi 6 AX201 160MHz · Wi-Fi",
     * "enp3s0 · Realtek RTL8111/8168/8211/8411 ... · Ethernet · 1 Gb/s". */
    public string net_summary() {
        string? iface = null;
        string routes;
        try { FileUtils.get_contents(rooted("/proc/net/route"), out routes); } catch (Error e) { routes = ""; }
        int best = int.MAX;
        foreach (unowned string line in routes.split("\n")) {
            var f = Regex.split_simple("\\s+", line.strip());
            if (f.length < 7 || f[1] != "00000000") continue;
            int flags = (int) int64.parse("0x" + f[3]), metric = int.parse(f[6]);
            if ((flags & 1) == 0 || metric >= best) continue;   // 1 = RTF_UP
            best = metric;
            iface = f[0];
        }
        if (iface == null) {
            try {
                var d = Dir.open(sys("class/net"));
                string? n;
                while ((n = d.read_name()) != null) {
                    if (n == "lo") continue;
                    if (read_line(sys("class/net/%s/operstate".printf(n))) == "up") { iface = n; break; }
                }
            } catch (Error e) {}
        }
        if (iface == null) return "";
        var parts = new Gee.ArrayList<string>();
        parts.add(iface);
        string dir = sys("class/net/" + iface);
        string? card = device_name(Path.build_filename(dir, "device"));
        if (card != null) parts.add(card);
        bool wifi = FileUtils.test(Path.build_filename(dir, "wireless"), FileTest.EXISTS)
                 || FileUtils.test(Path.build_filename(dir, "phy80211"), FileTest.EXISTS);
        if (wifi) parts.add("Wi-Fi");
        else if (read_line(Path.build_filename(dir, "type")) == "1") parts.add("Ethernet");
        int mbps = int.parse(read_line(Path.build_filename(dir, "speed")) ?? "0");
        if (mbps > 0) parts.add(mbps >= 1000 ? "%g Gb/s".printf(mbps / 1000.0) : "%d Mb/s".printf(mbps));
        return string.joinv(" · ", parts.to_array());
    }
}
