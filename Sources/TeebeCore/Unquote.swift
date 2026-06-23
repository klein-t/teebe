import Foundation

/// Decodes git's C-style path quoting. When a path contains special characters
/// (spaces aside), git wraps it in double quotes and escapes bytes as `\t`, `\n`,
/// `\"`, `\\`, or octal `\NNN` (UTF-8 bytes). With `core.quotepath=false` most
/// non-ASCII stays literal, but control characters are still quoted.
enum Unquote {
    static func cQuoted(_ string: String) -> String {
        guard string.count >= 2, string.hasPrefix("\""), string.hasSuffix("\"") else { return string }
        let chars = Array(string.dropFirst().dropLast())
        var bytes: [UInt8] = []
        var index = 0

        func appendUTF8(_ character: Character) { bytes.append(contentsOf: Array(String(character).utf8)) }
        func isOctal(_ c: Character) -> Bool { c >= "0" && c <= "7" }

        while index < chars.count {
            let c = chars[index]
            guard c == "\\", index + 1 < chars.count else {
                appendUTF8(c)
                index += 1
                continue
            }
            let next = chars[index + 1]
            switch next {
            case "n": bytes.append(0x0A); index += 2
            case "t": bytes.append(0x09); index += 2
            case "r": bytes.append(0x0D); index += 2
            case "\"": bytes.append(0x22); index += 2
            case "\\": bytes.append(0x5C); index += 2
            case "a": bytes.append(0x07); index += 2
            case "b": bytes.append(0x08); index += 2
            case "f": bytes.append(0x0C); index += 2
            case "v": bytes.append(0x0B); index += 2
            default:
                if isOctal(next) {
                    var j = index + 1
                    var octal = ""
                    while j < chars.count, octal.count < 3, isOctal(chars[j]) {
                        octal.append(chars[j]); j += 1
                    }
                    if let value = UInt8(octal, radix: 8) { bytes.append(value) }
                    index = j
                } else {
                    appendUTF8(c)
                    index += 1
                }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
