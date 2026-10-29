import Foundation

/// How a label's codes came out and which warnings are worth showing. The popover, the API and MCP, and the
/// command line all report from here, so they always agree.
public struct CodeCounts: Equatable, Sendable {
    /// Codes found inside the crops.
    public var expected: Int
    /// Codes that still decode from the finished labels.
    public var verified: Int { expected - missing.count }
    /// Payloads of the codes that don't decode, in label order.
    public var missing: [String]

    public init(expected: Int, missing: [String]) {
        self.expected = expected
        self.missing = missing
    }
}

extension ComposedLabel {
    public var codeCounts: CodeCounts {
        CodeCounts(expected: expectedCodes.count, missing: missingCodes.map(\.payload))
    }

    /// The warnings minus cautions about codes that should still scan.
    public var reportableWarnings: [String] {
        let cautions = Set(codeReports.filter { $0.severity == .caution }.compactMap(\.message))
        return warnings.filter { !cautions.contains($0) }
    }
}

extension Array where Element == ComposedLabel {
    public var codeCounts: CodeCounts {
        CodeCounts(expected: reduce(0) { $0 + $1.expectedCodes.count }, missing: flatMap(\.missingCodes).map(\.payload))
    }

    /// Every label's reportable warnings, once each, sorted.
    public var reportableWarnings: [String] {
        Set(flatMap(\.reportableWarnings)).sorted()
    }
}
