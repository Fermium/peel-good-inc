import Foundation

/// A Finder tag, written with its colour so "Printed" can be green. `apply(to:)` is the only tag writer.
public struct FinderTag: Codable, Hashable, Sendable {
    public var name = "Printed"
    public var color: Color = .green

    public init(name: String = "Printed", color: Color = .green) {
        self.name = name
        self.color = color
    }

    enum CodingKeys: String, CodingKey { case name, color }

    /// Either field may be left out.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Printed"
        color = try c.decodeIfPresent(Color.self, forKey: .color) ?? .green
    }

    /// Finder's label numbers.
    public enum Color: Int, Codable, CaseIterable, Sendable {
        case none = 0, gray, green, purple, blue, yellow, red, orange
        public var title: String { "\(self)".capitalized }
        /// "green", as the API and MCP spell it.
        public var name: String { "\(self)" }
    }

    /// Adds the tag, keeping the file's other tags (one with the same name is replaced, so its colour updates).
    /// Files that are gone or read-only are left alone.
    public func apply(to url: URL) {
        let key = "com.apple.metadata:_kMDItemUserTags"
        var tags: [String] = []
        let size = getxattr(url.path, key, nil, 0, 0, 0)
        if size > 0 {
            var data = Data(count: size)
            _ = data.withUnsafeMutableBytes { getxattr(url.path, key, $0.baseAddress, size, 0, 0) }
            tags = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] ?? []
        }
        tags.removeAll { $0.split(separator: "\n").first.map(String.init) == name }
        tags.append(color == .none ? name : "\(name)\n\(color.rawValue)")
        guard let data = try? PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0) else { return }
        _ = data.withUnsafeBytes { setxattr(url.path, key, $0.baseAddress, data.count, 0, 0) }
    }

    /// The tags on a file, as Finder shows them (names only).
    public static func names(on url: URL) -> [String] {
        let key = "com.apple.metadata:_kMDItemUserTags"
        let size = getxattr(url.path, key, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        _ = data.withUnsafeMutableBytes { getxattr(url.path, key, $0.baseAddress, size, 0, 0) }
        let tags = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] ?? []
        return tags.compactMap { $0.split(separator: "\n").first.map(String.init) }
    }
}

/// A rule's Finder tag.
///
/// General > After Printing > Add Finder tag switches tagging on or off for every print. When it's on:
/// - `general` (Default, and always for Everything else) adds General's tag;
/// - `none` adds no tag;
/// - `custom` adds the rule's own tag instead of General's.
/// When it's off, nothing is tagged. Only files the user owns are tagged (`AfterPrint.isUserFile`).
///
/// JSON: "default", "none", or {"name": …, "color": …}. A rule file from before tag modes has no tag
/// (read as none) or a tag object (read as custom), so older rules keep doing what they did.
public enum RuleTag: Codable, Hashable, Sendable {
    case general
    case none
    case custom(FinderTag)

    public var custom: FinderTag? {
        if case .custom(let t) = self { return t }
        return nil
    }

    /// The tag a print gets, or nil for none.
    public func resolve(generalOn: Bool, general: FinderTag) -> FinderTag? {
        guard generalOn else { return nil }
        let tag: FinderTag? = switch self {
        case .general: general
        case .none: nil
        case .custom(let t): t
        }
        guard let tag, !tag.name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return tag
    }

    public func resolve(_ settings: AppSettings) -> FinderTag? {
        resolve(generalOn: settings.tagAfterPrint, general: settings.generalTag)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .none; return }
        if let s = try? c.decode(String.self) {
            switch s {
            case "default", "general": self = .general
            case "none": self = .none
            default: throw DecodingError.dataCorruptedError(in: c, debugDescription: "tag must be \"default\", \"none\" or {name, color}")
            }
            return
        }
        self = .custom(try c.decode(FinderTag.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .general: try c.encode("default")
        case .none: try c.encode("none")
        case .custom(let t): try c.encode(t)
        }
    }
}
