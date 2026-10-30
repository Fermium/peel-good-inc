import CoreGraphics
import Foundation

/// Checks on typed-in settings, shared by Settings (which tidies the value as you type) and MCP
/// (which refuses a bad value with the same rule).
extension Limits {
    public static let renameSuffixLength = 64
    /// Characters a file name can't hold in Finder.
    public static let renameSuffixForbidden: Set<Character> = ["/", ":"]

    /// The suffix as given, or an error: no / or :, at most `renameSuffixLength` characters.
    public static func renameSuffix(_ s: String) throws -> String {
        guard s.count <= renameSuffixLength else {
            throw OptionError(code: "invalid_renameSuffix", message: "renameSuffix can be at most \(renameSuffixLength) characters.")
        }
        guard !s.contains(where: renameSuffixForbidden.contains) else {
            throw OptionError(code: "invalid_renameSuffix", message: "renameSuffix can't contain / or :.")
        }
        return s
    }

    /// The tag name as given, or an error: not blank, at most `tagNameLength` characters.
    public static func tagName(_ s: String) throws -> String {
        guard !s.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw OptionError(code: "invalid_tagName", message: "tagName can't be empty.")
        }
        guard s.count <= tagNameLength else {
            throw OptionError(code: "invalid_tagName", message: "tagName can be at most \(tagNameLength) characters.")
        }
        return s
    }

    /// What Settings saves for a typed suffix: / and : dropped, cut to `renameSuffixLength`.
    public static func tidyRenameSuffix(_ s: String) -> String {
        String(s.filter { !renameSuffixForbidden.contains($0) }.prefix(renameSuffixLength))
    }

    /// What Settings saves for a typed tag name: cut to `tagNameLength`; a blank name keeps `previous`.
    public static func tidyTagName(_ s: String, previous: String) -> String {
        s.trimmingCharacters(in: .whitespaces).isEmpty ? previous : String(s.prefix(tagNameLength))
    }

    /// A value pulled into `range`.
    public static func clamp(_ v: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(v, range.lowerBound), range.upperBound)
    }

    /// A nudge with both axes inside `nudgeMM`.
    public static func clampNudge(_ n: CGPoint) -> CGPoint {
        CGPoint(x: clamp(Double(n.x), nudgeMM), y: clamp(Double(n.y), nudgeMM))
    }
}
