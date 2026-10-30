import Foundation

/// JSON with ordered object keys, so the OpenAPI document reads top to bottom the way it's written.
indirect enum JSONValue: Equatable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([(String, JSONValue)])

    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(elements) }

    static func == (a: JSONValue, b: JSONValue) -> Bool { a.serialized() == b.serialized() }

    subscript(key: String) -> JSONValue? {
        if case .object(let pairs) = self { return pairs.first { $0.0 == key }?.1 }
        return nil
    }

    var stringValue: String? { if case .string(let s) = self { s } else { nil } }

    /// Parses JSON (key order follows the text).
    init(parsing data: Data) throws {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        self = Self(any: any)
    }

    private init(any: Any) {
        switch any {
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(Self.init(any:)))
        case let d as [String: Any]: self = .object(d.keys.sorted().map { ($0, Self(any: d[$0]!)) })
        default: self = .null
        }
    }

    /// An encodable value as JSON (ISO 8601 dates, base64 data, sorted keys).
    static func encoding<T: Encodable>(_ value: T) -> JSONValue {
        let data = (try? APIJSON.encoder.encode(value)) ?? Data("null".utf8)
        return (try? JSONValue(parsing: data)) ?? .null
    }

    func serialized(pretty: Bool = true) -> String {
        var out = ""
        write(to: &out, indent: pretty ? 0 : nil)
        return out
    }

    private func write(to out: inout String, indent: Int?) {
        let nl = indent == nil ? "" : "\n"
        let pad = { (n: Int) in String(repeating: "  ", count: n) }
        switch self {
        case .string(let s): out += Self.quote(s)
        case .number(let n):
            out += n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): out += b ? "true" : "false"
        case .null: out += "null"
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[" + nl
            for (i, item) in items.enumerated() {
                if let indent { out += pad(indent + 1) }
                item.write(to: &out, indent: indent.map { $0 + 1 })
                out += (i < items.count - 1 ? "," : "") + nl
            }
            if let indent { out += pad(indent) }
            out += "]"
        case .object(let pairs):
            if pairs.isEmpty { out += "{}"; return }
            out += "{" + nl
            for (i, (key, value)) in pairs.enumerated() {
                if let indent { out += pad(indent + 1) }
                out += Self.quote(key) + (indent == nil ? ":" : ": ")
                value.write(to: &out, indent: indent.map { $0 + 1 })
                out += (i < pairs.count - 1 ? "," : "") + nl
            }
            if let indent { out += pad(indent) }
            out += "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

/// The encoder every API response uses.
enum APIJSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}
