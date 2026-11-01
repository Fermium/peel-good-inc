import Foundation
import IOKit
import IOKit.pwr_mgt
import IOUSBHost

// Zebras on USB, through IOUSBHost: no driver, no root and no entitlement outside the sandbox. They
// are USB printer class 7/1/2 with a bulk pipe each way, and answer exactly as they do on port 9100.
// Differences from the network that shape this file, checked on a GX420t (V56.17.17Z):
// - Unread replies stay on the printer and mix into the next answer, so each query drains first.
// - Only one client can open the printer. A second one gets a generic error, not "busy", so opening
//   retries. CUPS waits for us and retries by itself.
// - A blocked write stops everything, tilde commands included: USB has no separate status channel.

extension Zebra {
    /// A Zebra attached over USB.
    public struct USBPrinter: Sendable, Equatable {
        /// What `Link.usb` names it by: its USB serial number, or its port when that can't tell it apart.
        public var id: String
        /// "ZTC GX420t".
        public var model: String
    }

    private static let zebraVendor = 0x0a5f

    private static func printerInterfaces() -> CFMutableDictionary {
        IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: nil, productID: nil, bcdDevice: nil, interfaceNumber: nil, configurationValue: nil,
            interfaceClass: 7, interfaceSubclass: 1, interfaceProtocol: 2, speed: nil, productIDArray: nil
        ).takeRetainedValue()
    }

    private static func property<T>(_ service: io_service_t, _ name: String) -> T? {
        IORegistryEntrySearchCFProperty(service, kIOServicePlane, name as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? T
    }

    /// Each attached Zebra's printer interface. Asks IOKit only: nothing is opened, so a printer in
    /// use still shows up. The caller releases the services.
    private static func attached() -> [(printer: USBPrinter, service: io_service_t)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, printerInterfaces(), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [(serial: String, port: String, model: String, service: io_service_t)] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            let vendor: Int? = property(service, "idVendor")
            guard vendor == zebraVendor else { IOObjectRelease(service); continue }
            let product: Int = property(service, "idProduct") ?? 0, location: Int = property(service, "locationID") ?? 0
            found.append((
                serial: ((property(service, "USB Serial Number") as String?) ?? "").trimmingCharacters(in: .whitespaces),
                port: String(format: "usb:%04x:%04x:%08x", zebraVendor, product, location),
                model: property(service, "USB Product Name") ?? "Zebra",
                service: service
            ))
        }
        return found.map { f in
            (USBPrinter(id: usableSerial(f.serial, model: f.model, among: found.map(\.serial)) ? f.serial : f.port, model: f.model), f.service)
        }
    }

    /// A USB serial can be blank, or the product family on printers set to share one ("ZT230"): Zebra
    /// documents that, so it only names a printer when it's unique and isn't the model.
    static func usableSerial(_ serial: String, model: String, among all: [String]) -> Bool {
        !serial.isEmpty && !model.localizedCaseInsensitiveContains(serial) && all.filter { $0 == serial }.count == 1
    }

    public static func usbPrinters() -> [USBPrinter] {
        attached().map { IOObjectRelease($0.service); return $0.printer }
    }

    /// The printer languages in an IEEE 1284 Device ID ("COMMAND SET:ZPL;" or "CMD:ZPL,EPL;").
    /// Zebras can pad values with spaces.
    static func commandSet(deviceID: String) -> [String] {
        for field in deviceID.split(separator: ";") {
            let parts = field.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, ["COMMAND SET", "CMD"].contains(parts[0].uppercased()) else { continue }
            return parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
        }
        return []
    }

    /// Whether this USB printer takes ZPL right now, so a printer set to EPL never gets a ZPL probe.
    /// A Zebra that names no language gets the benefit of the doubt, and `~HI` then has to answer.
    public static func usbSpeaksZPL(_ printer: USBPrinter) throws -> Bool {
        let languages = commandSet(deviceID: try USBPort.named(printer.id).deviceID())
        return languages.isEmpty || languages.contains("ZPL")
    }

    /// The connection to print on, so a printer unplugged from one is reached on the other. Nothing has
    /// been sent yet, so moving on is always safe. A USB printer that's attached is the answer even when
    /// it's busy: the job waits its turn in `holding` instead of going around it on the network. An
    /// address has to answer, unless it's the last choice. A printer that answers with a problem
    /// counts: `send` reports it.
    public static func route(_ links: [Link]) throws -> Link {
        let present = links.filter(\.isPresent)
        guard let last = present.last else { throw Failed(description: "the printer isn't connected over USB") }
        for link in present.dropLast() {
            if case .usb = link { return link }
            if (try? status(link, timeout: 2)) != nil { return link }
        }
        return last
    }

    /// Runs a whole print on one connection. On USB this keeps the printer open from the first byte
    /// until `body` returns: other apps wait, jobs from this app queue, and the Mac stays awake.
    public static func holding<T>(_ link: Link, _ body: (any Channel) throws -> T) throws -> T {
        guard case .usb(let id) = link else { return try body(link) }
        let port = USBPort.named(id)
        port.job.lock()
        defer { port.job.unlock() }
        // Another app's print may be going: a long job takes about a minute.
        try port.open(within: 60)
        defer { port.close() }
        var assertion: IOPMAssertionID = 0
        let awake = IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "Printing a label" as CFString, &assertion)
        defer { if awake == kIOReturnSuccess { IOPMAssertionRelease(assertion) } }
        // A job cut off earlier leaves half a format, which would swallow the start of this one.
        if let s = try? status(port), s.partialFormat { try? port.write(Data("~JX".utf8), timeout: 3) }
        return try body(port)
    }

    /// Calls `changed` on the main queue when a Zebra is plugged in or unplugged. Runs for the life of the app.
    public static func watchUSB(changed: @escaping @Sendable () -> Void) {
        final class Watch {
            let changed: @Sendable () -> Void
            init(_ changed: @escaping @Sendable () -> Void) { self.changed = changed }
        }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passRetained(Watch(changed)).toOpaque()
        let fired: IOServiceMatchingCallback = { context, iterator in
            var any = false
            while case let service = IOIteratorNext(iterator), service != 0 { any = true; IOObjectRelease(service) }
            if any { Unmanaged<Watch>.fromOpaque(context!).takeUnretainedValue().changed() }
        }
        for event in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            guard IOServiceAddMatchingNotification(port, event, printerInterfaces(), fired, context, &iterator) == KERN_SUCCESS else { continue }
            // Emptying the iterator arms it. What's already attached is the launch scan's job.
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
        }
    }

    /// One attached printer's connection, shared within the app so a print in progress and the status
    /// checks use the same open interface. It opens with its first user and closes with its last.
    final class USBPort: Channel, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var ports: [String: USBPort] = [:]

        static func named(_ id: String) -> USBPort {
            lock.withLock {
                if let port = ports[id] { return port }
                let port = USBPort(id: id)
                ports[id] = port
                return port
            }
        }

        let id: String
        let label = "USB printer"
        /// Held for a whole print.
        let job = NSLock()
        /// Held for each command. A write keeps it throughout, so nothing lands inside a format.
        private let transfer = NSLock()
        private let queue = DispatchQueue(label: "PeelGood.ZebraUSB")
        private var users = 0
        private var interface: IOUSBHostInterface?
        private var output: IOUSBHostPipe?
        private var input: IOUSBHostPipe?
        private var packetSize = 64

        private init(id: String) { self.id = id }

        func open(within timeout: TimeInterval) throws {
            transfer.lock()
            defer { transfer.unlock() }
            if users == 0 { try connect(within: timeout) }
            users += 1
        }

        func close() {
            transfer.lock()
            defer { transfer.unlock() }
            users -= 1
            if users == 0 { disconnect() }
        }

        private func connect(within timeout: TimeInterval) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let printers = attached()
                defer { printers.forEach { IOObjectRelease($0.service) } }
                guard let service = printers.first(where: { $0.printer.id == id })?.service else {
                    throw Failed(description: "the printer isn't connected over USB")
                }
                do {
                    let opened = try IOUSBHostInterface(__ioService: service, options: [], queue: queue, interestHandler: nil)
                    try attach(opened)
                    return
                } catch {
                    guard Date() < deadline else { throw Failed(description: "another app is using the USB printer") }
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
        }

        private func attach(_ opened: IOUSBHostInterface) throws {
            var outAddress: Int?, inAddress: Int?
            let configuration = opened.configurationDescriptor, descriptor = opened.interfaceDescriptor
            var next = IOUSBGetNextEndpointDescriptor(configuration, descriptor, nil)
            while let endpoint = next {
                let address = Int(endpoint.pointee.bEndpointAddress)
                // Bulk only; the descriptor says which, since layouts differ between models.
                if endpoint.pointee.bmAttributes & 3 == 2 {
                    if address & 0x80 != 0 { inAddress = address } else {
                        outAddress = address
                        packetSize = max(Int(endpoint.pointee.wMaxPacketSize) & 0x7FF, 1)
                    }
                }
                next = IOUSBGetNextEndpointDescriptor(configuration, descriptor, UnsafePointer(OpaquePointer(endpoint)))
            }
            guard let outAddress, let inAddress else {
                opened.destroy()
                throw Failed(description: "the USB printer has no way to answer")
            }
            do {
                output = try opened.copyPipe(withAddress: outAddress)
                input = try opened.copyPipe(withAddress: inAddress)
                interface = opened
            } catch {
                opened.destroy()
                throw error
            }
        }

        private func disconnect() {
            interface?.destroy()
            interface = nil
            output = nil
            input = nil
        }

        /// The IEEE 1284 Device ID (GET_DEVICE_ID).
        func deviceID() throws -> String {
            try open(within: 2)
            defer { close() }
            transfer.lock()
            defer { transfer.unlock() }
            guard let interface else { throw Failed(description: "the printer isn't connected over USB") }
            let buffer = NSMutableData(length: 1024)!
            var count = 0
            let request = IOUSBDeviceRequest(bmRequestType: 0xA1, bRequest: 0, wValue: 0, wIndex: 0, wLength: 1024)
            try interface.__send(request, data: buffer, bytesTransferred: &count, completionTimeout: 3)
            // The first two bytes are its length.
            return String(decoding: (buffer as Data).prefix(count).dropFirst(2), as: UTF8.self)
        }

        // MARK: Channel

        func query(_ command: String, timeout: TimeInterval, quiet: TimeInterval, done: ([UInt8]) -> Bool) throws -> String {
            transfer.lock()
            defer { transfer.unlock() }
            let reply = try ask(command, timeout: timeout, quiet: quiet, done: done)
            guard !reply.isEmpty else { throw Failed(description: "\(label) didn't answer. Its print head may be open, or it may be out of labels") }
            return String(decoding: reply, as: UTF8.self)
        }

        private func ask(_ command: String, timeout: TimeInterval, quiet: TimeInterval, done: ([UInt8]) -> Bool) throws -> [UInt8] {
            // An answer nobody read, from an earlier client or a command that replied late.
            var drained = 0
            while drained < 64, try !read(within: 0.03).isEmpty { drained += 1 }
            try send(Data(command.utf8))
            var reply: [UInt8] = []
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline, !done(reply) {
                let wait = reply.isEmpty ? deadline.timeIntervalSinceNow : min(quiet, deadline.timeIntervalSinceNow)
                guard wait > 0 else { break }
                let chunk = try read(within: wait)
                if chunk.isEmpty { break }
                reply += chunk
            }
            return reply
        }

        func write(_ job: Data, timeout: TimeInterval) throws {
            transfer.lock()
            defer { transfer.unlock() }
            var data = job
            // Ending on a packet boundary leaves it open whether the transfer has ended. Printers
            // ignore line ends between formats, so one more byte or two settles it.
            if data.count % packetSize == 0 { data.append(contentsOf: [0x0D, 0x0A]) }
            var sent = 0
            var lastProgress = Date()
            while sent < data.count {
                let chunk = NSMutableData(data: data.subdata(in: sent..<min(sent + Self.chunkSize, data.count)))
                let count: Int
                do {
                    count = try writeChunk(chunk)
                } catch {
                    throw Failed(description: "sending to \(label) stopped after \(sent) of \(data.count) bytes: \(error.localizedDescription). Check what printed before you print again")
                }
                sent += count
                if count > 0 { lastProgress = Date() }
                guard count < chunk.length else { continue }
                // The printer stopped taking data. A write isn't an error yet: it may be busy printing.
                let stalled = Date().timeIntervalSince(lastProgress)
                let status = (try? ask("~HS", timeout: 2, quiet: 0.3) { $0.filter { $0 == 0x03 }.count >= 3 }).flatMap { Status(reply: String(decoding: $0, as: UTF8.self)) }
                // A full buffer is what a slow printer looks like here; anything else won't clear by waiting.
                if let problem = status?.problems.first(where: { $0 != "its buffer is full" }) {
                    throw Failed(description: "\(label) stopped after \(sent) of \(data.count) bytes because \(problem). Check what printed before you print again")
                }
                if stalled > Self.stallLimit {
                    throw Failed(description: "\(label) stopped taking data after \(sent) of \(data.count) bytes. Check what printed before you print again")
                }
            }
        }

        // MARK: Transfers

        private static let chunkSize = 16 * 1024
        private static let chunkTimeout: TimeInterval = 5
        private static let stallLimit: TimeInterval = 30

        /// What a pipe reports when time runs out. Bytes moved before that still count.
        private func timedOut(_ error: Error) -> Bool {
            let code = (error as NSError).code
            return code == Int(kIOReturnTimeout) || code == Int(Int32(bitPattern: 0xE000_5000))
        }

        private func send(_ data: Data) throws {
            var bytes = data
            if bytes.count % packetSize == 0 { bytes.append(contentsOf: [0x0D, 0x0A]) }
            let count = try writeChunk(NSMutableData(data: bytes))
            guard count == bytes.count else { throw Failed(description: "\(label) didn't take the command") }
        }

        /// Sends what it can; returns how many bytes went out. Any error but a timeout halts the pipe
        /// until it's cleared.
        private func writeChunk(_ chunk: NSMutableData) throws -> Int {
            guard let output else { throw Failed(description: "the printer isn't connected over USB") }
            var count = 0
            do {
                try output.__sendIORequest(with: chunk, bytesTransferred: &count, completionTimeout: Self.chunkTimeout)
            } catch where timedOut(error) {
                return count
            } catch {
                try? output.clearStall()
                throw error
            }
            return count
        }

        /// Whatever the printer has for us, or nothing once `seconds` pass.
        private func read(within seconds: TimeInterval) throws -> [UInt8] {
            guard let input else { throw Failed(description: "the printer isn't connected over USB") }
            let buffer = NSMutableData(length: 4096)!
            var count = 0
            do {
                try input.__sendIORequest(with: buffer, bytesTransferred: &count, completionTimeout: seconds)
            } catch where timedOut(error) {
                // Below, with whatever arrived.
            } catch {
                try? input.clearStall()
                throw error
            }
            return [UInt8]((buffer as Data).prefix(count))
        }
    }
}

extension Zebra.Link {
    /// USB printers are present when attached. An address can only be tried.
    public var isPresent: Bool {
        guard case .usb(let id) = self else { return true }
        return Zebra.usbPrinters().contains { $0.id == id }
    }

    /// Opens the USB printer for one command, sharing it if a print holds it open.
    func withUSB<T>(_ id: String, within timeout: TimeInterval, _ body: (Zebra.USBPort) throws -> T) throws -> T {
        let port = Zebra.USBPort.named(id)
        try port.open(within: timeout)
        defer { port.close() }
        return try body(port)
    }
}
