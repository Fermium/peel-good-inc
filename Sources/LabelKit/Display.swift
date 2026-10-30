import Foundation

// How sizes, printers and modes read in the app's menus and the command line's output, defined once.

extension LabelSize {
    /// "4 × 6 in (102 × 152 mm)", or "100 × 150 mm (3.94 × 5.91 in)" for metric rolls.
    public var display: String { "\(primary) (\(secondary))" }
    /// "4 × 6 in", or "100 × 150 mm" for metric rolls.
    public var primary: String { isMetric ? mmText : inchText }
    /// The other unit: "102 × 152 mm", or "3.94 × 5.91 in".
    public var secondary: String { isMetric ? inchText : mmText }
    private var inchText: String { "\(LabelSize.format(width)) × \(LabelSize.format(height)) in" }
    private var mmText: String { "\(LabelSize.millimetres(width)) × \(LabelSize.millimetres(height)) mm" }
}

extension PrinterInfo {
    /// "MUNBYN ITPP941AP" rather than the queue name.
    public var displayName: String {
        let model = makeAndModel.replacingOccurrences(of: "-AirPrint", with: "")
        return model.isEmpty ? Self.displayName(queue: name) : model
    }

    /// "Ready", "Printing", "Offline", "Not answering", or what stops it ("The print head is open"),
    /// for the menu, Settings and the command line alike.
    public var statusText: String {
        if let problem { return problem.prefix(1).uppercased() + problem.dropFirst() }
        return switch state {
        case .idle: "Ready"
        case .printing: "Printing"
        case .stopped: "Offline"
        case .unknown: "Not answering"
        }
    }

    /// A queue name made readable ("MUNBYN_ITPP941AP" reads "MUNBYN ITPP941AP"), for printers that aren't connected.
    public static func displayName(queue: String) -> String { queue.replacingOccurrences(of: "_", with: " ") }
}

extension InkMode {
    /// "Auto", "Crisp", "Photo", "Halftone": the pickers' titles.
    public var title: String { rawValue.capitalized }
    /// One line on what the mode does, for help text and API descriptions.
    public var help: String {
        switch self {
        case .auto: "picks per page"
        case .crisp: "hard cutoff, sharp text and codes"
        case .photo: "dithers grays"
        case .halftone: "dot screen for gradients"
        }
    }
}

extension FitMode {
    public var title: String { rawValue.capitalized }
}
