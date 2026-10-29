/* resources_data.vala -- CPU / memory / network figures read straight from
 * /proc, no libraries. Each sample is one small file read, so it stays on
 * the main thread (same call the Python version makes with psutil).
 * The maths mirror psutil, so both versions show the same numbers. */

public struct CpuTimes {
    public uint64 busy;
    public uint64 total;
}

public class MemSnapshot {
    public uint64 total;
    public uint64 used;      // total - free - buffers - cached (psutil "used")
    public double percent;   // (total - available) / total, like psutil
    public uint64 swap_total;
    public uint64 swap_used;
    public double swap_percent;
}

public class ResourcesSampler : Object {
    private CpuTimes prev_total = CpuTimes();
    private CpuTimes[] prev_cores = new CpuTimes[0];
    private bool have_cpu = false;

    private uint64 prev_rx = 0;
    private uint64 prev_tx = 0;
    private int64 prev_net_us = 0;

    public double cpu_total = 0;        // % of the whole machine
    public double[] cpu_cores = new double[0];
    public double rx_rate = 0;          // bytes/s
    public double tx_rate = 0;

    private static string? read_proc(string path) {
        string data;
        try {
            FileUtils.get_contents(path, out data);
        } catch (Error e) {
            return null;
        }
        return data;
    }

    /* "cpu  user nice system idle iowait irq softirq steal guest guest_nice".
     * guest time is already counted inside user, so it's left out of the
     * total; idle + iowait count as not-busy (psutil does the same). */
    private static CpuTimes parse_cpu_line(string line) {
        var t = CpuTimes();
        string[] f = line.split_set(" ", 0);
        uint64[] v = new uint64[8];
        int n = 0;
        for (int i = 1; i < f.length && n < 8; i++) {
            if (f[i] == "") continue;
            v[n++] = uint64.parse(f[i]);
        }
        uint64 idle = v[3] + v[4];
        uint64 total = 0;
        for (int i = 0; i < 8; i++) total += v[i];
        t.total = total;
        t.busy = total - idle;
        return t;
    }

    private static double pct(CpuTimes now, CpuTimes before) {
        uint64 dt = now.total - before.total;
        if (dt == 0 || now.total < before.total) return 0;
        double p = (double) (now.busy - before.busy) / (double) dt * 100.0;
        return p.clamp(0, 100);
    }

    public void sample_cpu() {
        string? data = read_proc("/proc/stat");
        if (data == null) return;
        CpuTimes total = CpuTimes();
        var cores = new Gee.ArrayList<CpuTimes?>();
        foreach (unowned string line in data.split("\n")) {
            if (!line.has_prefix("cpu")) break;  // cpu lines are always first
            if (line.has_prefix("cpu ")) total = parse_cpu_line(line);
            else cores.add(parse_cpu_line(line));
        }
        if (prev_cores.length != cores.size) {
            prev_cores = new CpuTimes[cores.size];
            cpu_cores = new double[cores.size];
            have_cpu = false;
        }
        if (have_cpu) cpu_total = pct(total, prev_total);
        for (int i = 0; i < cores.size; i++) {
            if (have_cpu) cpu_cores[i] = pct(cores[i], prev_cores[i]);
            prev_cores[i] = cores[i];
        }
        prev_total = total;
        have_cpu = true;
    }

    public MemSnapshot sample_memory() {
        var m = new MemSnapshot();
        string? data = read_proc("/proc/meminfo");
        if (data == null) return m;
        uint64 free = 0, available = 0, buffers = 0, cached = 0, reclaimable = 0, swap_free = 0;
        bool have_available = false;
        foreach (unowned string line in data.split("\n")) {
            int colon = line.index_of_char(':');
            if (colon < 0) continue;
            string key = line.substring(0, colon);
            uint64 kb = uint64.parse(line.substring(colon + 1).strip().split(" ")[0]);
            uint64 b = kb * 1024;
            switch (key) {
                case "MemTotal": m.total = b; break;
                case "MemFree": free = b; break;
                case "MemAvailable": available = b; have_available = true; break;
                case "Buffers": buffers = b; break;
                case "Cached": cached = b; break;
                case "SReclaimable": reclaimable = b; break;
                case "SwapTotal": m.swap_total = b; break;
                case "SwapFree": swap_free = b; break;
            }
        }
        uint64 cache_all = cached + reclaimable;
        uint64 not_used = free + buffers + cache_all;
        m.used = m.total > not_used ? m.total - not_used : m.total - free;
        if (!have_available) available = free + buffers + cache_all;
        m.percent = m.total > 0 ? (double) (m.total - available) / (double) m.total * 100.0 : 0;
        m.swap_used = m.swap_total - swap_free;
        m.swap_percent = m.swap_total > 0 ? (double) m.swap_used / (double) m.swap_total * 100.0 : 0;
        return m;
    }

    /* Sums every interface (lo included), same as psutil.net_io_counters(). */
    public void sample_network() {
        string? data = read_proc("/proc/net/dev");
        if (data == null) return;
        uint64 rx = 0, tx = 0;
        foreach (unowned string line in data.split("\n")) {
            int colon = line.index_of_char(':');
            if (colon < 0) continue;
            string[] f = line.substring(colon + 1).split_set(" ", 0);
            int n = 0;
            foreach (unowned string s in f) {
                if (s == "") continue;
                if (n == 0) rx += uint64.parse(s);
                else if (n == 8) { tx += uint64.parse(s); break; }
                n++;
            }
        }
        int64 now = get_monotonic_time();
        if (prev_net_us != 0) {
            double dt = (now - prev_net_us) / 1000000.0;
            rx_rate = dt > 0 && rx >= prev_rx ? (rx - prev_rx) / dt : 0;
            tx_rate = dt > 0 && tx >= prev_tx ? (tx - prev_tx) / dt : 0;
        }
        prev_rx = rx;
        prev_tx = tx;
        prev_net_us = now;
    }
}
