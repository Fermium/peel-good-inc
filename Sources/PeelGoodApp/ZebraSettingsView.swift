import AppKit
import LabelKit
import SwiftUI

/// Settings › Printers › a Zebra: the printer's own configuration (darkness, speed, media, mode).
/// It applies to every app's labels, so edits wait for Save to Printer, which shows what changes and
/// saves it on the printer (^JUS), like Move to Printer does for the offset.
struct ZebraSettingsSection: View {
    let printer: PrinterInfo
    let host: String
    @State private var current: Zebra.Config?
    @State private var edited = Zebra.Config()
    @State private var loading = true
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        Section {
            if let current {
                LabeledContent("Darkness") {
                    NumberField(value: number(\.darkness, current.darkness ?? 10), range: range(Zebra.Config.darknessRange))
                }
                LabeledContent("Print speed") {
                    NumberField(value: number(\.speed, current.speed ?? 4), range: range(Zebra.Config.speedRange), unit: "in/s")
                }
                picker("Print method", \.method, Zebra.PrintMethod.allCases, \.title)
                picker("Media", \.tracking, Zebra.Tracking.allCases, \.title)
                picker("Print mode", \.mode, Zebra.PrintMode.allCases, \.title)
                LabeledContent("Tear-off position") { tearOffField(current) }
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Text(message ?? "These settings are kept on the printer and apply to labels from every app.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save to Printer…") { review(current) }.disabled(edited == current || busy)
                }
            } else {
                HStack {
                    Text(loading ? "Reading the printer's settings…" : message ?? "The printer didn't answer.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if loading { ProgressView().controlSize(.small) } else { Button("Try Again") { load() } }
                }
            }
            HStack {
                Spacer()
                Button("Calibrate…") { calibrate() }
                    .help("Feeds a few labels to measure them and set the sensors (~JC)")
                Button("Print Configuration") { run("Printed the configuration label.") { try Zebra.printConfigurationLabel($0) } }
                    .help("Prints the printer's own configuration label (~WC)")
            }
            .disabled(busy)
        } header: {
            Text("Printer Settings")
        }
        // Read once per printer, not on every appearance: a reload would throw away unsaved edits.
        .task(id: host) { load() }
    }

    // MARK: Rows

    /// In mm like the offsets; the printer counts dot rows.
    private func tearOffField(_ current: Zebra.Config) -> some View {
        let dotsPerMM = (printer.dpi ?? 203.2) / 25.4
        let r = Zebra.Config.tearOffRange
        return NumberField(value: Binding(
            get: { Double(edited.tearOff ?? current.tearOff ?? 0) / dotsPerMM },
            set: { edited.tearOff = Int(($0 * dotsPerMM).rounded()) }
        ), range: Double(r.lowerBound) / dotsPerMM...Double(r.upperBound) / dotsPerMM, step: 0.5,
           // Enough decimals that every dot has its own value (8 dots/mm: 0.125 mm steps).
           decimals: dotsPerMM > 10 ? 2 : 1, unit: "mm")
    }

    private func number(_ key: WritableKeyPath<Zebra.Config, Int?>, _ fallback: Int) -> Binding<Double> {
        Binding(get: { Double(edited[keyPath: key] ?? fallback) }, set: { edited[keyPath: key] = Int($0.rounded()) })
    }

    private func range(_ r: ClosedRange<Int>) -> ClosedRange<Double> { Double(r.lowerBound)...Double(r.upperBound) }

    private func picker<T: Hashable>(_ title: String, _ key: WritableKeyPath<Zebra.Config, T?>, _ all: [T], _ name: KeyPath<T, String>) -> some View {
        Picker(title, selection: Binding(get: { edited[keyPath: key] }, set: { edited[keyPath: key] = $0 })) {
            if edited[keyPath: key] == nil { Text("Unknown").tag(T?.none) }
            ForEach(all, id: \.self) { Text($0[keyPath: name]).tag(T?.some($0)) }
        }
    }

    // MARK: Printer

    private func load() {
        guard !busy else { return }
        loading = true
        message = nil
        let host = host
        Task {
            do {
                let read = try await Task.detached { try Zebra.config(host)?.config }.value
                // Keep edits made while reading; otherwise show what the printer has.
                if let old = current, edited != old {} else if let read { edited = read }
                current = read
                if read == nil { message = "The printer can't answer right now (paused, open or busy)." }
            } catch {
                message = "\(error)"
            }
            loading = false
        }
    }

    /// What changes, then Save to Printer.
    private func review(_ current: Zebra.Config) {
        let changes = edited.changes(from: current)
        let alert = NSAlert()
        alert.messageText = "Save these settings on \(printer.displayName)?"
        var notes = changes.map { "• \($0)" }
        notes.append("")
        notes.append("The printer keeps them, so labels from every app on every Mac print with them.")
        if edited.tracking != current.tracking { notes.append("Calibrate the media afterwards so the printer finds the new labels.") }
        if edited.method == .thermalTransfer && current.method == .directThermal { notes.append("Thermal transfer needs a ribbon fitted.") }
        if edited.mode != current.mode, edited.mode != .tearOff { notes.append("Only pick a mode your printer has the hardware for.") }
        alert.informativeText = notes.joined(separator: "\n")
        alert.addButton(withTitle: "Save to Printer")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        save(over: current)
    }

    private func save(over old: Zebra.Config) {
        let wanted = edited, host = host
        busy = true
        Task {
            do {
                let after = try await Task.detached { try Zebra.apply(wanted, over: old, save: true, to: host) }.value
                Log.notice(.app, "\(printer.name): saved \(wanted.changes(from: old).joined(separator: "; "))")
                if let after {
                    current = after
                    edited = after
                    let kept = wanted.changes(from: after)
                    message = kept.isEmpty ? "Saved on the printer." : "The printer didn't take everything: \(kept.joined(separator: "; "))"
                } else {
                    message = "Sent. The printer didn't answer afterwards."
                }
                busy = false
                if wanted.tracking != old.tracking { calibrate() }
            } catch {
                message = "\(error)"
                busy = false
            }
        }
    }

    private func calibrate() {
        let alert = NSAlert()
        alert.messageText = "Calibrate \(printer.displayName)?"
        alert.informativeText = "The printer feeds a few labels to measure them. Wait for it to stop before printing."
        alert.addButton(withTitle: "Calibrate")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run("Calibrating. Wait for the printer to stop.") { try Zebra.calibrate($0) }
    }

    private func run(_ done: String, _ action: @escaping @Sendable (String) throws -> Void) {
        let host = host
        busy = true
        Task {
            do {
                try await Task.detached { try action(host) }.value
                message = done
            } catch {
                message = "\(error)"
            }
            busy = false
        }
    }
}
