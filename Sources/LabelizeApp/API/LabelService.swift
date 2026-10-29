import Foundation
import LabelizeCore

/// What the HTTP API and the MCP server can ask the app to do. The API layer only talks to this.
/// `AppLabelService` is the real implementation; `MockLabelService` never prints.
@MainActor
protocol LabelService: AnyObject {
    func printers() -> [APIPrinter]
    /// Sizes for a printer, by queue name or display name.
    func sizes(printer: String) throws -> [APISize]
    /// Prints every page of every file. `request.path` is ignored here; the caller resolves files.
    /// `source` is an `APIJob.Source`. Only the user's own files (`AfterPrint.isUserFile`: not uploads,
    /// the clipboard or History) get the after-print tag or move, which in practice means `localFile` jobs.
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

/// Options for print and preview. Everything is optional; missing values use the printer's settings
/// (or the matching rule's). An empty or blank value counts as missing (`given`).
struct APIPrintRequest: Codable, Sendable, Equatable {
    /// Absolute path to a PDF, SVG or image on this Mac. MCP only, with permission; the HTTP API refuses it.
    var path: String?
    var printer: String?
    var size: String?
    /// fit or fill.
    var fit: String?
    /// auto, crisp, photo or halftone.
    var ink: String?
    var copies: Int?

    init(path: String? = nil, printer: String? = nil, size: String? = nil, fit: String? = nil, ink: String? = nil, copies: Int? = nil) {
        self.path = Self.given(path)
        self.printer = Self.given(printer)
        self.size = Self.given(size)
        self.fit = Self.given(fit)
        self.ink = Self.given(ink)
        self.copies = copies
    }

    /// The text, or nil when it's empty or only spaces: "printer": "" means the default, as leaving it out does.
    static func given(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Every text value through `given`.
    var normalized: APIPrintRequest { APIPrintRequest(path: path, printer: printer, size: size, fit: fit, ink: ink, copies: copies) }
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
    /// The ink actually used: crisp, photo or halftone (auto picks crisp or photo per label).
    var ink: String
    /// Source points to label points, in percent.
    var scalePercent: Double
    var rotated: Bool
    var codes: [APICode]
    var warnings: [String]
}

/// A label's `APILabelInfo` plus its image. Encodes flat: the info's fields, then width, height and png.
struct APILabelPreview: Codable, Sendable, Equatable {
    var info: APILabelInfo
    /// Pixels at the printer's resolution.
    var width: Int
    var height: Int
    /// PNG, base64 in HTTP JSON. MCP leaves it out and sends the images as image content.
    var png: Data?

    init(_ info: APILabelInfo, width: Int, height: Int, png: Data?) {
        self.info = info
        self.width = width
        self.height = height
        self.png = png
    }

    private enum CodingKeys: String, CodingKey { case width, height, png }

    init(from decoder: Decoder) throws {
        info = try APILabelInfo(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        png = try c.decodeIfPresent(Data.self, forKey: .png)
    }

    func encode(to encoder: Encoder) throws {
        try info.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encodeIfPresent(png, forKey: .png)
    }
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

extension APIError {
    /// A rejected option: 422 when the printer can't do it, else 400.
    init(_ e: OptionError) {
        self.init(status: e.isUnsupported ? 422 : 400, code: e.code, message: e.message)
    }
}

extension APIPrintRequest {
    /// The size, fit and ink asked for, checked when applied.
    var overrides: OptionOverrides { OptionOverrides(size: size, fit: fit, ink: ink) }
}

struct APIErrorBody: Codable, Sendable {
    struct Detail: Codable, Sendable {
        var code: String
        var message: String
    }
    var error: Detail
}
