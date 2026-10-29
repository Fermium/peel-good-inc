import Foundation

/// What the HTTP API and the MCP server can ask the app to do. The API layer only talks to this.
/// `AppLabelService` is the real implementation; `MockLabelService` never prints.
@MainActor
protocol LabelService: AnyObject {
    func printers() -> [APIPrinter]
    /// Sizes for a printer, by queue name or display name.
    func sizes(printer: String) throws -> [APISize]
    /// Prints every page of every file. `request.path` is ignored here; the caller resolves files.
    /// `source` is an `APIJob.Source`; only `localFile` jobs get the after-print tag or move.
    func print(files: [URL], request: APIPrintRequest, source: String) async throws -> APIJob
    /// Composes every page of every file without printing.
    func preview(files: [URL], request: APIPrintRequest) async throws -> APIPreview
    func printClipboard(request: APIPrintRequest) async throws -> APIJob
    func reprintLast(copies: Int?) async throws -> APIJob
    /// Most recent first.
    func jobs() -> [APIJob]
}

// MARK: DTOs

struct APIPrinter: Codable, Sendable, Equatable {
    /// CUPS queue name, used to address the printer.
    var name: String
    var displayName: String
    var model: String
    /// The printer Labelize prints to by default.
    var isDefault: Bool
    var isLabelPrinter: Bool
    /// idle, printing, stopped or unknown.
    var state: String
    /// Current label size, for example "4x6".
    var size: String
    var fit: String
    var ink: String
}

struct APISize: Codable, Sendable, Equatable {
    /// "4x6", width × height in inches. Pass this as `size`.
    var size: String
    var display: String
    var widthInches: Double
    var heightInches: Double
    /// printer (a preset the printer reports) or catalog (a standard roll size).
    var source: String
    var supported: Bool
    var reason: String?
    var current: Bool
}

/// Options for print and preview. Everything is optional; missing values use the printer's settings.
struct APIPrintRequest: Codable, Sendable, Equatable {
    /// Absolute path to a PDF, SVG or image on this Mac. MCP only, with permission; the HTTP API refuses it.
    var path: String?
    var printer: String?
    var size: String?
    /// fit or fill.
    var fit: String?
    /// auto, crisp or photo.
    var ink: String?
    var copies: Int?

    init(path: String? = nil, printer: String? = nil, size: String? = nil, fit: String? = nil, ink: String? = nil, copies: Int? = nil) {
        self.path = path
        self.printer = printer
        self.size = size
        self.fit = fit
        self.ink = ink
        self.copies = copies
    }
}

struct APICode: Codable, Sendable, Equatable {
    var symbology: String
    var payload: String
    /// Still decodes from the finished 1-bit label.
    var scannable: Bool
    /// ok, caution or error.
    var severity: String?
    var message: String?
}

struct APIJob: Codable, Sendable, Equatable, Identifiable {
    /// waiting: still counting down or waiting for Print in the preview when the call returned.
    enum Status: String, Codable, Sendable { case printed, cancelled, failed, waiting }

    var id: String
    var created: Date
    /// upload (sent with the request), file (a path on this Mac), clipboard or reprint.
    var source: String

    enum Source {
        static let upload = "upload", localFile = "file", clipboard = "clipboard", reprint = "reprint"
    }

    /// For the HTTP API: no local paths, and a generic message for print-system failures.
    var redacted: APIJob {
        var job = self
        job.savedPDF = nil
        if job.error != nil { job.error = "Printing failed." }
        return job
    }
    var status: Status
    var files: [String]
    var printer: String
    var size: String
    var copies: Int
    var labels: Int
    var codesFound: Int
    var codesVerified: Int
    var codesMissing: [String]
    var warnings: [String]
    /// The label-sized PDF that was sent, kept for reprinting.
    var savedPDF: String?
    /// The id `lp` returned.
    var printerJobID: String?
    var error: String?
    /// The rule that matched: its name, or "Everything else". None for reprints.
    var rule: String?
    /// countdown (cancellable in the popover) or review (waits for Print).
    var action: String?
    /// Per label, once composed: ink used, scale, rotation and codes.
    var labelDetails: [APILabelInfo]?
}

struct APILabelInfo: Codable, Sendable, Equatable {
    var index: Int
    /// The ink actually used: crisp or photo (auto picks one per label).
    var ink: String
    /// Source points to label points, in percent.
    var scalePercent: Double
    var rotated: Bool
    var codes: [APICode]
    var warnings: [String]
}

struct APILabelPreview: Codable, Sendable, Equatable {
    var index: Int
    /// Pixels at the printer's resolution.
    var width: Int
    var height: Int
    /// PNG, base64 in HTTP JSON. MCP leaves it out and sends the images as image content.
    var png: Data?
    var ink: String
    var scalePercent: Double
    var rotated: Bool
    var codes: [APICode]
    var warnings: [String]
}

struct APIPreview: Codable, Sendable, Equatable {
    var printer: String
    var size: String
    var rule: String?
    var copies: Int
    /// What printing would do: countdown or review.
    var action: String
    var labels: Int
    var codesFound: Int
    var codesVerified: Int
    var codesMissing: [String]
    var warnings: [String]
    var images: [APILabelPreview]
}

struct APIHealth: Codable, Sendable {
    var status: String
    var version: String
    var http: Bool
    var mcp: Bool
    var port: Int
}


// MARK: Errors

/// An error with an HTTP status and a stable code, for both REST and MCP.
struct APIError: Error, CustomStringConvertible, Sendable {
    var status: Int
    var code: String
    var message: String

    var description: String { message }

    static func badRequest(_ message: String, code: String = "bad_request") -> APIError { .init(status: 400, code: code, message: message) }
    static func notFound(_ message: String, code: String = "not_found") -> APIError { .init(status: 404, code: code, message: message) }
    static func unprocessable(_ message: String, code: String = "unprocessable") -> APIError { .init(status: 422, code: code, message: message) }
    static func failed(_ message: String, code: String = "print_failed") -> APIError { .init(status: 500, code: code, message: message) }
}

struct APIErrorBody: Codable, Sendable {
    struct Detail: Codable, Sendable {
        var code: String
        var message: String
    }
    var error: Detail
}
