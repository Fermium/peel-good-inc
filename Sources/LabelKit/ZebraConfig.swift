import Foundation

// The printer's own configuration: what Settings › Printers can change on a Zebra. None of it is per job:
// every app's labels print with it, so it's only ever changed on purpose, while the printer is idle,
// and saved (^JUS) only when asked.
//
// Commands and ranges as in Zebra's ZPL II Programming Guide (P1012728): ~SD p.333, ^PR p.326, ^MT p.311,
// ^MN p.307, ^MM p.305, ~TA p.355, ~JC p.254, ~WC p.359, ^JU p.278, ~HD p.219.

extension Zebra {
    public enum PrintMethod: String, CaseIterable, Sendable {
        case directThermal, thermalTransfer
        public var title: String { self == .directThermal ? "Direct thermal" : "Thermal transfer (ribbon)" }
        var code: String { self == .directThermal ? "D" : "T" }
    }

    /// ^MN: Y (web sensing) for gaps and notches, M for black marks, N for continuous.
    public enum Tracking: String, CaseIterable, Sendable {
        case gap, mark, continuous
        public var title: String {
            switch self {
            case .gap: "Gap or notch"
            case .mark: "Black mark"
            case .continuous: "Continuous"
            }
        }
        /// ^MNY for gaps, never ^MNM (LPrint's bug feeds blank labels).
        var code: String {
            switch self {
            case .gap: "Y"
            case .mark: "M"
            case .continuous: "N"
            }
        }
    }

    /// ^MM. The guide: which modes work depends on the printer and its options; an unsupported one is
    /// ignored and the current mode stays (the read-back after Apply shows it).
    public enum PrintMode: String, CaseIterable, Sendable {
        case tearOff, peelOff, cutter, rewind
        public var title: String {
            switch self {
            case .tearOff: "Tear off"
            case .peelOff: "Peel off"
            case .cutter: "Cutter"
            case .rewind: "Rewind"
            }
        }
        var code: String {
            switch self {
            case .tearOff: "T"
            case .peelOff: "P"
            case .cutter: "C"
            case .rewind: "R"
            }
        }
    }

    /// What the app can change. Nil means the printer didn't say (or it isn't being changed).
    public struct Config: Equatable, Sendable {
        /// 0–30 (~SD).
        public var darkness: Int?
        /// Inches per second (^PR). A printer slower than asked prints at its own maximum.
        public var speed: Int?
        /// Feeding and backfeed speeds (from ~HD), sent unchanged with the print speed: ^PR's own
        /// defaults for them (6 and 2 in/s) would otherwise replace what the printer is set to.
        public var slew: Int?
        public var backfeed: Int?
        public var method: PrintMethod?
        public var tracking: Tracking?
        public var mode: PrintMode?
        /// Where labels stop to be torn off, in dot rows, −120…120 (~TA; the step doubles at 600 dpi).
        public var tearOff: Int?

        public static let darknessRange = 0...30
        public static let speedRange = 1...14
        public static let tearOffRange = -120...120

        public init(darkness: Int? = nil, speed: Int? = nil, method: PrintMethod? = nil, tracking: Tracking? = nil,
                    mode: PrintMode? = nil, tearOff: Int? = nil) {
            self.darkness = darkness
            self.speed = speed
            self.method = method
            self.tracking = tracking
            self.mode = mode
            self.tearOff = tearOff
        }

        /// The values in the `^HH` configuration, as the printer words them, and the `~HD` speeds.
        public init(_ s: Setup, diagnostic: [String: String] = [:]) {
            slew = diagnostic["Slew Speed"].flatMap { Int($0) }
            backfeed = diagnostic["Backfeed Speed"].flatMap { Int($0) }
            func leadingNumber(_ text: String?) -> Double? {
                text.flatMap { t in Double(t.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }) }
            }
            darkness = leadingNumber(s.darkness).map { Int($0.rounded()) }
            speed = leadingNumber(s.printSpeed).map { Int($0.rounded()) }
            tearOff = leadingNumber(s.tearOff).map { Int($0.rounded()) }
            let methodText = s.printMethod?.uppercased() ?? ""
            method = methodText.contains("DIRECT") ? .directThermal : methodText.contains("TRANS") ? .thermalTransfer : nil
            let media = s.mediaType?.uppercased() ?? ""
            // "NON-CONTINUOUS" (some firmware) is gap media, so it's tested before "CONTINUOUS".
            tracking = media.contains("GAP") || media.contains("NOTCH") || media.contains("WEB") || media.hasPrefix("NON") ? .gap
                : media.contains("MARK") ? .mark : media.contains("CONTINUOUS") ? .continuous : nil
            let mode = s.printMode?.uppercased() ?? ""
            self.mode = mode.contains("TEAR") ? .tearOff : mode.contains("PEEL") ? .peelOff
                : mode.contains("CUT") ? .cutter : mode.contains("REWIND") ? .rewind : nil
        }

        /// Each setting that differs from `old`, worded for the review: "Darkness: 10 → 15".
        public func changes(from old: Config) -> [String] {
            var out: [String] = []
            func add<T: Equatable>(_ name: String, _ a: T?, _ b: T?, _ show: (T) -> String) {
                guard let b, a != b else { return }
                out.append("\(name): \(a.map(show) ?? "?") → \(show(b))")
            }
            add("Darkness", old.darkness, darkness) { "\($0)" }
            add("Print speed", old.speed, speed) { "\($0) in/s" }
            add("Print method", old.method, method) { $0.title }
            add("Media", old.tracking, tracking) { $0.title }
            add("Print mode", old.mode, mode) { $0.title }
            add("Tear-off position", old.tearOff, tearOff) { String(format: "%+d dots", $0) }
            return out
        }

        /// The ZPL for what differs from `old`: tilde commands first (they act at once), then one format.
        public func commands(from old: Config, save: Bool) -> String {
            var tilde = "", format = ""
            if let d = darkness, d != old.darkness { tilde += String(format: "~SD%02d", Self.darknessRange.clamped(d)) }
            if let t = tearOff, t != old.tearOff {
                let v = Self.tearOffRange.clamped(t)
                tilde += "~TA" + (v < 0 ? "-" : "") + String(format: "%03d", abs(v))
            }
            if let s = speed, s != old.speed {
                format += "^PR\(Self.speedRange.clamped(s))"
                if let slew = old.slew, let backfeed = old.backfeed { format += ",\(slew),\(backfeed)" }
            }
            if let m = method, m != old.method { format += "^MT\(m.code)" }
            if let t = tracking, t != old.tracking { format += "^MN\(t.code)" }
            if let m = mode, m != old.mode { format += "^MM\(m.code)" }
            if save { format += "^JUS" }
            return tilde + (format.isEmpty ? "" : "^XA\(format)^XZ")
        }
    }

    /// The printer's current configuration, or nil while it can't answer (paused, head open…).
    public static func config(_ printer: any Channel) throws -> (config: Config, setup: Setup)? {
        guard let setup = try setup(printer) else { return nil }
        return (Config(setup, diagnostic: (try? headDiagnostic(printer)) ?? [:]), setup)
    }

    /// The `~HD` reply, "Slew Speed = 6" lines as a dictionary.
    public static func headDiagnostic(_ printer: any Channel) throws -> [String: String] {
        let reply = try printer.query("~HD", timeout: 3, quiet: 1) { $0.contains(0x03) }
        var values: [String: String] = [:]
        for line in reply.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        return values
    }

    /// Changes what differs from `current` and returns the configuration the printer then reports,
    /// so out-of-range values show up as what the printer actually took.
    public static func apply(_ wanted: Config, over current: Config, save: Bool, to printer: any Channel) throws -> Config? {
        let commands = wanted.commands(from: current, save: save)
        guard !commands.isEmpty else { return current }
        try requireIdle(printer, doing: "take settings")
        try printer.write(commands)
        Thread.sleep(forTimeInterval: save ? 1.5 : 0.5)
        // The settings are sent; a failed read-back only means we can't show what the printer kept.
        return ((try? config(printer)) ?? nil)?.config
    }

    /// Feeds labels to measure them and set the sensors (~JC).
    public static func calibrate(_ printer: any Channel) throws {
        try requireIdle(printer, doing: "calibrate")
        try printer.write("~JC")
    }

    /// Prints the printer's own configuration label (~WC).
    public static func printConfigurationLabel(_ printer: any Channel) throws {
        try requireIdle(printer, doing: "print its configuration")
        try printer.write("~WC")
    }

    /// Settings and tilde commands apply to whatever is queued (tildes even jump ahead of it), so they
    /// only go to a printer that's ready and idle.
    @discardableResult
    static func requireIdle(_ printer: any Channel, doing what: String) throws -> Status {
        let s = try status(printer)
        guard s.problems.isEmpty else { throw Failed(description: "\(printer.label) can't \(what): \(s.problems.joined(separator: ", "))") }
        guard s.isIdle else { throw Failed(description: "\(printer.label) is busy printing; try again when it's done") }
        return s
    }
}

private extension ClosedRange where Bound == Int {
    func clamped(_ v: Int) -> Int { Swift.min(Swift.max(v, lowerBound), upperBound) }
}
