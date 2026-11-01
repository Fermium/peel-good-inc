import Darwin
import Foundation

/// Talking to Zebra printers on the network: raw ZPL on TCP 9100, the printer's status and setup
/// replies, and Zebra's UDP discovery on port 4201.
///
/// Plain BSD sockets: a write followed by a clean close is what printers expect (ZPLKit found
/// Network.framework's teardown can drop jobs on real hardware).
public enum Zebra {
    public static let port: UInt16 = 9100

    /// "Zebra GX420t".
    public static func displayName(product: String) -> String { "Zebra \(product)" }

    public struct Failed: Error, CustomStringConvertible {
        public let description: String
    }

    // MARK: Identity

    /// The `~HI` reply: "GX420t-200dpi,V56.17.17Z,8,2104KB".
    public struct Identity: Sendable, Equatable {
        public var model: String
        public var firmware: String
        public var dotsPerMM: Int
        public var memoryKB: Int?

        /// 8 dots/mm is the "203 dpi" head, 12 the "300 dpi" one: 25.4 × dots/mm exactly.
        public var dpi: Double { Double(dotsPerMM) * 25.4 }

        /// "GX420t" without the "-200dpi" suffix.
        public var product: String {
            model.range(of: #"-\d+dpi$"#, options: .regularExpression).map { String(model[..<$0.lowerBound]) } ?? model
        }

        public init?(reply: String) {
            let parts = Zebra.frames(reply).first?.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? []
            guard parts.count >= 3, let dpmm = Int(parts[2]), dpmm > 0 else { return nil }
            model = parts[0]
            firmware = parts[1]
            dotsPerMM = dpmm
            memoryKB = parts.count > 3 ? Int(parts[3].filter(\.isNumber)) : nil
        }
    }

    /// Setup values from the `^HH` configuration text, in dots.
    public struct Setup: Sendable, Equatable {
        public var printWidth: Int?
        public var labelLength: Int?
        /// Dots across the whole print head ("832 8/MM FULL").
        public var headWidth: Int?
        /// The longest label the printer will feed, in inches.
        public var maximumLength: Double?
        public var printMode: String?
        public var mediaType: String?
        public var printMethod: String?
        public var darkness: String?
        /// The printer's own calibration: LEFT POSITION (^LS, positive moves the image left) and
        /// LABEL TOP (^LT, positive moves it down), in dots.
        public var leftPosition: Int?
        public var labelTop: Int?
        public var serial: String?
        /// "6 IPS", "+000": kept as the printer words them, read by `Zebra.Config`.
        public var printSpeed: String?
        public var tearOff: String?

        /// Continuous media: no gaps or marks, so labels are as long as ^LL says.
        public var isContinuous: Bool { mediaType?.uppercased().hasPrefix("CONTINUOUS") == true }

        public init(reply: String) {
            var values: [String: String] = [:]
            for line in reply.split(whereSeparator: \.isNewline) {
                // "  813                 PRINT WIDTH": value, a run of spaces, then the name in capitals.
                // Values can hold spaces too ("39.0IN   989MM"), names only single ones: split at the last run.
                let text = line.filter { $0 != "\u{02}" && $0 != "\u{03}" }.trimmingCharacters(in: .whitespaces)
                guard let gap = text.matches(of: /\s{2,}/).last?.range else { continue }
                values[text[gap.upperBound...].trimmingCharacters(in: .whitespaces)] = String(text[..<gap.lowerBound])
            }
            func leadingInt(_ key: String) -> Int? { values[key].flatMap { Int($0.prefix { $0.isNumber }) } }
            printWidth = leadingInt("PRINT WIDTH")
            labelLength = leadingInt("LABEL LENGTH")
            headWidth = leadingInt("RESOLUTION")
            maximumLength = values["MAXIMUM LENGTH"].flatMap { Double($0.prefix { $0.isNumber || $0 == "." }) }
            printMode = values["PRINT MODE"]
            mediaType = values["MEDIA TYPE"]
            printMethod = values["PRINT METHOD"]
            darkness = values["DARKNESS"]
            leftPosition = values["LEFT POSITION"].flatMap { Int($0.replacingOccurrences(of: "+", with: "")) }
            labelTop = values["LABEL TOP"].flatMap { Int($0.replacingOccurrences(of: "+", with: "")) }
            serial = values["SERIAL NUMBER"]
            printSpeed = values["PRINT SPEED"]
            tearOff = values["TEAR OFF"]
        }
    }

    // MARK: Status

    /// The `~HS` reply: three STX…ETX lines of comma-separated fields.
    public struct Status: Sendable, Equatable {
        public var paperOut = false
        public var paused = false
        public var headOpen = false
        public var ribbonOut = false
        public var bufferFull = false
        public var underTemperature = false
        public var overTemperature = false
        public var corruptRAM = false
        /// Formats received and not yet printed.
        public var formatsInBuffer = 0
        /// Labels still to print in the current batch.
        public var labelsRemaining = 0

        public init?(reply: String) {
            let lines = Zebra.frames(reply).map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
            guard lines.count >= 2, lines[0].count >= 12, lines[1].count >= 9 else { return nil }
            func flag(_ f: [String], _ i: Int) -> Bool { (Int(f[i]) ?? 0) != 0 }
            let a = lines[0], b = lines[1]
            paperOut = flag(a, 1)
            paused = flag(a, 2)
            formatsInBuffer = Int(a[4]) ?? 0
            bufferFull = flag(a, 5)
            corruptRAM = flag(a, 9)
            underTemperature = flag(a, 10)
            overTemperature = flag(a, 11)
            headOpen = flag(b, 2)
            ribbonOut = flag(b, 3)
            labelsRemaining = Int(b[8]) ?? 0
        }

        /// What stops printing, worded for people. Empty when the printer is ready.
        public var problems: [String] {
            var p: [String] = []
            if headOpen { p.append("the print head is open") }
            if paperOut { p.append("it's out of labels") }
            if ribbonOut { p.append("it's out of ribbon") }
            if paused { p.append("it's paused") }
            if overTemperature { p.append("the print head is too hot") }
            if underTemperature { p.append("the print head is too cold") }
            if corruptRAM { p.append("its memory is corrupt") }
            if bufferFull { p.append("its buffer is full") }
            return p
        }

        public var isIdle: Bool { formatsInBuffer == 0 && labelsRemaining == 0 }
    }

    /// The text between STX (0x02) and ETX (0x03) markers, in order.
    static func frames(_ reply: String) -> [String] {
        reply.split(separator: "\u{03}").compactMap { chunk in
            guard let stx = chunk.firstIndex(of: "\u{02}") else { return nil }
            return String(chunk[chunk.index(after: stx)...])
        }
    }

    public static func identify(_ host: String, timeout: TimeInterval = 4) throws -> Identity {
        let reply = try query(host, "~HI", timeout: timeout) { $0.contains(0x03) }
        guard let id = Identity(reply: reply) else { throw Failed(description: "\(host) didn't answer like a Zebra printer") }
        return id
    }

    /// The configuration, or nil while the printer can't answer: ^XA^HH^XZ is a format, so a paused
    /// printer queues it (and prints nothing) instead of replying. Checks `~HS` first for that reason,
    /// unless the caller just did (`known`).
    public static func setup(_ host: String, known: Status? = nil, timeout: TimeInterval = 5) throws -> Setup? {
        guard try (known ?? status(host)).problems.isEmpty else { return nil }
        // The configuration ends with its last setting; wait for the reply to go quiet.
        return Setup(reply: try query(host, "^XA^HH^XZ", timeout: timeout, quiet: 0.6) { _ in false })
    }

    /// An SGD value (`! U1 getvar`), or nil when the printer doesn't know it ("?").
    public static func getvar(_ host: String, _ name: String, timeout: TimeInterval = 3) throws -> String? {
        let reply = try query(host, "! U1 getvar \"\(name)\"\r\n", timeout: timeout, quiet: 0.3) {
            $0.filter { $0 == UInt8(ascii: "\"") }.count >= 2
        }
        let value = reply.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return value.isEmpty || value == "?" ? nil : value
    }

    public static func status(_ host: String, timeout: TimeInterval = 4) throws -> Status {
        let reply = try query(host, "~HS", timeout: timeout) { $0.filter { $0 == 0x03 }.count >= 3 }
        guard let status = Status(reply: reply) else { throw Failed(description: "\(host) sent an unreadable status") }
        return status
    }

    // MARK: Describing

    /// What Peel Good remembers about a Zebra on the network. Keyed by serial number, so a new
    /// address (DHCP) finds the same printer and its settings.
    public struct Profile: Codable, Sendable, Equatable {
        public var serial: String
        public var host: String
        /// "GX420t".
        public var product: String
        public var dotsPerMM: Int
        /// Dots across the print head.
        public var headDots: Int
        /// The longest label it feeds, in inches.
        public var maximumLength: Double
        /// The print server's serial from the 4201 discovery reply, to recognise it when scanning.
        public var discoveryID: String?

        public init(serial: String, host: String, product: String, dotsPerMM: Int, headDots: Int,
                    maximumLength: Double, discoveryID: String? = nil) {
            self.serial = serial
            self.host = host
            self.product = product
            self.dotsPerMM = dotsPerMM
            self.headDots = headDots
            self.maximumLength = maximumLength
            self.discoveryID = discoveryID
        }

        public var dpi: Double { Double(dotsPerMM) * 25.4 }

        public var displayName: String { Zebra.displayName(product: product) }

        /// "Zebra_99J000000001": the name its settings and rules use.
        public var printerName: String { "Zebra_\(serial)" }

        /// The printer for menus, rules and printing: any label up to its head width and maximum length.
        public func printer(name: String? = nil, status: Status? = nil) -> PrinterInfo {
            let state: PrinterInfo.State = status.map { $0.problems.isEmpty ? ($0.isIdle ? .idle : .printing) : .stopped } ?? .unknown
            return PrinterInfo(
                name: name ?? printerName, makeAndModel: displayName, state: state, presets: [],
                customMin: LabelSize(width: 0.75, height: 0.25),
                customMax: LabelSize(width: Double(headDots) / dpi, height: maximumLength),
                dpi: dpi, zebraHost: host, problem: status?.problems.first
            )
        }
    }

    public struct Description: Sendable {
        public var profile: Profile
        public var identity: Identity
        public var setup: Setup?
        public var status: Status?
    }

    /// Asks a Zebra what it is (`~HI`, `~HS`, then `^HH` and its serial when it's ready).
    public static func describe(_ host: String, discoveryID: String? = nil) throws -> Description {
        let id = try identify(host)
        let status = try? status(host)
        let setup = status.flatMap { (try? self.setup(host, known: $0)) ?? nil }
        let serial = (try? getvar(host, "device.unique_id")) ?? nil
        let profile = Profile(
            serial: serial ?? setup?.serial ?? host, host: host, product: id.product, dotsPerMM: id.dotsPerMM,
            headDots: setup?.headWidth ?? setup?.printWidth ?? Int((4.09 * id.dpi).rounded()),
            maximumLength: setup?.maximumLength ?? 39, discoveryID: discoveryID
        )
        return Description(profile: profile, identity: id, setup: setup, status: status)
    }

    // MARK: Calibration

    /// Moves the printer's own calibration by `dx`, `dy` dots (+x right, +y down) and saves it (^JUS),
    /// so every app prints there. Only when the printer is idle: settings sent mid-job apply to it.
    /// Returns the new LEFT POSITION and LABEL TOP.
    @discardableResult
    public static func moveCalibration(_ host: String, dx: Int, dy: Int) throws -> (leftPosition: Int, labelTop: Int) {
        let s = try requireIdle(host, doing: "take settings")
        guard let setup = try setup(host, known: s), let left = setup.leftPosition, let top = setup.labelTop else {
            throw Failed(description: "\(host) didn't report its LEFT POSITION and LABEL TOP")
        }
        // ^LS moves the image left for positive values, so a move right lowers it; ^LT moves it down.
        let newLeft = left - dx, newTop = top + dy
        guard (-9999...9999).contains(newLeft), (-120...120).contains(newTop) else {
            throw Failed(description: "that offset is outside what the printer accepts")
        }
        try write("^XA^LS\(newLeft)^LT\(newTop)^JUS^XZ", to: host)
        return (newLeft, newTop)
    }

    // MARK: Sending

    /// Checks the printer is ready, then writes the job and closes the connection.
    /// The printer acknowledges nothing; `waitUntilPrinted` watches it work through the job.
    public static func send(_ job: Data, to host: String, timeout: TimeInterval = 10) throws {
        let status = try status(host)
        if !status.problems.isEmpty {
            throw Failed(description: "\(host) can't print: \(status.problems.joined(separator: ", "))")
        }
        try write(job, to: host, timeout: timeout)
    }

    static func write(_ text: String, to host: String) throws { try write(Data(text.utf8), to: host, timeout: 10) }

    /// Writes bytes to port 9100 and closes the connection cleanly.
    static func write(_ job: Data, to host: String, timeout: TimeInterval) throws {
        let fd = try connect(host, timeout: timeout)
        defer { close(fd) }
        try job.withUnsafeBytes { try sendAll(fd, $0, host: host) }
        shutdown(fd, SHUT_WR)
    }

    private static func sendAll(_ fd: Int32, _ raw: UnsafeRawBufferPointer, host: String) throws {
        var offset = 0
        while offset < raw.count {
            let n = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
            if n < 0 {
                if errno == EINTR { continue }
                throw Failed(description: "sending to \(host) failed: \(String(cString: strerror(errno)))")
            }
            offset += n
        }
    }

    /// Polls `~HS` until the printer has no formats or labels left, or reports a problem.
    @discardableResult
    public static func waitUntilPrinted(_ host: String, timeout: TimeInterval = 45, every interval: TimeInterval = 0.7) throws -> Status {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let s = try status(host)
            if !s.problems.isEmpty { throw Failed(description: "\(host) stopped: \(s.problems.joined(separator: ", "))") }
            if s.isIdle { return s }
            if Date() > deadline { throw Failed(description: "\(host) is still printing after \(Int(timeout)) s") }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    // MARK: Discovery

    public struct Found: Sendable, Equatable {
        public var host: String
        /// The print server's product name ("ZebraNet Wired PS").
        public var server: String
        public var firmware: String
        public var serial: String
        /// The name set on the printer ("ZBR11123456" by default).
        public var systemName: String

        /// Parses a reply to the 4201 probe. Field offsets as documented by ZPLKit (MIT).
        public init?(reply: [UInt8], from host: String) {
            guard reply.count >= 109, reply[0] == 0x3A, reply[1] == 0x2C, reply[2] == 0x2E else { return nil }
            func text(_ offset: Int, _ length: Int) -> String {
                let bytes = reply[offset..<min(offset + length, reply.count)].prefix { $0 != 0 }
                return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            self.host = host
            server = text(12, 20)
            firmware = text(39, 20)
            serial = text(62, 10)
            systemName = text(84, 25)
        }
    }

    /// Broadcasts Zebra's discovery probe on every IPv4 interface and collects the replies.
    public static func discover(timeout: TimeInterval = 3) -> [Found] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        let probe: [UInt8] = [0x2E, 0x2C, 0x3A, 0x01, 0x00, 0x00]
        let targets = broadcastAddresses() + [INADDR_BROADCAST]
        var found: [String: Found] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        var round = 0
        while Date() < deadline {
            // UDP drops packets: probe again every second, as Zebra's own tools do.
            if round % 3 == 0 {
                for target in targets {
                    var addr = sockaddr_in()
                    addr.sin_family = sa_family_t(AF_INET)
                    addr.sin_port = UInt16(4201).bigEndian
                    addr.sin_addr.s_addr = target
                    withUnsafePointer(to: &addr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            _ = sendto(fd, probe, probe.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
            round += 1
            var buffer = [UInt8](repeating: 0, count: 2048)
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            guard n > 0 else { continue }
            let host = String(cString: inet_ntoa(from.sin_addr))
            if found[host] == nil, let f = Found(reply: Array(buffer[0..<n]), from: host) { found[host] = f }
        }
        return found.values.sorted { $0.host < $1.host }
    }

    /// Each IPv4 interface's subnet broadcast address (network byte order).
    private static func broadcastAddresses() -> [in_addr_t] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var out: [in_addr_t] = []
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = ifa.pointee.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            out.append(ip | ~m)
        }
        return out
    }

    // MARK: Sockets

    /// Sends a command and reads until `done` says the reply is complete, the printer goes quiet for
    /// `quiet` seconds after answering, or the timeout passes.
    static func query(_ host: String, _ command: String, timeout: TimeInterval, quiet: TimeInterval = 1,
                      done: ([UInt8]) -> Bool) throws -> String {
        let fd = try connect(host, timeout: timeout)
        defer { close(fd) }
        try Array(command.utf8).withUnsafeBytes { try sendAll(fd, $0, host: host) }
        var reply: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline, !done(reply) {
            let wait = reply.isEmpty ? deadline.timeIntervalSinceNow : min(quiet, deadline.timeIntervalSinceNow)
            guard wait > 0, readable(fd, within: wait) else { break }
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            reply += buffer[0..<n]
        }
        guard !reply.isEmpty else { throw Failed(description: "\(host) didn't answer") }
        return String(decoding: reply, as: UTF8.self)
    }

    private static func readable(_ fd: Int32, within seconds: TimeInterval) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, Int32(seconds * 1000)) > 0
    }

    /// A TCP connection to port 9100, giving up after `timeout`.
    static func connect(_ host: String, port: UInt16 = port, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else {
            throw Failed(description: "can't find \(host) on the network")
        }
        defer { freeaddrinfo(info) }
        var lastError = "no address"
        for ai in sequence(first: first, next: { $0.pointee.ai_next }) {
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var ok = Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0
            if !ok && errno == EINPROGRESS {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&p, 1, Int32(timeout * 1000)) > 0 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    ok = err == 0
                    if !ok { lastError = String(cString: strerror(err)) }
                } else {
                    lastError = "timed out"
                }
            } else if !ok {
                lastError = String(cString: strerror(errno))
            }
            if ok {
                _ = fcntl(fd, F_SETFL, flags)
                return fd
            }
            close(fd)
        }
        throw Failed(description: "can't connect to \(host): \(lastError)")
    }
}
