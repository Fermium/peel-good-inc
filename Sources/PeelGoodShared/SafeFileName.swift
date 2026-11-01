import Foundation

/// A name from outside, safe as a file name: no separators or control characters, no leading dot,
/// and at most 200 bytes of UTF-8 (file names are limited to 255 bytes, not characters).
public enum SafeFileName {
    public static func make(_ title: String, fileExtension ext: String, fallback: String) -> String {
        var name = String(title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if name.hasPrefix(".") { name = "_" + name }
        for known in [ext, "pdf", "png", "jpg", "jpeg"] where name.lowercased().hasSuffix(".\(known)") {
            name = String(name.dropLast(known.count + 1))
            break
        }
        var short = ""
        for c in name where short.utf8.count + String(c).utf8.count <= 200 { short.append(c) }
        return "\(short.isEmpty ? fallback : short).\(ext)"
    }
}
