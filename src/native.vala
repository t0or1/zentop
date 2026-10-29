/* native.vala -- raw syscall bindings not covered by Vala's Posix vapi
 * (sched_setaffinity/sched_getaffinity are GNU extensions, not POSIX
 * standard, so they're not in the vapi). Tested standalone before use;
 * see test_syscalls.vala. Compile with --Xcc=-D_GNU_SOURCE. */

[CCode (cheader_filename = "sched.h")]
private extern int sched_setaffinity(Posix.pid_t pid, size_t cpusetsize, void* mask);

[CCode (cheader_filename = "sched.h")]
private extern int sched_getaffinity(Posix.pid_t pid, size_t cpusetsize, void* mask);

namespace Native {
    const int CPU_WORDS = 16; // glibc default cpu_set_t = 1024 bits / 64-bit words

    public int[] get_affinity(Posix.pid_t pid, int core_count) {
        uint64[] mask = new uint64[CPU_WORDS];
        int rc = sched_getaffinity(pid, CPU_WORDS * 8, (void*) mask);
        if (rc != 0) return new int[0];
        var result = new Gee.ArrayList<int>();
        for (int i = 0; i < core_count; i++) {
            if ((mask[i / 64] & (1UL << (i % 64))) != 0) result.add(i);
        }
        return result.to_array();
    }

    public bool set_affinity(Posix.pid_t pid, int[] cores) {
        uint64[] mask = new uint64[CPU_WORDS];
        foreach (var c in cores) mask[c / 64] |= (1UL << (c % 64));
        return sched_setaffinity(pid, CPU_WORDS * 8, (void*) mask) == 0;
    }

    public string? get_exe_path(int pid) {
        uint8[] buf = new uint8[4096];
        ssize_t n = Posix.readlink("/proc/%d/exe".printf(pid), (char[]) buf);
        if (n <= 0) return null;
        return (string) buf[0:n];
    }
}
