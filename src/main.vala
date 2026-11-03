/* main.vala -- entry point. Module map (all in src/):
 *   data:  proc_reader  process_scan  resources_data  filesystems_data
 *          sensors_data  native  config
 *   look:  theme  graphs  widgets  table_text  util
 *   tabs:  tab_processes (+ process_actions, process_feed)  tab_resources
 *          (+ tab_sensors)
 *          tab_pie  tab_filesystems  tab_themes
 *   shell: window */

int main(string[] args) {
    if (args.length > 1 && (args[1] == "--version" || args[1] == "-v")) {
        print("zentop %s\n", ZENTOP_VERSION);
        return 0;
    }
    register_app_fonts(); // before any widget asks for a font
    raise_fd_limit();     // the process scan keeps one fd per process
    var app = new Gtk.Application("com.zentop.app", ApplicationFlags.DEFAULT_FLAGS);
    app.activate.connect(() => {
        var win = app.active_window ?? new ZentopWindow(app);
        win.present();
    });
    return app.run(args);
}
