import Foundation
import IOKit
import IOKit.pwr_mgt
import IOUSBHost
import Synchronization

// Zebras on USB, through IOUSBHost: no driver, no root and no entitlement outside the sandbox. They
// are USB printer class 7/1/2 with a bulk pipe each way, and answer exactly as they do on port 9100.
// Differences from the network that shape this file, checked on a GX420t (V56.17.17Z):
// - Unread replies stay on the printer and mix into the next answer, so each query drains first.
// - Only one client can open the printer. A second one gets a generic error, not "busy", so opening
//   retries. CUPS waits for us and retries by itself.
// - A blocked write stops everything, tilde commands included: USB has no separate status channel.

extension Zebra {
    /// How messages name a printer on USB.
    static let usbLabel = "USB printer"

    private static var notOnUSB: Failed { Failed(description: "the printer isn't connected over USB") }

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

    /// Each attached Zebra's printer interface, with what `Link.usb` names it by: its USB serial
    /// number, or its port when that can't tell it apart. Asks IOKit only: nothing is opened, so a
    /// printer in use still shows up. The caller releases the services.
    private static func attached() -> [(id: String, service: io_service_t)] {
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
            (usableSerial(f.serial, model: f.model, among: found.map(\.serial)) ? f.serial : f.port, f.service)
        }
    }

    /// A USB serial can be blank, or the product family on printers set to share one ("ZT230"): Zebra
    /// documents that, so it only names a printer when it's unique and isn't the model.
    static func usableSerial(_ serial: String, model: String, among all: [String]) -> Bool {
        !serial.isEmpty && !model.localizedCaseInsensitiveContains(serial) && all.filter { $0 == serial }.count == 1
    }

    /// The ids of the Zebras attached over USB.
    public static func usbPrinters() -> [String] {
        attached().map { IOObjectRelease($0.service); return $0.id }
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
    public static func usbSpeaksZPL(id: String) throws -> Bool {
        let languages = commandSet(deviceID: try USBPort.named(id).deviceID())
        return languages.isEmpty || languages.contains("ZPL")
    }

    /// The connection to print on, so a printer unplugged from one is reached on the other. Nothing has
    /// been sent yet, so moving on is always safe. A USB printer that's attached is the answer even when
    /// it's busy: the job waits its turn in `holding` instead of going around it on the network. An
    /// address has to answer, unless it's the last choice. A printer that answers with a problem
    /// counts: `send` reports it.
    public static func route(_ links: [Link]) throws -> Link {
        let present = links.filter(\.isPresent)
        guard let last = present.last else { throw notOnUSB }
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
        return try port.whileOpen(within: 60) {
            var assertion: IOPMAssertionID = 0
            let awake = IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                    "Printing a label" as CFString, &assertion)
            defer { if awake == kIOReturnSuccess { IOPMAssertionRelease(assertion) } }
            // A job cut off earlier leaves half a format, which would swallow the start of this one.
            if let s = try? status(port), s.partialFormat { try? port.write("~JX") }
            return try body(port)
        }
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
        private static let ports = Mutex<[String: USBPort]>([:])

        static func named(_ id: String) -> USBPort {
            ports.withLock { ports in
                if let port = ports[id] { return port }
                let port = USBPort(id: id)
                ports[id] = port
                return port
            }
        }

        /// The interface and its pipes, while the printer is open.
        private struct Open {
            let interface: IOUSBHostInterface
            let output: IOUSBHostPipe
            let input: IOUSBHostPipe
            let packetSize: Int

            /// Finds the bulk pipes: the descriptor says which, since layouts differ between models.
            init(_ interface: IOUSBHostInterface) throws {
                var outAddress: Int?, inAddress: Int?, packetSize = 64
                let configuration = interface.configurationDescriptor, descriptor = interface.interfaceDescriptor
                var next = IOUSBGetNextEndpointDescriptor(configuration, descriptor, nil)
                while let endpoint = next {
                    let address = Int(endpoint.pointee.bEndpointAddress)
                    if endpoint.pointee.bmAttributes & 3 == 2 {
                        if address & 0x80 != 0 { inAddress = address } else {
                            outAddress = address
                            packetSize = max(Int(endpoint.pointee.wMaxPacketSize) & 0x7FF, 1)
                        }
                    }
                    next = IOUSBGetNextEndpointDescriptor(configuration, descriptor, UnsafePointer(OpaquePointer(endpoint)))
                }
                guard let outAddress, let inAddress else { throw Failed(description: "the USB printer has no way to answer") }
                self.interface = interface
                output = try interface.copyPipe(withAddress: outAddress)
                input = try interface.copyPipe(withAddress: inAddress)
                self.packetSize = packetSize
            }
        }

        let id: String
        let label = Zebra.usbLabel
        /// Held for a whole print.
        let job = NSLock()
        /// Held for each command. A write keeps it throughout, so nothing lands inside a format.
        private let transfer = NSLock()
        private let queue = DispatchQueue(label: "PeelGood.ZebraUSB")
        private var users = 0
        private var open: Open?

        private init(id: String) { self.id = id }

        /// Runs `body` with the printer open, sharing it if a print already holds it.
        func whileOpen<T>(within timeout: TimeInterval, _ body: () throws -> T) throws -> T {
            let deadline = Date().addingTimeInterval(timeout)
            // Between tries the lock is free, so waiting for another app doesn't hold up this one's commands.
            while try !transfer.withLock({ try addUser() }) {
                guard Date() < deadline else { throw Failed(description: "another app is using the USB printer") }
                Thread.sleep(forTimeInterval: 0.2)
            }
            defer {
                transfer.withLock {
                    users -= 1
                    if users == 0 {
                        open?.interface.destroy()
                        open = nil
                    }
                }
            }
            return try body()
        }

        /// False when the printer is there but can't be opened right now.
        private func addUser() throws -> Bool {
            if users == 0 {
                let printers = attached()
                defer { printers.forEach { IOObjectRelease($0.service) } }
                guard let service = printers.first(where: { $0.id == id })?.service else { throw notOnUSB }
                guard let interface = try? IOUSBHostInterface(__ioService: service, options: [], queue: queue, interestHandler: nil) else { return false }
                guard let opened = try? Open(interface) else {
                    interface.destroy()
                    return false
                }
                open = opened
            }
            users += 1
            return true
        }

        /// The IEEE 1284 Device ID (GET_DEVICE_ID).
        func deviceID() throws -> String {
            try whileOpen(within: 2) {
                try transfer.withLock {
                    guard let open else { throw notOnUSB }
                    let buffer = NSMutableData(length: 1024)!
                    var count = 0
                    let request = IOUSBDeviceRequest(bmRequestType: 0xA1, bRequest: 0, wValue: 0, wIndex: 0, wLength: 1024)
                    try open.interface.__send(request, data: buffer, bytesTransferred: &count, completionTimeout: 3)
                    // The first two bytes are its length.
                    return String(decoding: (buffer as Data).prefix(count).dropFirst(2), as: UTF8.self)
                }
            }
        }

        // MARK: Channel

        func query(_ command: String, timeout: TimeInterval, quiet: TimeInterval, done: ([UInt8]) -> Bool) throws -> String {
            let reply = try transfer.withLock { try ask(command, timeout: timeout, quiet: quiet, done: done) }
            guard !reply.isEmpty else { throw Failed(description: "\(label) didn't answer. Its print head may be open, or it may be out of labels") }
            return String(decoding: reply, as: UTF8.self)
        }

        private func ask(_ command: String, timeout: TimeInterval, quiet: TimeInterval, done: ([UInt8]) -> Bool) throws -> [UInt8] {
            // An answer nobody read, from an earlier client or a command that replied late.
            var drained = 0
            while drained < 64, try !read(within: 0.03).isEmpty { drained += 1 }
            let bytes = NSMutableData(data: try terminated(Data(command.utf8)))
            guard try writeChunk(bytes) == bytes.length else { throw Failed(description: "\(label) didn't take the command") }
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

        /// `timeout` doesn't apply: a busy printer takes data slowly, so what limits a write is
        /// `stallLimit`, the time with no progress.
        func write(_ job: Data, timeout: TimeInterval) throws {
            try transfer.withLock {
                let data = try terminated(job)
                var sent = 0
                var lastProgress = Date()
                func cutOff(_ what: String) -> Failed {
                    Failed(description: "\(what). Check what printed before you print again")
                }
                while sent < data.count {
                    let chunk = NSMutableData(data: data.subdata(in: sent..<min(sent + Self.chunkSize, data.count)))
                    let count: Int
                    do {
                        count = try writeChunk(chunk)
                    } catch {
                        throw cutOff("sending to \(label) stopped after \(sent) of \(data.count) bytes: \(error.localizedDescription)")
                    }
                    sent += count
                    if count > 0 { lastProgress = Date() }
                    guard count < chunk.length else { continue }
                    // The printer stopped taking data. A write isn't an error yet: it may be busy printing.
                    let stalled = Date().timeIntervalSince(lastProgress)
                    let reply = try? ask(Status.command, timeout: 2, quiet: 0.3, done: Status.isComplete)
                    if let problem = reply.flatMap({ Status(reply: String(decoding: $0, as: UTF8.self)) })?.faults.first {
                        throw cutOff("\(label) stopped after \(sent) of \(data.count) bytes because \(problem)")
                    }
                    if stalled > Self.stallLimit {
                        throw cutOff("\(label) stopped taking data after \(sent) of \(data.count) bytes")
                    }
                }
            }
        }

        // MARK: Transfers

        private static let chunkSize = 16 * 1024
        private static let chunkTimeout: TimeInterval = 5
        private static let stallLimit: TimeInterval = 30

        /// Data ending exactly on a packet boundary leaves it open whether the transfer has ended.
        /// Printers ignore line ends between formats, so one more settles it.
        private func terminated(_ data: Data) throws -> Data {
            guard let open else { throw notOnUSB }
            return data.count % open.packetSize == 0 ? data + [0x0D, 0x0A] : data
        }

        /// What a pipe reports when time runs out. Bytes moved before that still count.
        private func timedOut(_ error: Error) -> Bool {
            let code = (error as NSError).code
            return code == Int(kIOReturnTimeout) || code == Int(Int32(bitPattern: 0xE000_5000))
        }

        /// Sends what it can; returns how many bytes went out. Any error but a timeout halts the pipe
        /// until it's cleared.
        private func writeChunk(_ chunk: NSMutableData) throws -> Int {
            guard let output = open?.output else { throw notOnUSB }
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
            guard let input = open?.input else { throw notOnUSB }
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
        guard let id = usbID else { return true }
        return Zebra.usbPrinters().contains(id)
    }
}
