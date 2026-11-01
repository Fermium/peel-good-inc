import Foundation
import LabelKit

// Zebras on the network or USB aren't CUPS queues: the app remembers them itself (by serial number,
// so one printer reached two ways is one printer) and lists them with the Mac's printers, the same
// way for the app, the API and the command line.

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

    /// Adds a Zebra, or updates the one with the same serial (a new address, or a second connection).
    public func remember(_ zebra: Zebra.Profile) {
        var list = zebraPrinters
        if let i = list.firstIndex(where: { $0.serial == zebra.serial }) {
            var merged = zebra
            merged.host = zebra.host ?? list[i].host
            merged.usbSerial = zebra.usbSerial ?? list[i].usbSerial
            merged.prefers = zebra.prefers ?? list[i].prefers
            merged.discoveryID = zebra.discoveryID ?? list[i].discoveryID
            list[i] = merged
        } else {
            list.append(zebra)
        }
        zebraPrinters = list
    }

    /// The remembered Zebra with this printer name.
    public func zebra(named name: String) -> Zebra.Profile? {
        zebraPrinters.first { $0.printerName == name }
    }

    public func forgetZebra(named name: String) {
        zebraPrinters = zebraPrinters.filter { $0.printerName != name }
    }

    /// Discovery IDs and USB ids of Zebras the user said not to offer again.
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
            guard let link = try? Zebra.route(zebras[i].reachableLinks), let s = try? Zebra.status(link, timeout: timeout) else { return }
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
        final class Box: @unchecked Sendable { var products: [Int: String] = [:]; var serials: [Int: String] = [:]; let lock = NSLock() }
        let box = Box()
        let hosts = candidates.map(\.found.host), known = candidates.map(\.isKnown)
        DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
            let link = Zebra.Link.network(hosts[i])
            guard let product = try? Zebra.identify(link, timeout: identifyTimeout).product else { return }
            let serial = known[i] ? nil : (try? Zebra.getvar(link, "device.unique_id", timeout: identifyTimeout)) ?? nil
            box.lock.withLock { box.products[i] = product; box.serials[i] = serial }
        }
        for (i, product) in box.products { candidates[i].product = product }
        // A printer already remembered from USB, now also seen on the network: the same printer.
        for (i, serial) in box.serials {
            guard var zebra = zebraPrinters.first(where: { $0.serial == serial }) else { continue }
            zebra.host = hosts[i]
            zebra.discoveryID = candidates[i].found.serial
            remember(zebra)
            candidates[i].isKnown = true
        }
        return candidates
    }

    /// Looks at the Zebras attached over USB. One that's already remembered, from either connection,
    /// gets its USB connection added. Returns the new ones that take ZPL, to offer. Ones the user said
    /// not to offer aren't even asked, unless `includingIgnored`.
    public func scanUSB(includingIgnored: Bool = false) -> [USBCandidate] {
        var new: [USBCandidate] = []
        for id in Zebra.usbPrinters() where !zebraPrinters.contains(where: { $0.usbSerial == id }) {
            if !includingIgnored, ignoredZebras.contains(id) { continue }
            guard (try? Zebra.usbSpeaksZPL(id: id)) == true,
                  let profile = try? Zebra.describe(.usb(id: id)).profile else { continue }
            if zebraPrinters.contains(where: { $0.serial == profile.serial }) {
                remember(profile)
            } else {
                new.append(USBCandidate(id: id, profile: profile))
            }
        }
        return new
    }
}

/// A Zebra on USB that isn't remembered yet.
public struct USBCandidate: Sendable, Equatable {
    public var id: String
    public var profile: Zebra.Profile
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
