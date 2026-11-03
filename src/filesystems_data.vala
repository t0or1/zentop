/* filesystems_data.vala -- mounted partitions, their usage, and the
 * one-level disk-usage scan behind the treemap. No GTK in here: the scan
 * runs on worker threads, walking with openat/fstatat so no path string
 * is built per file. */

public class Partition {
    public string device;
    public string mountpoint;
    public string fstype;
    public uint64 total;
    public uint64 used;
    public uint64 free;
    public double percent;
}

public class ScanEntry {
    public string name;
    public uint64 size;
    public bool is_dir;
    public ScanEntry(string name, uint64 size, bool is_dir) { this.name = name; this.size = size; this.is_dir = is_dir; }
}

[CCode (cname = "openat", cheader_filename = "fcntl.h")]
private extern int c_openat(int dirfd, string path, int flags);
[CCode (cname = "fstatat", cheader_filename = "fcntl.h,sys/stat.h")]
private extern int c_fstatat(int dirfd, string path, out Posix.Stat buf, int flags);
[CCode (cname = "O_DIRECTORY", cheader_filename = "fcntl.h")]
private extern const int C_O_DIRECTORY;
[CCode (cname = "O_NOFOLLOW", cheader_filename = "fcntl.h")]
private extern const int C_O_NOFOLLOW;
[CCode (cname = "O_CLOEXEC", cheader_filename = "fcntl.h")]
private extern const int C_O_CLOEXEC;
[CCode (cname = "AT_SYMLINK_NOFOLLOW", cheader_filename = "fcntl.h")]
private extern const int C_AT_SYMLINK_NOFOLLOW;

namespace FsData {
    private const uchar DT_LNK = 10;

    /* /proc/mounts escapes spaces etc. as octal: "\040". */
    private string unescape_mount(string s) {
        if (!s.contains("\\")) return s;
        var b = new StringBuilder();
        for (int i = 0; i < s.length; i++) {
            if (s[i] == '\\' && i + 3 < s.length) {
                string oct = s.substring(i + 1, 3);
                int v = 0;
                bool ok = oct.length == 3;
                for (int k = 0; ok && k < 3; k++) {
                    if (oct[k] < '0' || oct[k] > '7') ok = false; else v = v * 8 + (oct[k] - '0');
                }
                if (ok) { b.append_c((char) v); i += 3; continue; }
            }
            b.append_c(s[i]);
        }
        return b.str;
    }

    /* Filesystems the kernel backs with a real device (no "nodev" flag in
     * /proc/filesystems) -- the same filter psutil.disk_partitions() uses. */
    private Gee.HashSet<string>? fstypes_cache = null;

    /* Cached; re-read only when a mount shows a type we haven't seen (a
     * module such as exfat loaded since), so the 5 s refresh reads one file. */
    private Gee.HashSet<string> physical_fstypes(bool force = false) {
        if (fstypes_cache != null && !force) return fstypes_cache;
        var set = new Gee.HashSet<string>();
        string data;
        try { FileUtils.get_contents("/proc/filesystems", out data); } catch (Error e) { return set; }
        foreach (unowned string line in data.split("\n")) {
            if (line.strip() == "" || line.has_prefix("nodev")) continue;
            set.add(line.strip());
        }
        set.add("zfs"); // psutil special-cases zfs too
        fstypes_cache = set;
        return set;
    }

    private Gee.HashSet<string>? known_virtual = null; // types confirmed "nodev"


    public Gee.ArrayList<Partition> partitions() {
        var list = new Gee.ArrayList<Partition>();
        var fstypes = physical_fstypes();
        if (known_virtual == null) known_virtual = new Gee.HashSet<string>();
        string data;
        try { FileUtils.get_contents("/proc/self/mounts", out data); } catch (Error e) { return list; }
        foreach (unowned string line in data.split("\n")) {
            string[] f = line.split(" ");
            if (f.length < 3 || f[0] == "" || f[0] == "none") continue;
            if (!fstypes.contains(f[2])) {
                if (known_virtual.contains(f[2])) continue;
                fstypes = physical_fstypes(true);        // new type: refresh the list once
                if (!fstypes.contains(f[2])) { known_virtual.add(f[2]); continue; }
            }
            Posix.statvfs st;
            string mp = unescape_mount(f[1]);
            if (Posix.statvfs_exec(mp, out st) != 0) continue;
            var p = new Partition();
            p.device = unescape_mount(f[0]);
            p.mountpoint = mp;
            p.fstype = f[2];
            uint64 frsize = st.f_frsize;
            p.total = (uint64) st.f_blocks * frsize;
            p.free = (uint64) st.f_bavail * frsize;
            p.used = ((uint64) st.f_blocks - (uint64) st.f_bfree) * frsize;
            uint64 denom = p.used + p.free;
            p.percent = denom > 0 ? (double) p.used / (double) denom * 100.0 : 0; // psutil's formula
            list.add(p);
        }
        return list;
    }

    /* One directory waiting to be walked: an open fd and the top-level
     * entry its bytes count toward. */
    private class Job {
        public int fd;
        public int top;
        public Job(int fd, int top) { this.fd = fd; this.top = top; }
    }

    /* Recursive disk usage under a mountpoint, like `du -x`: stays on the
     * mountpoint's device, never follows symlinks, counts allocated blocks
     * (what the disk actually spends, so sparse files and tiny files are
     * right) and each hard-linked file once.
     *
     * Several threads walk at once: the walk is syscall-bound (getdents +
     * fstatat per entry), and an SSD answers parallel requests nearly as
     * fast as one. Load balancing is idle-driven: a thread that meets a
     * subdirectory walks it itself, unless another thread is idle, in which
     * case it hands the subdirectory over. So a lopsided tree (one huge
     * /home) still keeps every thread busy, and the queue never holds more
     * than a few open fds. */
    private class Walker {
        public uint64[] sizes = {};       // per top-level entry, guarded by `mu`
        private uint64 root_dev;
        private Cancellable cancel;
        private Mutex mu = Mutex();
        private Cond wake = Cond();
        private Gee.ArrayList<Job> queue = new Gee.ArrayList<Job>();
        private int busy = 0;             // threads walking a job; guarded by `mu`
        private int idle = 0;             // read without the lock: a hint, not a count
        private GenericSet<string> linked = new GenericSet<string>(str_hash, str_equal);

        public Walker(uint64 root_dev, Cancellable cancel) {
            this.root_dev = root_dev;
            this.cancel = cancel;
        }

        public void add(Job j) {
            mu.lock();
            queue.add(j);
            wake.signal();
            mu.unlock();
        }

        public void run(int threads) {
            var pool = new Thread<void*>[threads - 1];
            for (int i = 0; i < pool.length; i++) pool[i] = new Thread<void*>("fs-walk", () => { work(); return null; });
            work();
            foreach (var t in pool) t.join();
        }

        private void work() {
            while (true) {
                mu.lock();
                AtomicInt.inc(ref idle);
                while (queue.size == 0 && busy > 0) wake.wait(mu);
                AtomicInt.add(ref idle, -1);
                if (queue.size == 0) {           // nothing queued, nobody walking: done
                    wake.broadcast();
                    mu.unlock();
                    return;
                }
                var job = queue.remove_at(queue.size - 1);
                busy++;
                mu.unlock();

                uint64 bytes = walk(job.fd, job.top);

                mu.lock();
                sizes[job.top] += bytes;
                busy--;
                if (busy == 0 && queue.size == 0) wake.broadcast();
                mu.unlock();
            }
        }

        /* Bytes under an open directory (takes ownership of fd). */
        private uint64 walk(int fd, int top) {
            Posix.Dir? dir = Posix.fdopendir(fd);
            if (dir == null) { Posix.close(fd); return 0; }
            int dfd = Posix.dirfd(dir);
            uint64 total = 0;
            unowned Posix.DirEnt? ent;
            while ((ent = Posix.readdir(dir)) != null) {
                if (cancel.is_cancelled()) break;
                unowned string name = (string) ent.d_name;
                if (name == "." || name == ".." || (uchar) ent.d_type == DT_LNK) continue;
                Posix.Stat st;
                if (c_fstatat(dfd, name, out st, C_AT_SYMLINK_NOFOLLOW) != 0) continue;
                if ((uint64) st.st_dev != root_dev || Posix.S_ISLNK(st.st_mode)) continue;
                if (Posix.S_ISDIR(st.st_mode)) {
                    total += usage(st);
                    int child = c_openat(dfd, name, Posix.O_RDONLY | C_O_DIRECTORY | C_O_NOFOLLOW | C_O_CLOEXEC);
                    if (child < 0) continue;
                    if (AtomicInt.get(ref idle) > 0) add(new Job(child, top));   // someone's free: share
                    else total += walk(child, top);
                } else if ((uint64) st.st_nlink <= 1 || first_link(st)) {
                    total += usage(st);
                }
            }
            return total;   // closedir() runs when `dir` goes out of scope
        }

        public bool first_link(Posix.Stat st) {
            string key = "%llx:%llx".printf((uint64) st.st_dev, (uint64) st.st_ino);
            mu.lock();
            bool first = !linked.contains(key);
            if (first) linked.add(key);
            mu.unlock();
            return first;
        }
    }

    /* Allocated bytes (st_blocks is in 512-byte units on Linux). */
    private uint64 usage(Posix.Stat st) {
        return (uint64) st.st_blocks * 512;
    }

    /* One level deep: each direct child of `mountpoint` with its recursive
     * disk usage. Returns null if the mountpoint can't be read at all. */
    public Gee.ArrayList<ScanEntry>? scan(string mountpoint, Cancellable cancel) {
        Posix.Stat root;
        if (Posix.stat(mountpoint, out root) != 0) return null;
        uint64 root_dev = (uint64) root.st_dev;
        int fd = c_openat(Posix.AT_FDCWD, mountpoint, Posix.O_RDONLY | C_O_DIRECTORY | C_O_CLOEXEC);
        if (fd < 0) return null;
        Posix.Dir? dir = Posix.fdopendir(fd);
        if (dir == null) { Posix.close(fd); return null; }
        // the top level first: names, files' sizes, and one job per folder
        var names = new Gee.ArrayList<string>();
        var dirs = new Gee.ArrayList<bool>();
        var own = new Gee.ArrayList<uint64?>();
        var jobs = new Gee.ArrayList<Job>();
        var walker = new Walker(root_dev, cancel);
        unowned Posix.DirEnt? ent;
        while ((ent = Posix.readdir(dir)) != null) {
            if (cancel.is_cancelled()) break;
            string name = (string) ent.d_name;
            if (name == "." || name == "..") continue;
            Posix.Stat st;
            if (c_fstatat(Posix.dirfd(dir), name, out st, C_AT_SYMLINK_NOFOLLOW) != 0) continue;
            if (Posix.S_ISLNK(st.st_mode) || (uint64) st.st_dev != root_dev) continue;
            bool is_dir = Posix.S_ISDIR(st.st_mode);
            if (is_dir) {
                int child = c_openat(Posix.dirfd(dir), name, Posix.O_RDONLY | C_O_DIRECTORY | C_O_NOFOLLOW | C_O_CLOEXEC);
                if (child >= 0) jobs.add(new Job(child, names.size));
            } else if ((uint64) st.st_nlink > 1 && !walker.first_link(st)) {
                continue;
            }
            names.add(name);
            dirs.add(is_dir);
            own.add(usage(st));
        }
        walker.sizes = new uint64[names.size];
        foreach (var j in jobs) walker.add(j);
        walker.run(((int) get_num_processors()).clamp(1, 8));

        var entries = new Gee.ArrayList<ScanEntry>();
        for (int i = 0; i < names.size; i++) {
            uint64 size = own[i] + walker.sizes[i];
            if (size > 0) entries.add(new ScanEntry(names[i], size, dirs[i]));
        }
        return entries;
    }
}
