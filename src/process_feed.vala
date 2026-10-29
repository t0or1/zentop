/* process_feed.vala -- one long-lived worker thread runs the /proc scan;
 * results come back on the GTK main loop through `rows_ready`. Requests
 * made while a scan is still running are dropped, so a slow tick can
 * never pile up work. Processes and Pie Graph share this one scan. */

public class ProcessFeed : Object {
    public signal void rows_ready(Gee.ArrayList<ProcessRow> rows);

    private class Request { public bool stop; }

    private ProcessCache cache = new ProcessCache();
    private AsyncQueue<Request> queue = new AsyncQueue<Request>();
    private Thread<void*>? worker = null;
    private bool in_flight = false;

    public void request() {
        if (in_flight) return;
        in_flight = true;
        if (worker == null) worker = new Thread<void*>("proc-scan", run);
        queue.push(new Request());
    }

    private void* run() {
        while (true) {
            var req = queue.pop();
            if (req.stop) break;
            var rows = cache.refresh();
            Idle.add(() => {
                in_flight = false;
                rows_ready(rows);
                return false;
            });
        }
        return null;
    }

    public void shutdown() {
        if (worker == null) return;
        var r = new Request();
        r.stop = true;
        queue.push(r);
        worker.join();
        worker = null;
    }
}
