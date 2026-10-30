import AppKit
import PeelGoodCore
import PeelGoodShared

MainActor.assumeIsolated {
    let copiedDefaults = DefaultsMigration.migrateAppDefaults()   // before anything reads settings
    AppPaths.migrate()   // before anything reads or writes the data folders
    if let copiedDefaults { Log.notice(.app, copiedDefaults) }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
