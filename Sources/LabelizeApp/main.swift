import AppKit

MainActor.assumeIsolated {
    AppPaths.migrate()   // before anything reads or writes the data folders
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
