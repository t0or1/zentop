/* sensors_data.vala -- every power and temperature sensor Linux exposes,
 * discovered once and then re-read cheaply (kept fds + pread, like /proc).
 *
 * Sources, in the kernel's own units:
 *   hwmon        tempN_input (m°C, + _label/_max/_crit), powerN_input or
 *                powerN_average (µW), energyN_input (µJ counter -> W)
 *   RAPL         /sys/class/powercap/<zone>/energy_uj (µJ counter -> W);
 *                root-only on current kernels (PLATYPUS side-channel fix),
 *                so these show as locked unless made readable
 *   batteries    power_now (µW), or current_now (µA) x voltage_now (µV)
 *   thermal      thermal_zoneN/temp, only zones hwmon doesn't already cover
 *   NVIDIA       NVML (libnvidia-ml.so.1), loaded at run time if present
 * No GTK in here. ZENTOP_SYSFS points discovery at a fake tree for tests. */

public enum SensorKind { POWER, TEMP }

/* Why RAPL is still locked, so the page can say what to do next. */
public enum RaplSetup {
    NOT_SET_UP,       // no udev rule yet: run install.sh --rapl
    NEEDS_RELOGIN,    // rule and group exist, this session predates the group
    NEEDS_APPLY       // session is in the group but the files weren't re-permissioned yet
}

[CCode (cname = "getgroups", cheader_filename = "unistd.h")]
private extern int c_getgroups(int size, [CCode (array_length = false)] Posix.gid_t[]? list);

private enum ReadMode { DIRECT, ENERGY, CURRENT_X_VOLTAGE, NVML_POWER, NVML_TEMP }

public class Sensor {
    public SensorKind kind;
    public string group;          // what the reading is about: "CPU", "GPU", "NVMe Samsung SSD 970"
    public string source;         // where it comes from: "k10temp", "RAPL", "NVML"
    public string label;          // "Tctl", "Package", "edge"
    public string what = "";      // what it measures, in words: "CPU core die (CCD 1)"
    public double value = double.NAN;  // W or °C; NaN = no reading right now
    public double low = double.INFINITY;
    public double peak = -double.INFINITY;
    public double sum = 0;
    public int samples = 0;
    public double high = double.NAN;   // temps: driver's "max" (warning) threshold
    public double crit = double.NAN;   // temps: driver's critical threshold
    public bool locked = false;        // present but not readable by this user
    public string? note = null;        // battery: "discharging", "charging"...
    public string path = "";           // the file behind it, shown in tooltips

    internal ReadMode mode = ReadMode.DIRECT;
    internal ProcReader? a = null;
    internal ProcReader? b = null;
    internal ProcReader? status = null;
    internal double scale = 1;
    internal int64 prev_energy = -1;
    internal int64 prev_us = 0;
    internal int64 wrap = 0;
    internal void* nv_dev = null;
    internal string dev_dir = "";      // its hwmon or power_supply folder, to name the device

    public bool mode_is_energy() { return mode == ReadMode.ENERGY; }
    public double avg() { return samples > 0 ? sum / samples : double.NAN; }

    internal void record(double v) {
        value = v;
        if (v.is_nan()) return;
        if (v < low) low = v;
        if (v > peak) peak = v;
        sum += v;
        samples++;
    }
}

// --- NVML, bound at run time so there's no hard dependency on NVIDIA's driver
[CCode (has_target = false)] private delegate int NvmlInitFn();
[CCode (has_target = false)] private delegate int NvmlCountFn(out uint count);
[CCode (has_target = false)] private delegate int NvmlHandleFn(uint index, out void* dev);
[CCode (has_target = false)] private delegate int NvmlNameFn(void* dev, char* name, uint length);
[CCode (has_target = false)] private delegate int NvmlPowerFn(void* dev, out uint milliwatts);
[CCode (has_target = false)] private delegate int NvmlTempFn(void* dev, int sensor, out uint celsius);

public class SensorHub : Object {
    public Gee.ArrayList<Sensor> power = new Gee.ArrayList<Sensor>();
    public Gee.ArrayList<Sensor> temps = new Gee.ArrayList<Sensor>();
    public bool rapl_locked = false;   // RAPL exists but energy_uj isn't readable
    // per group key: a short title ("NVMe") and the device it is ("Samsung SSD 970 EVO Plus 1TB")
    public Gee.HashMap<string, string> group_title = new Gee.HashMap<string, string>();
    public Gee.HashMap<string, string> group_device = new Gee.HashMap<string, string>();
    private string root;
    private string topology = "";
    private Module? nvml = null;
    private NvmlPowerFn? nv_power = null;
    private NvmlTempFn? nv_temp = null;

    public SensorHub() {
        root = Environment.get_variable("ZENTOP_SYSFS") ?? "/sys";
    }

    // ------------------------------------------------------------- helpers

    private string p(string rel) { return Path.build_filename(root, rel); }

    private static string? read_line(string path) {
        string s;
        try { FileUtils.get_contents(path, out s); } catch (Error e) { return null; }
        return s.strip();
    }

    private static string[] list_dir(string path) {
        var names = new Gee.ArrayList<string>();
        try {
            var d = Dir.open(path);
            string? n;
            while ((n = d.read_name()) != null) names.add(n);
        } catch (Error e) {}
        names.sort((a, b) => natural_cmp(a, b));
        return names.to_array();
    }

    /* "temp10" after "temp9", "hwmon10" after "hwmon2". */
    private static int natural_cmp(string a, string b) {
        int i = 0, j = 0;
        while (i < a.length && j < b.length) {
            if (a[i].isdigit() && b[j].isdigit()) {
                int64 x = 0, y = 0;
                while (i < a.length && a[i].isdigit()) x = x * 10 + (a[i++] - '0');
                while (j < b.length && b[j].isdigit()) y = y * 10 + (b[j++] - '0');
                if (x != y) return x < y ? -1 : 1;
            } else {
                if (a[i] != b[j]) return a[i] < b[j] ? -1 : 1;
                i++;
                j++;
            }
        }
        return (a.length - i) - (b.length - j);
    }

    private static double parse_number(ProcReader r) {
        int i = 0;
        bool neg = false;
        while (i < r.len && (r.buf[i] == ' ' || r.buf[i] == '\t')) i++;
        if (i < r.len && r.buf[i] == '-') { neg = true; i++; }
        if (i >= r.len || r.buf[i] < '0' || r.buf[i] > '9') return double.NAN;
        int64 v = 0;
        while (i < r.len && r.buf[i] >= '0' && r.buf[i] <= '9') v = v * 10 + (r.buf[i++] - '0');
        return neg ? -v : v;
    }

    private static bool readable(string path) {
        return Posix.access(path, Posix.R_OK) == 0;
    }

    private static string? number_file(string dir, string name) {
        string f = Path.build_filename(dir, name);
        return FileUtils.test(f, FileTest.EXISTS) ? f : null;
    }

    private static double read_once(string? path, double scale) {
        if (path == null) return double.NAN;
        string? s = read_line(path);
        if (s == null || s == "") return double.NAN;
        int64 v;
        if (!int64.try_parse(s, out v)) return double.NAN;
        return v * scale;
    }

    /* Only meaningful while rapl_locked. Checks the rule install.sh writes
     * (or the hand-made 70-intel-rapl.rules) and this process's groups. */
    public static RaplSetup rapl_setup() {
        bool rule = FileUtils.test("/etc/udev/rules.d/70-zentop-rapl.rules", FileTest.EXISTS) ||
                    FileUtils.test("/etc/udev/rules.d/70-intel-rapl.rules", FileTest.EXISTS);
        unowned Posix.Group? g = Posix.getgrnam("rapl");
        if (!rule || g == null) return RaplSetup.NOT_SET_UP;
        int n = c_getgroups(0, null);
        if (n > 0) {
            var list = new Posix.gid_t[n];
            n = c_getgroups(n, list);
            for (int i = 0; i < n; i++) if (list[i] == g.gr_gid) return RaplSetup.NEEDS_APPLY;
        }
        return RaplSetup.NEEDS_RELOGIN;
    }

    // ------------------------------------------------------------- discovery

    /* Cheap fingerprint of the device lists: when it changes (a battery or
     * USB device appeared), discovery runs again. */
    public bool topology_changed() {
        string t = string.joinv(",", list_dir(p("class/hwmon"))) + "|" +
                   string.joinv(",", list_dir(p("class/power_supply"))) + "|" +
                   string.joinv(",", list_dir(p("class/powercap")));
        if (t == topology) return false;
        topology = t;
        return true;
    }

    public void discover() {
        power.clear();
        temps.clear();
        rapl_locked = false;
        topology_changed();
        var hwmon_names = new Gee.HashSet<string>();
        var name_counts = new Gee.HashMap<string, int>();
        foreach (var h in list_dir(p("class/hwmon"))) {
            string dir = p("class/hwmon/" + h);
            string name = read_line(Path.build_filename(dir, "name")) ?? h;
            hwmon_names.add(name);
            int nth = name_counts.has_key(name) ? name_counts[name] + 1 : 1;
            name_counts[name] = nth;
            discover_hwmon(dir, name, nth);
        }
        discover_rapl();
        discover_batteries();
        discover_thermal_zones(hwmon_names);
        discover_nvml();
        identify();
    }

    /* What a hwmon driver is reading, in words a person recognises. */
    private string group_for(string name, string dir, int nth) {
        string n = name.down();
        string g;
        if (n == "k10temp" || n == "zenpower" || n == "coretemp" || n == "amd_energy" ||
            n == "zenergy" || n == "cpu_thermal" || n.has_prefix("via_cputemp")) g = "CPU";
        else if (n == "amdgpu" || n == "radeon" || n == "nouveau" || n == "i915" || n == "xe") g = "GPU";
        else if (n == "nvme") g = "NVMe " + (read_line(Path.build_filename(dir, "device", "model")) ?? "SSD");
        else if (n == "drivetemp") g = "Disk " + (read_line(Path.build_filename(dir, "device", "model")) ?? "");
        else if (n == "acpitz") g = "ACPI";
        else if (n.has_prefix("pch_")) g = "Chipset";
        else if (n.has_prefix("iwlwifi") || n.has_prefix("mt79") || n.has_prefix("ath") || n.has_prefix("rtw")) g = "Wi-Fi";
        else if (n == "spd5118" || n == "jc42") g = "Memory";
        else if (n.has_prefix("nct") || n.has_prefix("it87") || n.has_prefix("asus") || n == "gigabyte_wmi" ||
                 n == "dell_smm" || n == "thinkpad" || n.has_prefix("f718")) g = "Motherboard";
        else if (n.has_prefix("bat")) g = "Battery";
        else g = name;
        g = g.strip();
        return nth > 1 ? "%s %d".printf(g, nth) : g;
    }

    private void discover_hwmon(string dir, string name, int nth) {
        string group = group_for(name, dir, nth);
        var files = list_dir(dir);
        int temp_count = 0;
        foreach (var f in files) if (f.has_prefix("temp") && f.has_suffix("_input")) temp_count++;
        foreach (var f in files) {
            if (f.has_prefix("temp") && f.has_suffix("_input")) {
                string idx = f.substring(4, f.length - 10);
                var s = new Sensor();
                s.kind = SensorKind.TEMP;
                s.group = group;
                s.source = name;
                s.dev_dir = dir;
                s.label = read_line(Path.build_filename(dir, "temp%s_label".printf(idx)))
                          ?? (temp_count == 1 ? "Temperature" : "Temp " + idx);
                s.path = Path.build_filename(dir, f);
                s.scale = 0.001;
                s.high = read_once(number_file(dir, "temp%s_max".printf(idx)), 0.001);
                s.crit = read_once(number_file(dir, "temp%s_crit".printf(idx)), 0.001);
                if (s.high <= 0) s.high = double.NAN;    // some drivers report 0 for "unset"
                if (s.crit <= 0) s.crit = double.NAN;
                attach(s, temps);
            } else if (f.has_prefix("power") && (f.has_suffix("_input") || f.has_suffix("_average"))) {
                bool avg = f.has_suffix("_average");
                string idx = f.substring(5, f.length - 5 - (avg ? 8 : 6));
                // prefer _input when a driver offers both
                if (avg && FileUtils.test(Path.build_filename(dir, "power%s_input".printf(idx)), FileTest.EXISTS)) continue;
                var s = new Sensor();
                s.kind = SensorKind.POWER;
                s.group = group;
                s.source = name;
                s.dev_dir = dir;
                s.label = read_line(Path.build_filename(dir, "power%s_label".printf(idx))) ?? "Power " + idx;
                s.path = Path.build_filename(dir, f);
                s.scale = 0.000001;
                attach(s, power);
            } else if (f.has_prefix("energy") && f.has_suffix("_input")) {
                string idx = f.substring(6, f.length - 12);
                var s = new Sensor();
                s.kind = SensorKind.POWER;
                s.group = group;
                s.source = name;
                s.dev_dir = dir;
                s.label = read_line(Path.build_filename(dir, "energy%s_label".printf(idx))) ?? "Energy " + idx;
                s.path = Path.build_filename(dir, f);
                s.mode = ReadMode.ENERGY;
                attach(s, power);
            }
        }
    }

    private void attach(Sensor s, Gee.ArrayList<Sensor> into) {
        if (!readable(s.path)) s.locked = true;
        else s.a = new ProcReader(s.path, 64);
        into.add(s);
    }

    private void discover_rapl() {
        string base_dir = p("class/powercap");
        bool have_msr = false;
        foreach (var z in list_dir(base_dir)) if (z.has_prefix("intel-rapl:")) have_msr = true;
        foreach (var z in list_dir(base_dir)) {
            string dir = Path.build_filename(base_dir, z);
            if (!FileUtils.test(Path.build_filename(dir, "energy_uj"), FileTest.EXISTS)) continue;
            if (z.has_prefix("intel-rapl-mmio") && have_msr) continue; // same package counter via MMIO
            string zone = read_line(Path.build_filename(dir, "name")) ?? z;
            var s = new Sensor();
            s.kind = SensorKind.POWER;
            s.source = "RAPL";
            s.path = Path.build_filename(dir, "energy_uj");
            s.mode = ReadMode.ENERGY;
            s.wrap = (int64) read_once(Path.build_filename(dir, "max_energy_range_uj"), 1);
            if (zone.has_prefix("package")) {
                s.group = "CPU";
                s.label = "Package" + (zone == "package-0" ? "" : " " + zone.substring(8));
            } else if (zone == "core") { s.group = "CPU"; s.label = "Cores"; }
            else if (zone == "uncore") { s.group = "CPU"; s.label = "Uncore / iGPU"; }
            else if (zone == "dram") { s.group = "Memory"; s.label = "DRAM"; }
            else if (zone == "psys") { s.group = "Platform"; s.label = "Whole platform (psys)"; }
            else { s.group = "RAPL"; s.label = zone; }
            attach(s, power);
            if (s.locked) rapl_locked = true;
        }
    }

    private void discover_batteries() {
        string base_dir = p("class/power_supply");
        foreach (var b in list_dir(base_dir)) {
            string dir = Path.build_filename(base_dir, b);
            if (read_line(Path.build_filename(dir, "type")) != "Battery") continue;
            // mice and headsets report a battery too (scope=Device), but no power
            if (read_line(Path.build_filename(dir, "scope")) == "Device") continue;
            var s = new Sensor();
            s.kind = SensorKind.POWER;
            s.group = "Battery";
            s.source = b;
            s.dev_dir = dir;
            s.label = b;
            string pw = Path.build_filename(dir, "power_now");
            string cur = Path.build_filename(dir, "current_now");
            string volt = Path.build_filename(dir, "voltage_now");
            if (FileUtils.test(pw, FileTest.EXISTS)) {
                s.path = pw;
                s.scale = 0.000001;
                attach(s, power);
            } else if (FileUtils.test(cur, FileTest.EXISTS) && FileUtils.test(volt, FileTest.EXISTS)) {
                s.path = cur;
                s.mode = ReadMode.CURRENT_X_VOLTAGE;
                s.scale = 1e-12;            // µA x µV -> W
                attach(s, power);
                if (!s.locked) s.b = new ProcReader(volt, 64);
            } else {
                continue;
            }
            string st = Path.build_filename(dir, "status");
            if (FileUtils.test(st, FileTest.EXISTS)) s.status = new ProcReader(st, 64);
        }
    }

    /* Zones whose type a hwmon driver already exports (acpitz, pch_*,
     * iwlwifi_1) would show twice; x86_pkg_temp is coretemp's package. */
    private void discover_thermal_zones(Gee.HashSet<string> hwmon_names) {
        string base_dir = p("class/thermal");
        foreach (var z in list_dir(base_dir)) {
            if (!z.has_prefix("thermal_zone")) continue;
            string dir = Path.build_filename(base_dir, z);
            string type = read_line(Path.build_filename(dir, "type")) ?? z;
            if (hwmon_names.contains(type) || type == "x86_pkg_temp") continue;
            var s = new Sensor();
            s.kind = SensorKind.TEMP;
            s.group = "Thermal zones";
            s.source = z;
            s.label = type;
            s.path = Path.build_filename(dir, "temp");
            s.scale = 0.001;
            // the first "critical" trip point, if the zone has one
            foreach (var f in list_dir(dir)) {
                if (!f.has_prefix("trip_point_") || !f.has_suffix("_type")) continue;
                if (read_line(Path.build_filename(dir, f)) != "critical") continue;
                s.crit = read_once(Path.build_filename(dir, f.replace("_type", "_temp")), 0.001);
                break;
            }
            attach(s, temps);
        }
    }

    private void discover_nvml() {
        if (nvml == null) {
            nvml = Module.open("libnvidia-ml.so.1", ModuleFlags.LAZY | ModuleFlags.LOCAL);
            if (nvml == null) return;           // no NVIDIA driver: nothing to do
            void* sym;
            if (!nvml.symbol("nvmlInit_v2", out sym)) { nvml = null; return; }
            // cast into a variable first: valac 0.56's C generator can't call a cast expression directly
            NvmlInitFn init = (NvmlInitFn) sym;
            if (init() != 0) { nvml = null; return; }
        }
        void* sym;
        if (!nvml.symbol("nvmlDeviceGetCount_v2", out sym)) return;
        uint count;
        NvmlCountFn get_count = (NvmlCountFn) sym;
        if (get_count(out count) != 0) return;
        void* handle_sym = null, name_sym = null, power_sym = null, temp_sym = null;
        if (!nvml.symbol("nvmlDeviceGetHandleByIndex_v2", out handle_sym)) return;
        if (!nvml.symbol("nvmlDeviceGetName", out name_sym)) return;
        if (nvml.symbol("nvmlDeviceGetPowerUsage", out power_sym)) nv_power = (NvmlPowerFn) power_sym;
        if (nvml.symbol("nvmlDeviceGetTemperature", out temp_sym)) nv_temp = (NvmlTempFn) temp_sym;
        NvmlHandleFn get_handle = (NvmlHandleFn) handle_sym;
        NvmlNameFn get_name = (NvmlNameFn) name_sym;
        for (uint i = 0; i < count; i++) {
            void* dev;
            if (get_handle(i, out dev) != 0) continue;
            char[] name = new char[96];
            string gpu = get_name(dev, (char*) name, 96) == 0 ? (string) name : "NVIDIA GPU";
            string group = count > 1 ? "GPU %u %s".printf(i + 1, gpu) : "GPU " + gpu;
            if (nv_power != null) {
                var s = new Sensor();
                s.kind = SensorKind.POWER; s.group = group; s.source = "NVML"; s.label = "Board power";
                s.mode = ReadMode.NVML_POWER; s.nv_dev = dev; s.path = "NVML";
                power.add(s);
            }
            if (nv_temp != null) {
                var s = new Sensor();
                s.kind = SensorKind.TEMP; s.group = group; s.source = "NVML"; s.label = "GPU";
                s.mode = ReadMode.NVML_TEMP; s.nv_dev = dev; s.path = "NVML";
                temps.add(s);
            }
        }
    }

    // ------------------------------------------------------------- naming

    /* After discovery: each sensor's "what it measures", and each group's
     * title and device name. pci.ids lookups happen here, once per group. */
    private void identify() {
        group_title.clear();
        group_device.clear();
        foreach (var list in new Gee.ArrayList<Sensor>[] {power, temps}) {
            foreach (var s in list) {
                if (s.what == "") s.what = describe(s);
                if (group_title.has_key(s.group)) continue;
                string title = s.group, device = "";
                if (s.group.has_prefix("NVMe ") || s.group.has_prefix("Disk ") || s.source == "NVML") {
                    int sp = s.group.index_of(" ");
                    title = s.group.substring(0, sp);
                    device = s.group.substring(sp + 1);
                    if (s.source == "NVML" && device.length > 2 && device[0].isdigit() && device[1] == ' ') {
                        title += " " + device.substring(0, 1);     // "GPU 2 RTX 3060" -> "GPU 2"
                        device = device.substring(2);
                    }
                } else if (s.group == "CPU" || s.group.has_prefix("CPU ")) {
                    device = HwInfo.cpu_model();
                } else if (s.group == "Memory") {
                    device = HwInfo.ram_summary();
                } else if (s.group.has_prefix("Motherboard")) {
                    device = HwInfo.board_name() ?? "";
                } else if (s.group.has_prefix("ACPI")) {
                    device = "Firmware (ACPI) thermal zone";
                } else if (s.group == "Platform") {
                    device = "Processor and the platform around it";
                } else if (s.group == "Thermal zones") {
                    device = "Zones the firmware and platform drivers define";
                } else if (s.group == "Battery") {
                    string? maker = read_line(Path.build_filename(s.dev_dir, "manufacturer"));
                    string? model = read_line(Path.build_filename(s.dev_dir, "model_name"));
                    device = string.joinv(" ", new string[] {maker ?? "", model ?? ""}).strip();
                } else if (s.dev_dir != "") {
                    device = HwInfo.device_name(Path.build_filename(s.dev_dir, "device")) ?? "";
                }
                group_title[s.group] = title;
                group_device[s.group] = device;
            }
        }
    }

    /* What a sensor measures, from its driver and label. Labels are the
     * drivers' own; where they're cryptic (Tctl, PPT, AUXTIN1) this says
     * what they mean. Empty when the label already says it all. */
    public static string describe(Sensor s) {
        string d = s.source.down(), l = s.label;
        string ll = l.down();
        int num = -1;
        // trailing number of the label ("Tccd2" -> 2, "Core 3" -> 3)
        int e = l.length;
        while (e > 0 && l[e - 1].isdigit()) e--;
        if (e < l.length) num = int.parse(l.substring(e));

        if (s.source == "RAPL") {
            if (l.has_prefix("Package")) return "Whole CPU package: cores, cache, iGPU, memory controller";
            if (l == "Cores") return "CPU cores only";
            if (l.has_prefix("Uncore")) return "Integrated GPU and the rest of the uncore";
            if (l == "DRAM") return "Memory (DRAM)";
            if (ll.contains("psys")) return "Whole platform: processor, memory and more";
            return "";
        }
        if (s.source == "NVML") return s.kind == SensorKind.POWER ? "Whole graphics card" : "GPU core";
        if (s.group == "Battery") return "Charge / discharge rate";
        if (s.group == "Thermal zones") return describe_zone(l);

        if (d == "k10temp" || d == "zenpower") {
            if (l == "Tctl") return "The value fans follow (on some Ryzen it includes an offset)";
            if (l == "Tdie") return "CPU die";
            if (ll.has_prefix("tccd")) return "Core complex die %d (one chiplet of cores)".printf(num);
            if (l.has_prefix("SVI2_P_Core")) return "CPU cores, from the voltage regulator";
            if (l.has_prefix("SVI2_P_SoC")) return "SoC: memory controller, iGPU and I/O";
            return "";
        }
        if (d == "coretemp") {
            if (l.has_prefix("Package")) return "Whole CPU package (the hottest core)";
            if (l.has_prefix("Core")) return "CPU core %d".printf(num);
            return "";
        }
        if (d == "zenergy" || d == "amd_energy") {
            if (ll.has_prefix("esocket")) return "Whole CPU socket";
            if (ll.has_prefix("ecore")) return "CPU core %d".printf(num);
            return "";
        }
        if (d == "amdgpu" || d == "radeon") {
            if (l == "edge") return "GPU die, edge sensor";
            if (l == "junction") return "GPU hotspot: the hottest point on the die";
            if (l == "mem") return "Video memory (VRAM)";
            if (l == "PPT" || l == "slowPPT") return "Package power: on Ryzen APUs the whole chip, CPU + GPU";
            if (l == "fastPPT") return "Short-term package power limit tracking";
            return s.kind == SensorKind.POWER ? "Graphics power" : "GPU";
        }
        if (d == "nouveau") return s.kind == SensorKind.POWER ? "Whole graphics card" : "GPU core";
        if (d == "i915" || d == "xe") return s.kind == SensorKind.POWER ? "Graphics power" : "GPU";
        if (d == "nvme") {
            if (l == "Composite") return "Drive temperature it reports and throttles on";
            if (num == 1) return "Usually the controller";
            if (num == 2) return "Usually the flash memory (NAND)";
            return "Extra drive sensor";
        }
        if (d == "drivetemp") return "Drive temperature (SMART)";
        if (d.has_prefix("iwlwifi") || d.has_prefix("mt79") || d.has_prefix("ath") || d.has_prefix("rtw")) return "Wi-Fi card";
        if (d.has_prefix("pch_")) return "Chipset (PCH)";
        if (d == "acpitz") return "Defined by the firmware: often a board or case estimate";
        if (d == "spd5118" || d == "jc42") return "Memory module (DIMM)";
        if (d == "cpu_thermal" || d.has_prefix("via_cputemp")) return "CPU";
        if (s.group.has_prefix("Motherboard")) {
            string u = l.up();
            if (u == "SYSTIN") return "Motherboard";
            if (u == "CPUTIN") return "Next to the CPU socket (board sensor)";
            if (u.has_prefix("AUXTIN")) return "Auxiliary input: VRM, chipset or case, depends on the board";
            if (u.has_prefix("PECI")) return "CPU, reported over PECI";
            if (u.has_prefix("SMBUSMASTER")) return "CPU, read over SMBus (often matches Tctl)";
            if (u.has_prefix("TSI")) return "CPU, read over AMD TSI";
            if (u.has_prefix("PCH")) return "Chipset";
            return "Board sensor";
        }
        return "";
    }

    /* ACPI / DPTF thermal zone types, which are four-letter codes. */
    private static string describe_zone(string type) {
        string t = type.down();
        if (t.has_prefix("int3400")) return "Intel DPTF policy zone (virtual)";
        if (t == "tcpu" || t.has_prefix("cpu")) return "CPU";
        if (t == "b0d4" || t == "b0db" || t.has_prefix("proc")) return "Intel processor thermal device";
        if (t.contains("skin") || t == "tskn") return "Laptop surface (skin)";
        if (t == "tmem") return "Memory area";
        if (t == "tamb" || t.has_prefix("amb")) return "Ambient air inside the case";
        if (t == "tchg" || t.has_prefix("chrg") || t.contains("charger")) return "Battery charger";
        if (t == "tvr" || t.has_prefix("vr")) return "Voltage regulator";
        if (t.has_prefix("sen")) return "Board sensor (DPTF)";
        if (t.has_prefix("soc_dts")) return "SoC thermal sensor";
        if (t.has_prefix("gpu")) return "GPU";
        if (t.has_prefix("iwlwifi")) return "Wi-Fi card";
        if (t.has_prefix("pch_")) return "Chipset (PCH)";
        if (t == "acpitz") return "Defined by the firmware: often a board or case estimate";
        return "";
    }

    /* Display order for groups: the parts people check first come first. */
    public static int group_rank(string group) {
        string[] order = {"CPU", "GPU", "Memory", "Platform", "Battery", "NVMe", "Disk",
                          "Chipset", "Motherboard", "Wi-Fi", "ACPI", "Thermal zones"};
        for (int i = 0; i < order.length; i++) if (group.has_prefix(order[i])) return i;
        return order.length;
    }

    // ------------------------------------------------------------- sampling

    public void sample(SensorKind kind) {
        int64 now = get_monotonic_time();
        foreach (var s in kind == SensorKind.POWER ? power : temps) {
            if (s.locked) continue;
            s.record(read_value(s, now));
        }
    }

    private double read_value(Sensor s, int64 now) {
        switch (s.mode) {
            case ReadMode.NVML_POWER: {
                uint mw = 0;
                return nv_power != null && nv_power(s.nv_dev, out mw) == 0 ? mw / 1000.0 : double.NAN;
            }
            case ReadMode.NVML_TEMP: {
                uint c = 0;
                return nv_temp != null && nv_temp(s.nv_dev, 0, out c) == 0 ? (double) c : double.NAN;
            }
            default: break;
        }
        if (s.a == null || !s.a.read()) return double.NAN;
        double v = parse_number(s.a);
        if (v.is_nan()) return v;
        if (s.status != null && s.status.read()) s.note = ((string) s.status.buf).strip().down();
        switch (s.mode) {
            case ReadMode.ENERGY: {
                int64 e = (int64) v;
                double w = double.NAN;
                if (s.prev_energy >= 0 && now > s.prev_us) {
                    int64 d = e - s.prev_energy;
                    if (d < 0 && s.wrap > 0) d += s.wrap;     // counter wrapped
                    if (d >= 0) w = d / (double) (now - s.prev_us);  // µJ / µs = W
                }
                s.prev_energy = e;
                s.prev_us = now;
                return w;
            }
            case ReadMode.CURRENT_X_VOLTAGE: {
                if (s.b == null || !s.b.read()) return double.NAN;
                double volt = parse_number(s.b);
                return Math.fabs(v * volt) * s.scale;
            }
            default:
                // some batteries report discharge power as negative
                return s.kind == SensorKind.POWER ? Math.fabs(v) * s.scale : v * s.scale;
        }
    }
}
