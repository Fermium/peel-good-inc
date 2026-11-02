import AppKit
import XCTest
@testable import PeelGoodApp

@MainActor
final class ModalAlertTests: XCTestCase {
    /// A modal loop on an offscreen window: the same loop an alert runs, with nothing on screen.
    private func modal() {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: false)
        RunLoop.main.add(Timer(timeInterval: 1, repeats: false) { _ in NSApp.stopModal() }, forMode: .common)
        NSApp.runModal(for: window)
        window.orderOut(nil)
    }

    func testTheMainActorKeepsWorkingWhileAnAlertWaits() async throws {
        _ = NSApplication.shared
        var ticks = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                ticks += 1
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { ticker.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        let before = ticks
        await ModalAlert.run { self.modal() }
        XCTAssertGreaterThan(ticks - before, 5, "remote sources run on the main actor, and an open alert must not stop them")
    }
}
