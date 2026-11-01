import AppKit
import LabelKit
import PeelGoodCore

/// Zebras on the network and USB: the scan when the app starts and its offer to add what it finds,
/// plugging one in, adding one by address, and moving a calibration from Peel Good onto the printer itself.
@MainActor
enum ZebraSetup {
    /// Looks for Zebras in the background (Settings > General can turn it off) and offers each new one.
    static func scanAtLaunch(store: Store) {
        Zebra.watchUSB { Task { @MainActor in usbChanged(store: store) } }
        guard store.scanForZebras else { return }
        let settings = store.settings
        Task {
            await scanUSB(store: store)
            let found = await Task.detached(priority: .utility) { settings.scanZebras() }.value
            Log.info(.app, "Zebra scan: \(found.count) found\(found.isEmpty ? "" : " at " + found.map(\.found.host).joined(separator: ", "))")
            store.refresh()
            for candidate in found where candidate.isNew { await offer(candidate, store: store) }
        }
    }

    /// A Zebra was plugged in or unplugged. It takes a moment to answer after it appears.
    private static func usbChanged(store: Store) {
        store.refresh()
        guard store.scanForZebras else { return }
        Task {
            try? await Task.sleep(for: .seconds(1))
            await scanUSB(store: store)
        }
    }

    private static var offeringUSB: Set<String> = []

    private static func scanUSB(store: Store) async {
        let settings = store.settings
        let found = await Task.detached(priority: .utility) { settings.scanUSB() }.value
        store.refresh()
        for candidate in found where !candidate.isIgnored && offeringUSB.insert(candidate.printer.id).inserted {
            await offer(candidate, store: store)
            offeringUSB.remove(candidate.printer.id)
        }
    }

    /// "Found Zebra GX420t on USB": Add, Not Now, or Ignore This Printer.
    private static func offer(_ candidate: USBCandidate, store: Store) async {
        let alert = NSAlert()
        alert.messageText = "Found \(candidate.profile.displayName) on USB"
        alert.informativeText = "Add it to Peel Good Inc. to print labels on it. You can turn off this search in Settings › General."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Ignore This Printer")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            store.addZebra(candidate.profile)
            Log.notice(.app, "added Zebra \(candidate.profile.product) \(candidate.profile.serial) on USB")
        case .alertThirdButtonReturn:
            store.ignoreZebra(candidate.printer.id)
        default:
            break
        }
    }

    /// "Found Zebra GX420t at 192.168.1.216": Add, Not Now, or Ignore This Printer.
    static func offer(_ candidate: ZebraCandidate, store: Store) async {
        let found = candidate.found
        let alert = NSAlert()
        alert.messageText = "Found \(candidate.product == nil ? "a Zebra printer" : candidate.displayName) at \(found.host)"
        alert.informativeText = "Add it to Peel Good Inc. to print labels on it. You can turn off this search in Settings › General."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Ignore This Printer")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do {
                try await add(host: found.host, discoveryID: found.serial, store: store)
            } catch {
                NSAlert(error: error).runModal()
            }
        case .alertThirdButtonReturn:
            store.ignoreZebra(found.serial)
        default:
            break
        }
    }

    /// Asks the printer what it is and remembers it.
    @discardableResult
    static func add(host: String, discoveryID: String? = nil, store: Store) async throws -> PrinterInfo {
        let host = host.trimmingCharacters(in: .whitespaces)
        let profile = try await Task.detached { try Zebra.describe(.network(host), discoveryID: discoveryID).profile }.value
        store.addZebra(profile)
        Log.notice(.app, "added Zebra \(profile.product) \(profile.serial) at \(host)")
        return profile.printer()
    }

    /// Moves Peel Good's offset for this printer into its own LEFT POSITION and LABEL TOP (saved with
    /// ^JUS), then clears Peel Good's, so every app prints in the calibrated place.
    static func moveCalibrationToPrinter(_ printer: PrinterInfo, store: Store) {
        guard let link = printer.zebraLink, let dpi = printer.dpi else { return }
        let nudge = store.nudge(for: printer)
        let dx = Int((Double(nudge.x) / 25.4 * dpi).rounded()), dy = Int((Double(nudge.y) / 25.4 * dpi).rounded())
        guard dx != 0 || dy != 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Move the offset to \(printer.displayName)?"
        alert.informativeText = "The printer saves it in its own settings, so labels from every app on every Mac move by "
            + String(format: "%.1f mm across and %.1f mm down. Peel Good's offset goes back to zero.", nudge.x, nudge.y)
        alert.addButton(withTitle: "Move to Printer")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                let result = try await Task.detached { try Zebra.moveCalibration(link, dx: dx, dy: dy) }.value
                store.setNudge(.zero, for: printer)
                Log.notice(.app, "moved calibration (\(dx), \(dy)) dots to \(printer.name): LEFT POSITION \(result.leftPosition), LABEL TOP \(result.labelTop)")
            } catch {
                Log.error(.app, "couldn't move calibration to \(printer.name): \(error)")
                NSAlert(error: error).runModal()
            }
        }
    }
}
