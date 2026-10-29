import Foundation

/// A minimal multipart/form-data parser: enough for file uploads and text fields.
struct Multipart {
    struct Part {
        var name: String
        var filename: String?
        var contentType: String?
        var data: Data

        var text: String { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    var parts: [Part]

    /// The boundary from a `multipart/form-data; boundary=…` content type.
    static func boundary(from contentType: String) -> String? {
        guard contentType.lowercased().hasPrefix("multipart/form-data") else { return nil }
        for param in contentType.split(separator: ";").dropFirst() {
            let kv = param.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0].lowercased() == "boundary" {
                return kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    init(parts: [Part]) { self.parts = parts }

    init(data: Data, boundary: String) throws {
        let delimiter = Data("--\(boundary)".utf8)
        let headerEnd = Data("\r\n\r\n".utf8)
        var parts: [Part] = []
        guard var cursor = data.range(of: delimiter)?.upperBound else { throw APIError.badRequest("Malformed multipart body.", code: "bad_multipart") }
        while true {
            // After a delimiter: "--" ends the body, CRLF starts a part.
            let rest = data[cursor...]
            if rest.starts(with: Data("--".utf8)) { break }
            guard rest.starts(with: Data("\r\n".utf8)) else { throw APIError.badRequest("Malformed multipart body.", code: "bad_multipart") }
            let start = cursor + 2
            guard let headerRange = data.range(of: headerEnd, in: start..<data.endIndex),
                  let next = data.range(of: Data("\r\n".utf8) + delimiter, in: headerRange.upperBound..<data.endIndex) else {
                throw APIError.badRequest("Malformed multipart body.", code: "bad_multipart")
            }
            let headers = String(decoding: data[start..<headerRange.lowerBound], as: UTF8.self)
            var part = Part(name: "", filename: nil, contentType: nil, data: Data(data[headerRange.upperBound..<next.lowerBound]))
            for line in headers.components(separatedBy: "\r\n") {
                let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2 else { continue }
                switch kv[0].lowercased() {
                case "content-disposition":
                    part.name = Self.param("name", in: kv[1]) ?? ""
                    part.filename = Self.param("filename", in: kv[1])
                case "content-type":
                    part.contentType = kv[1]
                default: break
                }
            }
            parts.append(part)
            cursor = next.upperBound
        }
        self.parts = parts
    }

    private static func param(_ key: String, in header: String) -> String? {
        for item in header.split(separator: ";").dropFirst() {
            let kv = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0].lowercased() == key {
                return kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    func field(_ name: String) -> String? {
        parts.first { $0.name == name && $0.filename == nil }?.text
    }

    var files: [Part] { parts.filter { $0.filename != nil || $0.name == "file" || $0.name == "file[]" } }
}
