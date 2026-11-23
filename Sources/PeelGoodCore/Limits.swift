import Foundation
import LabelKit

/// Every value list and range the app, the API, MCP and the command line accept, in one place.
/// Pickers list `*Choices`; schemas and validation use the ranges; a picker always shows the saved
/// value even when another client (MCP) set one outside its list.
public enum Limits {
    public static let copies = 1...100
    public static let countdownSeconds: ClosedRange<Double> = 0...10
    public static let countdownChoices: [Double] = [0, 1.5, 3]
    public static let historyDays = 0...3650
    /// 0 keeps prints forever.
    public static let historyChoices = [1, 7, 30, 90, 365, 0]
    /// The black and white cutoff, 0...1 (the CLI takes it as a percentage).
    public static let cutoff: ClosedRange<Double> = 0.2...0.8
    public static let nudgeMM: ClosedRange<Double> = -10...10
    public static let toneGamma: ClosedRange<Double> = 0.1...2
    public static let paddingMM: ClosedRange<Double> = 0...50
    /// Direct placement's scale, in percent of physical size.
    public static let scalePercent: ClosedRange<Double> = 25...400
    /// A Zebra's darkness adjustment for Peel Good's labels (^MD, added to the printer's own) and print speed.
    public static let darkness = ZPL.Tuning.darknessRange
    public static let printSpeed = ZPL.Tuning.speedRange
    public static let darknessDescription = "Zebra only: added to the printer's own darkness for Peel Good's labels (ZPL ^MD), \(darkness.lowerBound) to \(darkness.upperBound). "
        + "Each job puts it back to 0 once its labels print, so other apps and the printer's saved setting are untouched. 0 or null: no change."
    public static let printSpeedDescription = "Zebra only: print speed for Peel Good's labels in inches per second (ZPL ^PR), \(printSpeed.lowerBound) to \(printSpeed.upperBound); "
        + "slower prints darker, and a printer slower than asked prints at its maximum. Put back after each job. null uses the printer's own speed."
    public static let tagNameLength = 64
    public static let inks = InkMode.allCases.map(\.rawValue)
    public static let fits = FitMode.allCases.map(\.rawValue)
    /// What each placement does and which one wins, for schemas and help.
    public static let fitDescription = "Placement. " + FitMode.allCases.map { "\($0.rawValue): \($0.help)" }.joined(separator: "; ")
        + ". A value given here wins over the matching rule's, which wins over the printer's setting. Defaults to the printer's setting (fill unless changed). "
        + "Older names still work: fit means fill, as-is means fit-page."
    public static let scaleDescription = "Direct placement only: percent of physical size, \(Int(scalePercent.lowerBound)) to \(Int(scalePercent.upperBound)). "
        + "100 prints 1 mm on the page as 1 mm on the label; 95 or 105 nudge it smaller or bigger. "
        + "A value given here wins over the matching rule's, which wins over the printer's setting (100 unless changed)."

    /// "Immediately", "After 1.5 s".
    public static func countdownTitle(_ seconds: Double) -> String {
        seconds <= 0 ? "Immediately" : "After \(LabelSize.format(seconds)) s"
    }

    /// "1 day", "1 week", "1 month", "3 months", "1 year", "Forever", else "12 days".
    public static func historyTitle(_ days: Int) -> String {
        switch days {
        case 0: "Forever"
        case 1: "1 day"
        case 7: "1 week"
        case 30: "1 month"
        case 90: "3 months"
        case 365: "1 year"
        default: "\(days) days"
        }
    }

    /// The list, plus `current` in order when it isn't one of them, so a picker never shows blank.
    public static func choices<T: Comparable>(_ list: [T], including current: T, keepLast: T? = nil) -> [T] {
        guard !list.contains(current) else { return list }
        var head = list.filter { $0 != keepLast }
        head.append(current)
        head.sort()
        return keepLast.map { list.contains($0) ? head + [$0] : head } ?? head
    }

    /// "1 to 100", for error messages.
    public static func describe<T>(_ range: ClosedRange<T>) -> String { "\(range.lowerBound) to \(range.upperBound)" }
}
