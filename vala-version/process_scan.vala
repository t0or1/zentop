/* process_scan.vala -- per-process figures straight from /proc.
 *
 * Runs on a worker thread. Cost per process per tick: one open/read of
 * /proc/<pid>/stat into a reused buffer, parsed in place (no split, no
 * per-field strings). Everything that never changes for a pid (name,
 * start time, formatted "started") is resolved once and kept in a PidState,
 * which also carries the previous CPU/IO samples. PidStates of processes
 * that exited are dropped every tick, so the cache can't grow over a long
 * session. Disk I/O (/proc/<pid>/io) is read every 3rd tick only. */

public class ProcessRow {
    public int pid;
    public int ppid;
    public string name;
    public string name_key;       // lowercase, for search and sorting
    public string user;
    public double cpu;            // % of one core
    public int cpuid;
    public uint64 mem;            // RSS bytes
    public int64 read_total = -1;
    public int64 write_total = -1;
    public double read_rate = -1;
    public double write_rate = -1;
    public int priority;          // nice
    public unowned string status;
    public int64 create_time;     // unix seconds
    public string started;
    public double cputime;        // seconds
    public bool pinned;
    public string? highlight_color;
}

private class PidState {
    public int64 start_ticks;     // identifies the process across pid reuse
    public string stat_path;
    public string io_path;
    public string name;
    public string name_key;
    public string user = "-";
    public int64 create_time;
    public string started;
    public int started_day;
    public uint seen;
    // previous samples
    public int64 cpu_ticks = -1;
    public double cpu_at;
    public int64 io_read = -1;
    public int64 io_write = -1;
    public double io_at;
    // last I/O figures, shown on the ticks that skip /proc/<pid>/io
    public int64 read_total = -1;
    public int64 write_total = -1;
    public double read_rate = -1;
    public double write_rate = -1;
}

public class ProcessCache : Object {
    private const int IO_EVERY_N_TICKS = 3;
    // field numbers counted after the ")" that closes the process name
    private const int F_STATE = 0;
    private const int F_PPID = 1;
    private const int F_UTIME = 11;
    private const int F_STIME = 12;
    private const int F_NICE = 16;
    private const int F_START = 19;
    private const int F_RSS = 21;
    private const int F_CPU = 36;

    private Gee.HashMap<int, PidState> states = new Gee.HashMap<int, PidState>();
    private Gee.HashMap<uint, string> users = new Gee.HashMap<uint, string>();
    private uint8[] buf = new uint8[4096];
    private int64[] fields = new int64[F_CPU + 1];
    private double clk_tck;
    private uint64 page_size;
    private int64 boot_time;
    private uint tick = 0;

    public ProcessCache() {
        clk_tck = (double) Posix.sysconf(Posix._SC_CLK_TCK);
        page_size = (uint64) Posix.sysconf(Posix._SC_PAGESIZE);
        boot_time = read_boot_time();
    }

    private static int64 read_boot_time() {
        string content;
        try { FileUtils.get_contents("/proc/stat", out content); } catch (Error e) { return 0; }
        foreach (unowned string line in content.split("\n"))
            if (line.has_prefix("btime ")) return int64.parse(line.substring(6).strip());
        return 0;
    }

    private string user_name(uint uid) {
        var hit = users[uid];
        if (hit != null) return hit;
        unowned Posix.Passwd? pw = Posix.getpwuid((Posix.uid_t) uid);
        string name = pw != null ? pw.pw_name : uid.to_string();
        users[uid] = name;
        return name;
    }

    private static unowned string status_word(uint8 c) {
        switch (c) {
            case 'R': return "running";
            case 'S': return "sleeping";
            case 'D': return "disk-sleep";
            case 'T': return "stopped";
            case 't': return "tracing-stop";
            case 'Z': return "zombie";
            case 'X': case 'x': return "dead";
            case 'I': return "idle";
            case 'P': return "parked";
            default: return "unknown";
        }
    }

    /* Whole small /proc file into `buf`; returns bytes read or -1. */
    private ssize_t read_file(string path) {
        int fd = Posix.open(path, Posix.O_RDONLY);
        if (fd < 0) return -1;
        ssize_t n = Posix.read(fd, buf, buf.length - 1);
        Posix.close(fd);
        return n;
    }

    /* One tick: every pid in /proc, parsed. */
    public Gee.ArrayList<ProcessRow> refresh() {
        tick++;
        bool fetch_io = tick % IO_EVERY_N_TICKS == 0;
        double now = GLib.get_monotonic_time() / 1000000.0;
        int today = Fmt.today_ymd();
        var rows = new Gee.ArrayList<ProcessRow>();
        Dir dir;
        try { dir = Dir.open("/proc", 0); } catch (Error e) { return rows; }
        unowned string? entry;
        while ((entry = dir.read_name()) != null) {
            uint8 c0 = entry[0];
            if (c0 < '1' || c0 > '9') continue;  // pids are digits, never 0-prefixed
            int pid = int.parse(entry);
            if (pid <= 0) continue;
            var row = read_process(pid, now, today, fetch_io);
            if (row != null) rows.add(row);
        }
        prune();
        return rows;
    }

    private void prune() {
        var gone = new Gee.ArrayList<int>();
        foreach (var e in states.entries) if (e.value.seen != tick) gone.add(e.key);
        foreach (var pid in gone) states.unset(pid);
    }

    /* Parse "pid (name) S ppid ..." in place. Returns false if malformed. */
    private bool parse_stat(ssize_t n, out int name_start, out int name_end, out uint8 state) {
        name_start = name_end = 0;
        state = '?';
        int open = -1, close = -1;
        for (int i = 0; i < n; i++) if (buf[i] == '(') { open = i; break; }
        for (int i = (int) n - 1; i > open; i--) if (buf[i] == ')') { close = i; break; }
        if (open < 0 || close < 0) return false;
        name_start = open + 1;
        name_end = close;
        int f = 0, i = close + 2;
        if (i >= n) return false;
        state = buf[i];
        while (i < n && buf[i] != ' ') i++;
        while (f < F_CPU && i < n) {
            i++; // skip the space
            f++;
            bool neg = false;
            if (i < n && buf[i] == '-') { neg = true; i++; }
            int64 v = 0;
            while (i < n && buf[i] >= '0' && buf[i] <= '9') { v = v * 10 + (buf[i] - '0'); i++; }
            fields[f] = neg ? -v : v;
            while (i < n && buf[i] != ' ' && buf[i] != '\n') i++;
        }
        return f == F_CPU;
    }

    private ProcessRow? read_process(int pid, double now, int today, bool fetch_io) {
        var st = states[pid];
        string stat_path = st != null ? st.stat_path : "/proc/%d/stat".printf(pid);
        ssize_t n = read_file(stat_path);
        if (n <= 0) return null; // exited between listing and reading: normal
        buf[n] = 0;
        int ns, ne;
        uint8 state;
        if (!parse_stat(n, out ns, out ne, out state)) return null;

        int64 start_ticks = fields[F_START];
        if (st == null || st.start_ticks != start_ticks) {
            st = new_state(pid, stat_path, start_ticks, ((string) buf).substring(ns, ne - ns), today);
            states[pid] = st;
        } else if (st.started_day != today) {
            st.started = Fmt.started(st.create_time, today); // the date rolled over
            st.started_day = today;
        }
        st.seen = tick;

        var row = new ProcessRow();
        row.pid = pid;
        row.ppid = (int) fields[F_PPID];
        row.name = st.name;
        row.name_key = st.name_key;
        row.status = status_word(state);
        row.cpuid = (int) fields[F_CPU];
        row.mem = (uint64) fields[F_RSS] * page_size;
        row.priority = (int) fields[F_NICE];
        row.create_time = st.create_time;
        row.started = st.started;
        int64 ticks = fields[F_UTIME] + fields[F_STIME];
        row.cputime = ticks / clk_tck;
        if (st.cpu_ticks >= 0 && now > st.cpu_at)
            row.cpu = double.max(ticks - st.cpu_ticks, 0) / clk_tck / (now - st.cpu_at) * 100.0;
        st.cpu_ticks = ticks;
        st.cpu_at = now;

        if (fetch_io) {
            refresh_user(st, pid);  // uid can change (setuid); cheap enough every 3rd tick
            read_io(st, now);
        }
        row.user = st.user;
        row.read_total = st.read_total;
        row.write_total = st.write_total;
        row.read_rate = st.read_rate;
        row.write_rate = st.write_rate;
        return row;
    }

    private PidState new_state(int pid, string stat_path, int64 start_ticks, string comm, int today) {
        var st = new PidState();
        st.start_ticks = start_ticks;
        st.stat_path = stat_path;
        st.io_path = "/proc/%d/io".printf(pid);
        st.name = full_name(pid, comm);
        st.name_key = st.name.down();
        st.create_time = boot_time + (int64) (start_ticks / clk_tck);
        st.started = Fmt.started(st.create_time, today);
        st.started_day = today;
        refresh_user(st, pid);
        return st;
    }

    /* The kernel truncates comm to 15 chars; like psutil, recover the full
     * name from argv[0] when it starts with the truncated one. Once per pid. */
    private string full_name(int pid, string comm) {
        if (comm.length < 15) return comm;
        ssize_t n = read_file("/proc/%d/cmdline".printf(pid));
        if (n <= 0) return comm;
        buf[n] = 0;
        string argv0 = (string) buf;        // stops at the first NUL
        string base_name = Path.get_basename(argv0.split(" ")[0]);
        return base_name.has_prefix(comm) ? base_name : comm;
    }

    private void refresh_user(PidState st, int pid) {
        Posix.Stat s;
        if (Posix.stat(Path.get_dirname(st.stat_path), out s) == 0) st.user = user_name((uint) s.st_uid);
    }

    private void read_io(PidState st, double now) {
        ssize_t n = read_file(st.io_path);
        if (n <= 0) return; // not our process: stays "-"
        buf[n] = 0;
        int64 rd = io_field((string) buf, "read_bytes: ");
        int64 wr = io_field((string) buf, "write_bytes: ");
        if (rd < 0 || wr < 0) return;
        if (st.io_read >= 0 && now > st.io_at) {
            double dt = now - st.io_at;
            st.read_rate = double.max(rd - st.io_read, 0) / dt;   // counters can reset
            st.write_rate = double.max(wr - st.io_write, 0) / dt;
        } else {
            st.read_rate = st.write_rate = 0;
        }
        st.io_read = st.read_total = rd;
        st.io_write = st.write_total = wr;
        st.io_at = now;
    }

    private static int64 io_field(string text, string key) {
        int at = text.index_of(key);
        if (at < 0) return -1;
        int64 v = 0;
        for (int i = at + key.length; i < text.length && text[i].isdigit(); i++) v = v * 10 + (text[i] - '0');
        return v;
    }
}
