import Foundation

/// Groups files into the "types" an app choice is remembered for: by extension
/// (`.swift`), dotfiles by their name (`.gitignore`), build files like `Makefile` or
/// `Dockerfile` by their name, and every other file without an extension as one type.
public enum FileTypeKey {
    /// The shared type of files that have no extension and no special name.
    public static let noExtension = ""

    /// The type key for a file name. Case-insensitive.
    public static func key(forFileName name: String) -> String {
        let lower = name.lowercased()
        let isDotfile = lower.hasPrefix(".")
        let stem = isDotfile ? lower.dropFirst() : Substring(lower)
        if let dot = stem.lastIndex(of: "."), dot != stem.startIndex, stem.index(after: dot) != stem.endIndex {
            return String(stem[dot...])
        }
        if isDotfile, !stem.isEmpty { return lower }
        if lower.count > 4, lower.hasSuffix("file") { return lower }
        return noExtension
    }

    /// How a type reads in Settings: `.swift`, `.gitignore`, `Makefile`, `No extension`.
    public static func displayName(forKey key: String) -> String {
        if key == noExtension { return "No extension" }
        if key.hasPrefix(".") { return key }
        return key.prefix(1).uppercased() + key.dropFirst()
    }
}
