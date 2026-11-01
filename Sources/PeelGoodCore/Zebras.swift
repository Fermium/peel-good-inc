import Foundation
import LabelKit

// Zebras on the network aren't CUPS queues: the app remembers them itself (by serial number) and
// lists them with the Mac's printers, the same way for the app, the API and the command line.

extension AppSettings {
    /// Zebras added in the app, newest last.
    public var zebraPrinters: [Zebra.Profile] {
        get {
            guard let json = string(SettingsKey.zebraPrinters.rawValue) else { return [] }
            return (try? JSONDecoder().decode([Zebra.Profile].self, from: Data(json.utf8))) ?? []
        }
        nonmutating set {
            let json = (try? JSONEncoder().encode(newValue)).map { String(decoding: $0, as: UTF8.self) }
            set(newValue.isEmpty ? nil : json, SettingsKey.zebraPrinters.rawValue)
        }
    }

    /// Adds a Zebra, or updates the one with the same serial (a new address, say).
    public func remember(_ zebra: Zebra.Profile) {
        var list = zebraPrinters
        if let i = list.firstIndex(where: { $0.serial == zebra.serial }) { list[i] = zebra } else { list.append(zebra) }
        zebraPrinters = list
    }

    public func forgetZebra(named name: String) {
        zebraPrinters = zebraPrinters.filter { $0.printerName != name }
    }

    /// Discovery IDs of Zebras the user said not to offer again.
    public var ignoredZebras: [String] {
        get { strings(SettingsKey.ignoredZebras.rawValue) ?? [] }
        nonmutating set { set(newValue.isEmpty ? nil : newValue, SettingsKey.ignoredZebras.rawValue) }
    }

    /// The "Peel Good Inc." printer every app can print to (Settings > General).
    public var virtualPrinter: Bool {
        get { bool(SettingsKey.virtualPrinter.rawValue) ?? false }
        nonmutating set { set(newValue, SettingsKey.virtualPrinter.rawValue) }
    }

    /// Look for Zebras on the network when the app starts, and offer to add new ones.
    public var scanForZebras: Bool {
        get { bool(SettingsKey.scanForZebras.rawValue) ?? true }
        nonmutating set { set(newValue, SettingsKey.scanForZebras.rawValue) }
    }

    /// The Mac's printers and the remembered Zebras, with each Zebra's status when given.
    public func printers(cups: [PrinterInfo] = Printers.all(), zebraStatus: [String: Zebra.Status] = [:]) -> [PrinterInfo] {
        cups + zebraPrinters.map { $0.printer(status: zebraStatus[$0.serial]) }
    }

    /// Each remembered Zebra's status, asked in parallel with a short timeout. Missing when it doesn't answer.
    public func zebraStatus(timeout: TimeInterval = 1.5) -> [String: Zebra.Status] {
        let zebras = zebraPrinters
        final class Box: @unchecked Sendable { var values: [String: Zebra.Status] = [:]; let lock = NSLock() }
        let box = Box()
        DispatchQueue.concurrentPerform(iterations: zebras.count) { i in
            guard let s = try? Zebra.status(zebras[i].host, timeout: timeout) else { return }
            box.lock.withLock { box.values[zebras[i].serial] = s }
        }
        return box.values
    }

    /// The remembered Zebra a scan found: same print server, else same address.
    public func knownZebra(for found: Zebra.Found) -> Zebra.Profile? {
        zebraPrinters.first { $0.discoveryID == found.serial } ?? zebraPrinters.first { $0.host == found.host }
    }

    /// Each Zebra a scan found, recognised against the remembered ones. A remembered one found at a new
    /// address is moved there.
    public func reconcile(_ found: [Zebra.Found]) -> [ZebraCandidate] {
        var list = zebraPrinters
        let candidates = found.map { f in
            let known = knownZebra(for: f)
            if let known, known.host != f.host, let i = list.firstIndex(of: known) { list[i].host = f.host }
            return ZebraCandidate(found: f, product: known?.product, isKnown: known != nil, isIgnored: ignoredZebras.contains(f.serial))
        }
        if list != zebraPrinters { zebraPrinters = list }
        return candidates
    }

    /// Looks for Zebras on the network (UDP 4201) and asks each new one its model: what the scan at
    /// launch offers and what Settings › Printers › Add Zebra lists.
    public func scanZebras(timeout: TimeInterval = 3, identifyTimeout: TimeInterval = 2) -> [ZebraCandidate] {
        var candidates = reconcile(Zebra.discover(timeout: timeout))
        final class Box: @unchecked Sendable { var products: [Int: String] = [:]; let lock = NSLock() }
        let box = Box()
        let hosts = candidates.map(\.found.host)
        DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
            guard let product = try? Zebra.identify(hosts[i], timeout: identifyTimeout).product else { return }
            box.lock.withLock { box.products[i] = product }
        }
        for (i, product) in box.products { candidates[i].product = product }
        return candidates
    }
}

/// A Zebra a scan found.
public struct ZebraCandidate: Sendable, Equatable {
    public var found: Zebra.Found
    /// "GX420t", when it answered.
    public var product: String?
    /// Already added to Peel Good.
    public var isKnown: Bool
    /// The user said not to offer it again.
    public var isIgnored: Bool

    /// Not added and not ignored: worth offering.
    public var isNew: Bool { !isKnown && !isIgnored }
    public var displayName: String { product.map(Zebra.displayName) ?? found.systemName }
}
