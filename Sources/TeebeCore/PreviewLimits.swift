import Foundation

/// Bounds memory use and eager SwiftUI diff layout. Plain text uses NSTextView.
public enum PreviewLimits {
    public static let textBytes = 2 * 1024 * 1024
    public static let diffBytes = 256 * 1024
    public static let diffLines = 1000
    public static let lineBytes = 4096

    public static func canRender(_ diff: DiffFile) -> Bool {
        var bytes = 0
        var lines = 0
        for hunk in diff.hunks {
            lines += 1 // Header rows also take layout work.
            bytes += hunk.header.utf8.count
            guard lines <= diffLines, bytes <= diffBytes,
                  hunk.header.utf8.count <= lineBytes else { return false }
            for line in hunk.lines {
                lines += 1
                let count = line.content.utf8.count
                bytes += count
                guard lines <= diffLines, bytes <= diffBytes, count <= lineBytes else { return false }
            }
        }
        return true
    }
}

public enum PreviewTextLoader {
    public enum Result: Equatable, Sendable {
        case text(String)
        case tooLarge
        case unreadable
    }

    /// Call off the UI thread. Read at most the limit plus one byte, including
    /// when the file grows between the metadata check and the read.
    public static func load(_ url: URL) -> Result {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { return .unreadable }
            guard (values.fileSize ?? 0) <= PreviewLimits.textBytes else { return .tooLarge }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: PreviewLimits.textBytes + 1) ?? Data()
            guard data.count <= PreviewLimits.textBytes else { return .tooLarge }
            guard let text = String(data: data, encoding: .utf8) else { return .unreadable }
            return .text(text)
        } catch {
            return .unreadable
        }
    }
}
