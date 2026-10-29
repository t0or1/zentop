/* process_scan.vala
 *
 * Direct /proc parsing -- no psutil, no per-process Python object
 * overhead: just read(), split, parse.
 *
 * /proc/[pid]/stat field layout (1-indexed), after splitting the part
 * AFTER the process name's closing ')':
 *   f[0]=state f[1]=ppid ... f[11]=utime f[12]=stime ... f[16]=nice
 *   f[17]=num_threads ... f[19]=starttime ... f[21]=rss(pages) ...
 *   f[36]=processor (last CPU core)
 * (Splitting off "pid" and "(comm)" first shifts every field's 1-indexed
 * number down by 3, hence the offsets above -- see `man proc`.)
 */

public class ProcessRow : Object {
    public int pid;
    public int ppid;
    public string name;
    public string user;
    public double cpu;
    public int cpuid;
    public uint64 mem;          // bytes (RSS)
    public int64 read_total = -1;
    public int64 write_total = -1;
    public double read_rate = -1.0;
    public double write_rate = -1.0;
    public int priority;        // nice value
    public string status;
    public int64 create_time;   // unix epoch seconds
    public double cputime;      // seconds
    public bool pinned = false;
    public string? highlight_color = null;
}

private class CpuSample {
    public int64 total_ticks;
    public double sampled_at;
}

private class IoSample {
    public int64 read_bytes;
    public int64 write_bytes;
    public double sampled_at;
}

public class ProcessCache : Object {
    private const int IO_EVERY_N_TICKS = 3;

    private Gee.HashMap<int, CpuSample> prev_cpu = new Gee.HashMap<int, CpuSample>();
    private Gee.HashMap<int, IoSample> prev_io = new Gee.HashMap<int, IoSample>();
    private Gee.HashMap<int, double?> last_read_rate = new Gee.HashMap<int, double?>();
    private Gee.HashMap<int, double?> last_write_rate = new Gee.HashMap<int, double?>();
    private Gee.HashMap<int, int64?> last_read_total = new Gee.HashMap<int, int64?>();
    private Gee.HashMap<int, int64?> last_write_total = new Gee.HashMap<int, int64?>();
    private Gee.HashMap<int, string> uid_cache = new Gee.HashMap<int, string>();

    private long clk_tck;
    private long page_size;
    private int64 boot_time_epoch;
    private int tick = 0;

    public ProcessCache() {
        clk_tck = Posix.sysconf(Posix._SC_CLK_TCK);
        page_size = Posix.sysconf(Posix._SC_PAGESIZE);
        boot_time_epoch = read_boot_time();
    }

    private int64 read_boot_time() {
        string content;
        try {
            FileUtils.get_contents("/proc/stat", out content);
        } catch (Error e) {
            return 0;
        }
        foreach (unowned string line in content.split("\n")) {
            if (line.has_prefix("btime ")) {
                return int64.parse(line.substring(6).strip());
            }
        }
        return 0;
    }

    private string resolve_username(int uid) {
        if (uid_cache.has_key(uid)) return uid_cache[uid];
        unowned Posix.Passwd? pw = Posix.getpwuid((Posix.uid_t) uid);
        string name = (pw != null) ? pw.pw_name : uid.to_string();
        uid_cache[uid] = name;
        return name;
    }

    private static string status_word(string letter) {
        switch (letter) {
            case "R": return "running";
            case "S": return "sleeping";
            case "D": return "disk-sleep";
            case "T": return "stopped";
            case "t": return "tracing-stop";
            case "Z": return "zombie";
            case "X": case "x": return "dead";
            case "I": return "idle";
            case "P": return "parked";
            default: return "unknown";
        }
    }

    /* One tick: enumerate /proc, parse each pid, return the rows found. */
    public Gee.ArrayList<ProcessRow> refresh() {
        tick++;
        bool fetch_io = (tick % IO_EVERY_N_TICKS == 0);
        var rows = new Gee.ArrayList<ProcessRow>();
        double now = (double) GLib.get_monotonic_time() / 1000000.0;

        Dir dir;
        try {
            dir = Dir.open("/proc", 0);
        } catch (Error e) {
            return rows;
        }

        string? entry;
        while ((entry = dir.read_name()) != null) {
            if (!is_all_digits(entry)) continue;
            int pid = int.parse(entry);
            if (pid <= 0) continue;
            var row = read_process(pid, now, fetch_io);
            if (row != null) rows.add(row);
        }

        return rows;
    }

    private static bool is_all_digits(string s) {
        if (s.length == 0) return false;
        for (int i = 0; i < s.length; i++) {
            if (!s[i].isdigit()) return false;
        }
        return true;
    }

    private ProcessRow? read_process(int pid, double now, bool fetch_io) {
        string stat_content;
        try {
            FileUtils.get_contents("/proc/%d/stat".printf(pid), out stat_content);
        } catch (Error e) {
            return null; // process vanished between listing and reading -- normal, skip
        }

        int open_paren = stat_content.index_of_char('(');
        int close_paren = stat_content.last_index_of_char(')');
        if (open_paren < 0 || close_paren < open_paren) return null;

        string name = stat_content.substring(open_paren + 1, close_paren - open_paren - 1);
        string rest = stat_content.substring(close_paren + 1).strip();
        string[] f = rest.split(" ");
        if (f.length < 37) return null;

        Posix.Stat st;
        if (Posix.stat("/proc/%d".printf(pid), out st) != 0) return null;
        int uid = (int) st.st_uid;

        int64 utime = int64.parse(f[11]);
        int64 stime = int64.parse(f[12]);
        int64 total_ticks = utime + stime;

        double cpu_percent = 0.0;
        var prev = prev_cpu.has_key(pid) ? prev_cpu[pid] : null;
        if (prev != null) {
            double dt = now - prev.sampled_at;
            if (dt > 0) {
                double delta_ticks = (double) (total_ticks - prev.total_ticks);
                cpu_percent = (delta_ticks / clk_tck) / dt * 100.0;
            }
        }
        var sample = new CpuSample();
        sample.total_ticks = total_ticks;
        sample.sampled_at = now;
        prev_cpu[pid] = sample;

        var row = new ProcessRow();
        row.pid = pid;
        row.ppid = int.parse(f[1]);
        row.name = name;
        row.user = resolve_username(uid);
        row.cpu = cpu_percent;
        row.cpuid = int.parse(f[36]);
        row.mem = (uint64) (int64.parse(f[21]) * page_size);
        row.priority = int.parse(f[16]);
        row.status = status_word(f[0]);
        row.cputime = (double) total_ticks / clk_tck;
        row.create_time = boot_time_epoch + (int64) (int64.parse(f[19]) / clk_tck);

        if (fetch_io) {
            fetch_io_counters(pid, now, row);
        } else if (last_read_total.has_key(pid)) {
            row.read_total = last_read_total[pid];
            row.write_total = last_write_total[pid];
            row.read_rate = last_read_rate[pid];
            row.write_rate = last_write_rate[pid];
        }

        return row;
    }

    private void fetch_io_counters(int pid, double now, ProcessRow row) {
        string content;
        try {
            FileUtils.get_contents("/proc/%d/io".printf(pid), out content);
        } catch (Error e) {
            return; // no permission (common for processes you don't own) -- leave as -1
        }

        int64 read_bytes = -1, write_bytes = -1;
        foreach (unowned string line in content.split("\n")) {
            if (line.has_prefix("read_bytes: ")) {
                read_bytes = int64.parse(line.substring(12).strip());
            } else if (line.has_prefix("write_bytes: ")) {
                write_bytes = int64.parse(line.substring(13).strip());
            }
        }
        if (read_bytes < 0 || write_bytes < 0) return;

        row.read_total = read_bytes;
        row.write_total = write_bytes;

        var prev = prev_io.has_key(pid) ? prev_io[pid] : null;
        if (prev != null) {
            double dt = now - prev.sampled_at;
            if (dt > 0) {
                row.read_rate = (read_bytes - prev.read_bytes) / dt;
                row.write_rate = (write_bytes - prev.write_bytes) / dt;
            } else {
                row.read_rate = 0;
                row.write_rate = 0;
            }
        } else {
            row.read_rate = 0;
            row.write_rate = 0;
        }

        var s = new IoSample();
        s.read_bytes = read_bytes;
        s.write_bytes = write_bytes;
        s.sampled_at = now;
        prev_io[pid] = s;

        last_read_total[pid] = read_bytes;
        last_write_total[pid] = write_bytes;
        last_read_rate[pid] = row.read_rate;
        last_write_rate[pid] = row.write_rate;
    }
}
