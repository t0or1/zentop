/* resources_data.vala -- CPU / memory / network figures from /proc, with the
 * maths psutil uses, so both versions show the same numbers. Each file is
 * kept open and re-read with pread, then parsed in place: no line splitting,
 * no per-field strings. /proc/stat is read only as far as the cpu lines (its
 * "intr" line alone can be several KB). One sampler is shared by the header
 * and the Resources tab, so nothing is read twice in the same second. */

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
    private ProcReader stat_file;
    private ProcReader mem_file = new ProcReader("/proc/meminfo", 8192);
    private ProcReader net_file = new ProcReader("/proc/net/dev", 8192);

    private CpuTimes prev_total = CpuTimes();
    private CpuTimes[] prev_cores = new CpuTimes[0];
    private CpuTimes[] now_cores = new CpuTimes[0];
    private bool have_cpu = false;
    private int64 cpu_sampled_us = 0;

    private uint64 prev_rx = 0;
    private uint64 prev_tx = 0;
    private int64 prev_net_us = 0;

    public double cpu_total = 0;        // % of the whole machine
    public double[] cpu_cores = new double[0];
    public double rx_rate = 0;          // bytes/s
    public double tx_rate = 0;
    public MemSnapshot mem = new MemSnapshot();

    public ResourcesSampler() {
        // "cpu" + one line per core, ~100 bytes each, plus slack
        stat_file = new ProcReader("/proc/stat", 512 + 128 * (int) GLib.get_num_processors());
    }

    /* "cpu  user nice system idle iowait irq softirq steal guest guest_nice".
     * guest time is already counted inside user, so it's left out of the
     * total; idle + iowait count as not-busy (psutil does the same). */
    private static CpuTimes parse_cpu(ref Scan s) {
        var t = CpuTimes();
        uint64 idle = 0;
        for (int f = 0; f < 8; f++) {
            int64 v = s.next_uint();
            if (v < 0) break;
            t.total += v;
            if (f == 3 || f == 4) idle += v;
        }
        t.busy = t.total - idle;
        return t;
    }

    private static double pct(CpuTimes now, CpuTimes before) {
        if (now.total <= before.total) return 0;
        double p = (double) (now.busy - before.busy) / (double) (now.total - before.total) * 100.0;
        return p.clamp(0, 100);
    }

    /* Skips the read if the last sample is younger than `min_age_ms`, so the
     * header and the Resources tab can both ask in the same tick. */
    public void sample_cpu(int min_age_ms = 0) {
        int64 now_us = get_monotonic_time();
        if (have_cpu && now_us - cpu_sampled_us < min_age_ms * 1000) return;
        if (!stat_file.read()) return;
        cpu_sampled_us = now_us;
        var s = Scan(stat_file);
        CpuTimes total = CpuTimes();
        int cores = 0;
        while (!s.at_end() && s.starts_with("cpu")) {
            bool aggregate = s.starts_with("cpu ");
            s.skip(3);
            if (!aggregate) s.next_uint();  // the core number
            var t = parse_cpu(ref s);
            if (aggregate) total = t;
            else {
                if (cores >= now_cores.length) now_cores.resize(cores + 1);
                now_cores[cores] = t;
                cores++;
            }
            s.next_line();
        }
        if (prev_cores.length != cores) {
            prev_cores = new CpuTimes[cores];
            cpu_cores = new double[cores];
            have_cpu = false;
        }
        if (have_cpu) cpu_total = pct(total, prev_total);
        for (int i = 0; i < cores; i++) {
            if (have_cpu) cpu_cores[i] = pct(now_cores[i], prev_cores[i]);
            prev_cores[i] = now_cores[i];
        }
        prev_total = total;
        have_cpu = true;
    }

    public MemSnapshot sample_memory() {
        if (!mem_file.read()) return mem;
        var m = new MemSnapshot();
        uint64 free = 0, available = 0, buffers = 0, cached = 0, reclaimable = 0, swap_free = 0;
        bool have_available = false;
        var s = Scan(mem_file);
        while (!s.at_end()) {
            int key_at = s.i;
            if (!s.skip_past(':')) { s.next_line(); continue; }
            int64 kb = s.next_uint();   // not inside max(): Vala emits MAX(), which evaluates twice
            uint64 b = kb > 0 ? (uint64) kb * 1024 : 0;
            // compare the key in place: first byte, then the rest
            unowned uint8[] k = s.b;
            switch (k[key_at]) {
                case 'M':
                    if (key_is(k, key_at, "MemTotal:")) m.total = b;
                    else if (key_is(k, key_at, "MemFree:")) free = b;
                    else if (key_is(k, key_at, "MemAvailable:")) { available = b; have_available = true; }
                    break;
                case 'B': if (key_is(k, key_at, "Buffers:")) buffers = b; break;
                case 'C': if (key_is(k, key_at, "Cached:")) cached = b; break;
                case 'S':
                    if (key_is(k, key_at, "SReclaimable:")) reclaimable = b;
                    else if (key_is(k, key_at, "SwapTotal:")) m.swap_total = b;
                    else if (key_is(k, key_at, "SwapFree:")) swap_free = b;
                    break;
            }
            s.next_line();
        }
        uint64 cache_all = cached + reclaimable;
        uint64 not_used = free + buffers + cache_all;
        m.used = m.total > not_used ? m.total - not_used : m.total - free;
        if (!have_available) available = free + buffers + cache_all;
        m.percent = m.total > 0 ? (double) (m.total - available) / (double) m.total * 100.0 : 0;
        m.swap_used = m.swap_total - swap_free;
        m.swap_percent = m.swap_total > 0 ? (double) m.swap_used / (double) m.swap_total * 100.0 : 0;
        mem = m;
        return m;
    }

    private static bool key_is(uint8[] b, int at, string key) {
        for (int k = 0; k < key.length; k++) if (b[at + k] != key[k]) return false;
        return true;
    }

    /* Sums every interface (lo included), same as psutil.net_io_counters(). */
    public void sample_network() {
        if (!net_file.read()) return;
        uint64 rx = 0, tx = 0;
        var s = Scan(net_file);
        while (!s.at_end()) {
            if (s.skip_past(':')) {
                int64 r = s.next_uint();
                for (int f = 0; f < 7; f++) s.next_uint();
                int64 t = s.next_uint();
                if (r > 0) rx += r;
                if (t > 0) tx += t;
            }
            s.next_line();
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
