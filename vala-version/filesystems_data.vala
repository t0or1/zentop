/* filesystems_data.vala -- mounted partitions, their usage, and the
 * one-level disk-usage scan behind the treemap. No GTK in here: the scan
 * runs on a worker thread, walking with openat/fstatat so no path string
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
    private Gee.HashSet<string> physical_fstypes() {
        var set = new Gee.HashSet<string>();
        string data;
        try { FileUtils.get_contents("/proc/filesystems", out data); } catch (Error e) { return set; }
        foreach (unowned string line in data.split("\n")) {
            if (line.strip() == "" || line.has_prefix("nodev")) continue;
            set.add(line.strip());
        }
        set.add("zfs"); // psutil special-cases zfs too
        return set;
    }

    public Gee.ArrayList<Partition> partitions() {
        var list = new Gee.ArrayList<Partition>();
        var fstypes = physical_fstypes();
        string data;
        try { FileUtils.get_contents("/proc/self/mounts", out data); } catch (Error e) { return list; }
        foreach (unowned string line in data.split("\n")) {
            string[] f = line.split(" ");
            if (f.length < 3 || f[0] == "" || f[0] == "none") continue;
            if (!fstypes.contains(f[2])) continue;
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

    /* Recursive size under an open directory fd, never leaving device
     * `root_dev` (like du -x, so a scan of "/" skips /proc, /sys and a
     * separate /home) and never following symlinks. Takes ownership of fd. */
    private uint64 dir_size(int fd, uint64 root_dev, Cancellable cancel) {
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
                int child = c_openat(dfd, name, Posix.O_RDONLY | C_O_DIRECTORY | C_O_NOFOLLOW | C_O_CLOEXEC);
                if (child >= 0) total += dir_size(child, root_dev, cancel);
            } else {
                total += (uint64) st.st_size;
            }
        }
        return total; // closedir() runs when `dir` goes out of scope
    }

    /* One level deep: each direct child of `mountpoint` with its recursive
     * size. Returns null if the mountpoint can't be read at all. */
    public Gee.ArrayList<ScanEntry>? scan(string mountpoint, Cancellable cancel) {
        Posix.Stat root;
        if (Posix.stat(mountpoint, out root) != 0) return null;
        uint64 root_dev = (uint64) root.st_dev;
        int fd = c_openat(Posix.AT_FDCWD, mountpoint, Posix.O_RDONLY | C_O_DIRECTORY | C_O_CLOEXEC);
        if (fd < 0) return null;
        Posix.Dir? dir = Posix.fdopendir(fd);
        if (dir == null) { Posix.close(fd); return null; }
        var entries = new Gee.ArrayList<ScanEntry>();
        unowned Posix.DirEnt? ent;
        while ((ent = Posix.readdir(dir)) != null) {
            if (cancel.is_cancelled()) break;
            string name = (string) ent.d_name;
            if (name == "." || name == "..") continue;
            Posix.Stat st;
            if (c_fstatat(Posix.dirfd(dir), name, out st, C_AT_SYMLINK_NOFOLLOW) != 0) continue;
            if (Posix.S_ISLNK(st.st_mode) || (uint64) st.st_dev != root_dev) continue;
            bool is_dir = Posix.S_ISDIR(st.st_mode);
            uint64 size;
            if (is_dir) {
                int child = c_openat(Posix.dirfd(dir), name, Posix.O_RDONLY | C_O_DIRECTORY | C_O_NOFOLLOW | C_O_CLOEXEC);
                size = child >= 0 ? dir_size(child, root_dev, cancel) : 0;
            } else {
                size = (uint64) st.st_size;
            }
            if (size > 0) entries.add(new ScanEntry(name, size, is_dir));
        }
        return entries;
    }
}
