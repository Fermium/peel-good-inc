import Foundation

// The Internet Printing Protocol's binary message format (RFC 8010), as much as a printer that
// takes PDF jobs from CUPS needs. Structure follows fake_printer (Apache-2.0, BirjuVachhani/fake_printer).

enum IPPValue: Equatable, Sendable {
    case integer(Int32)
    case boolean(Bool)
    case enumeration(Int32)
    case range(Int32, Int32)
    case resolution(Int32, Int32)
    case text(String)
    case name(String)
    case keyword(String)
    case uri(String)
    case charset(String)
    case language(String)
    case mimeType(String)
    case collection([IPPAttribute])
    case noValue
    case other(tag: UInt8, bytes: [UInt8])

    /// The value as a string, for text-like values.
    var string: String? {
        switch self {
        case .text(let s), .name(let s), .keyword(let s), .uri(let s), .charset(let s), .language(let s), .mimeType(let s): s
        default: nil
        }
    }

    var int: Int? {
        switch self {
        case .integer(let v), .enumeration(let v): Int(v)
        default: nil
        }
    }
}

struct IPPAttribute: Equatable, Sendable {
    var name: String
    var values: [IPPValue]

    init(_ name: String, _ values: [IPPValue]) {
        self.name = name
        self.values = values
    }

    init(_ name: String, _ value: IPPValue) { self.init(name, [value]) }
}

struct IPPGroup: Equatable, Sendable {
    var tag: UInt8
    var attributes: [IPPAttribute]

    subscript(name: String) -> IPPAttribute? { attributes.first { $0.name == name } }
}

struct IPPMessage: Equatable, Sendable {
    var version: (UInt8, UInt8) = (2, 0)
    /// The operation (requests) or status (responses).
    var code: UInt16
    var requestID: UInt32
    var groups: [IPPGroup] = []
    /// The document, for Print-Job.
    var data = Data()

    static func == (a: IPPMessage, b: IPPMessage) -> Bool {
        a.version == b.version && a.code == b.code && a.requestID == b.requestID && a.groups == b.groups && a.data == b.data
    }

    /// The first attribute with this name in any group.
    func attribute(_ name: String) -> IPPAttribute? {
        groups.lazy.compactMap { $0[name] }.first
    }

    func string(_ name: String) -> String? { attribute(name)?.values.first?.string }
    func int(_ name: String) -> Int? { attribute(name)?.values.first?.int }
}

enum IPPTag {
    static let operation: UInt8 = 0x01, job: UInt8 = 0x02, end: UInt8 = 0x03, printer: UInt8 = 0x04, unsupported: UInt8 = 0x05
    static let noValue: UInt8 = 0x13
    static let integer: UInt8 = 0x21, boolean: UInt8 = 0x22, enumeration: UInt8 = 0x23
    static let dateTime: UInt8 = 0x31, resolution: UInt8 = 0x32, range: UInt8 = 0x33
    static let beginCollection: UInt8 = 0x34, textWithLanguage: UInt8 = 0x35, nameWithLanguage: UInt8 = 0x36, endCollection: UInt8 = 0x37
    static let text: UInt8 = 0x41, name: UInt8 = 0x42, keyword: UInt8 = 0x44, uri: UInt8 = 0x45
    static let charset: UInt8 = 0x47, language: UInt8 = 0x48, mimeType: UInt8 = 0x49, memberName: UInt8 = 0x4A
}

enum IPPCodec {
    struct Truncated: Error {}

    // MARK: Encoding

    static func encode(_ m: IPPMessage) -> Data {
        var out = Data([m.version.0, m.version.1])
        out.append16(m.code)
        out.append32(m.requestID)
        for group in m.groups {
            out.append(group.tag)
            for attribute in group.attributes {
                for (i, value) in attribute.values.enumerated() { encode(value, name: i == 0 ? attribute.name : "", into: &out) }
            }
        }
        out.append(IPPTag.end)
        out.append(m.data)
        return out
    }

    private static func encode(_ value: IPPValue, name: String, into out: inout Data) {
        out.append(tag(of: value))
        out.appendString(name)
        if case .collection(let members) = value {
            out.append16(0)
            for member in members {
                out.append(IPPTag.memberName)
                out.append16(0)
                out.appendString(member.name)
                for v in member.values { encode(v, name: "", into: &out) }
            }
            out.append(IPPTag.endCollection)
            out.append16(0)
            out.append16(0)
            return
        }
        let bytes = payload(of: value)
        out.append16(UInt16(bytes.count))
        out.append(contentsOf: bytes)
    }

    private static func tag(of value: IPPValue) -> UInt8 {
        switch value {
        case .integer: IPPTag.integer
        case .boolean: IPPTag.boolean
        case .enumeration: IPPTag.enumeration
        case .range: IPPTag.range
        case .resolution: IPPTag.resolution
        case .text: IPPTag.text
        case .name: IPPTag.name
        case .keyword: IPPTag.keyword
        case .uri: IPPTag.uri
        case .charset: IPPTag.charset
        case .language: IPPTag.language
        case .mimeType: IPPTag.mimeType
        case .collection: IPPTag.beginCollection
        case .noValue: IPPTag.noValue
        case .other(let tag, _): tag
        }
    }

    private static func payload(of value: IPPValue) -> [UInt8] {
        func be(_ v: Int32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian) { Array($0) } }
        switch value {
        case .integer(let v), .enumeration(let v): return be(v)
        case .boolean(let v): return [v ? 1 : 0]
        case .range(let a, let b): return be(a) + be(b)
        case .resolution(let x, let y): return be(x) + be(y) + [3] // dots per inch
        case .other(_, let bytes): return bytes
        case .collection, .noValue: return []
        default: return Array((value.string ?? "").utf8)
        }
    }

    // MARK: Decoding

    static func decode(_ data: Data) throws -> IPPMessage {
        var r = Reader(bytes: [UInt8](data))
        var m = IPPMessage(code: 0, requestID: 0)
        m.version = (try r.u8(), try r.u8())
        m.code = try r.u16()
        m.requestID = try r.u32()
        var current: IPPGroup?
        while true {
            let tag = try r.u8()
            if tag == IPPTag.end { break }
            if tag < 0x10 {
                if let current { m.groups.append(current) }
                current = IPPGroup(tag: tag, attributes: [])
                continue
            }
            let name = try r.string(Int(try r.u16()))
            let value = try decodeValue(tag: tag, &r, depth: 0)
            if current == nil { current = IPPGroup(tag: IPPTag.operation, attributes: []) }
            if name.isEmpty, let last = current?.attributes.indices.last {
                current?.attributes[last].values.append(value)
            } else {
                current?.attributes.append(IPPAttribute(name, value))
            }
        }
        if let current { m.groups.append(current) }
        m.data = Data(r.rest)
        return m
    }

    /// Collections nest; real ones are 2 or 3 deep. Deeper input is refused instead of exhausting the stack.
    static let maxDepth = 16

    private static func decodeValue(tag: UInt8, _ r: inout Reader, depth: Int) throws -> IPPValue {
        if tag == IPPTag.beginCollection {
            guard depth < maxDepth else { throw Truncated() }
            _ = try r.bytes(Int(try r.u16()))
            return .collection(try decodeMembers(&r, depth: depth + 1))
        }
        let bytes = try r.bytes(Int(try r.u16()))
        func i32(_ o: Int) -> Int32 {
            guard bytes.count >= o + 4 else { return 0 }
            return Int32(bitPattern: UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3]))
        }
        let s = String(decoding: bytes, as: UTF8.self)
        switch tag {
        case IPPTag.integer: return .integer(i32(0))
        case IPPTag.enumeration: return .enumeration(i32(0))
        case IPPTag.boolean: return .boolean(bytes.first ?? 0 != 0)
        case IPPTag.range: return .range(i32(0), i32(4))
        case IPPTag.resolution: return .resolution(i32(0), i32(4))
        case IPPTag.text: return .text(s)
        case IPPTag.name: return .name(s)
        case IPPTag.keyword: return .keyword(s)
        case IPPTag.uri: return .uri(s)
        case IPPTag.charset: return .charset(s)
        case IPPTag.language: return .language(s)
        case IPPTag.mimeType: return .mimeType(s)
        case IPPTag.textWithLanguage, IPPTag.nameWithLanguage:
            // language length, language, text length, text
            guard bytes.count >= 2 else { return .text("") }
            let start = 2 + (Int(bytes[0]) << 8 | Int(bytes[1])) + 2
            return .text(bytes.count >= start ? String(decoding: bytes[start...], as: UTF8.self) : "")
        case IPPTag.noValue: return .noValue
        default: return .other(tag: tag, bytes: bytes)
        }
    }

    private static func decodeMembers(_ r: inout Reader, depth: Int) throws -> [IPPAttribute] {
        var members: [IPPAttribute] = []
        var name: String?
        while true {
            let tag = try r.u8()
            _ = try r.bytes(Int(try r.u16()))
            if tag == IPPTag.endCollection {
                _ = try r.bytes(Int(try r.u16()))
                return members
            }
            if tag == IPPTag.memberName {
                name = try r.string(Int(try r.u16()))
                continue
            }
            let value = try decodeValue(tag: tag, &r, depth: depth)
            guard let name else { continue }
            if members.last?.name == name { members[members.count - 1].values.append(value) } else { members.append(IPPAttribute(name, value)) }
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var at = 0
        mutating func u8() throws -> UInt8 { try bytes(1)[0] }
        mutating func u16() throws -> UInt16 { let b = try bytes(2); return UInt16(b[0]) << 8 | UInt16(b[1]) }
        mutating func u32() throws -> UInt32 { let b = try bytes(4); return b.reduce(0) { $0 << 8 | UInt32($1) } }
        mutating func string(_ n: Int) throws -> String { String(decoding: try bytes(n), as: UTF8.self) }
        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard n >= 0, at + n <= bytes.count else { throw Truncated() }
            defer { at += n }
            return Array(bytes[at..<at + n])
        }
        var rest: ArraySlice<UInt8> { bytes[min(at, bytes.count)...] }
    }
}

private extension Data {
    mutating func append16(_ v: UInt16) { append(contentsOf: [UInt8(v >> 8), UInt8(v & 0xFF)]) }
    mutating func append32(_ v: UInt32) { append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
    mutating func appendString(_ s: String) {
        let b = Array(s.utf8)
        append16(UInt16(b.count))
        append(contentsOf: b)
    }
}
