/* proc_reader.vala -- re-reading small /proc files cheaply.
 *
 * Opening a /proc file costs a path walk plus kernel allocations; keeping
 * the fd and calling pread(fd, 0) regenerates the contents without either.
 * Measured on this machine: 4.0 us for open+read+close vs 1.4 us for pread.
 * For /proc/<pid>/* the fd stays bound to that process, so once it exits
 * reads fail with ESRCH: a reused pid can never be mistaken for the old one.
 * Android's lmkd uses the same technique for its hot files. */

// struct rlimit is two rlim_t (64-bit): passed as a uint64[2]
[CCode (cname = "getrlimit", cheader_filename = "sys/resource.h")]
private extern int c_getrlimit(int resource, [CCode (array_length = false)] uint64[] rl);
[CCode (cname = "setrlimit", cheader_filename = "sys/resource.h")]
private extern int c_setrlimit(int resource, [CCode (array_length = false)] uint64[] rl);
[CCode (cname = "RLIMIT_NOFILE", cheader_filename = "sys/resource.h")]
private extern const int C_RLIMIT_NOFILE;

/* One persistent fd per process needs more than the usual soft limit of
 * 1024 on a busy desktop; the hard limit (often 524288) is ours to take. */
public void raise_fd_limit() {
    uint64[] rl = new uint64[2];   // {soft, hard}
    if (c_getrlimit(C_RLIMIT_NOFILE, rl) != 0 || rl[0] >= rl[1]) return;
    rl[0] = uint64.min(rl[1], 65536);
    c_setrlimit(C_RLIMIT_NOFILE, rl);
}

public class ProcReader {
    public uint8[] buf;
    public ssize_t len = 0;
    private string path;
    private int fd = -1;

    public ProcReader(string path, int size = 4096) {
        this.path = path;
        buf = new uint8[size];
    }

    ~ProcReader() {
        if (fd >= 0) Posix.close(fd);
    }

    /* Fills `buf` (NUL-terminated); false when the file is gone or unreadable.
     * `reopen`: retry once with a fresh open (system-wide files only; for a
     * pid's files a failed read means the process is gone). */
    public bool read(bool reopen = true) {
        if (fd < 0) fd = Posix.open(path, Posix.O_RDONLY | Posix.O_CLOEXEC);
        if (fd < 0) return false;
        len = Posix.pread(fd, buf, buf.length - 1, 0);
        if (len < 0 && reopen) {
            Posix.close(fd);
            fd = Posix.open(path, Posix.O_RDONLY | Posix.O_CLOEXEC);
            if (fd >= 0) len = Posix.pread(fd, buf, buf.length - 1, 0);
        }
        if (len < 0) { len = 0; return false; }
        buf[len] = 0;
        return true;
    }

    public int get_fd() { return fd; }
}

/* Minimal cursor over a ProcReader buffer: no strings, no allocation. */
public struct Scan {
    public unowned uint8[] b;
    public int i;
    public int n;

    public Scan(ProcReader r) { b = r.buf; i = 0; n = (int) r.len; }

    public bool at_end() { return i >= n; }

    public bool starts_with(string s) {
        if (i + s.length > n) return false;
        for (int k = 0; k < s.length; k++) if (b[i + k] != s[k]) return false;
        return true;
    }

    public void skip(int count) { i += count; }

    /* Next unsigned integer on this line (skips spaces); -1 if none. */
    public int64 next_uint() {
        while (i < n && b[i] == ' ') i++;
        if (i >= n || b[i] < '0' || b[i] > '9') return -1;
        int64 v = 0;
        while (i < n && b[i] >= '0' && b[i] <= '9') { v = v * 10 + (b[i] - '0'); i++; }
        return v;
    }

    public void next_line() {
        while (i < n && b[i] != '\n') i++;
        if (i < n) i++;
    }

    /* Moves past the next `c` on this line; false if the line has none. */
    public bool skip_past(uint8 c) {
        while (i < n && b[i] != c && b[i] != '\n') i++;
        if (i >= n || b[i] != c) return false;
        i++;
        return true;
    }
}
