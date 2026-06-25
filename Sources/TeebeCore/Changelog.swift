import Foundation

/// One version's worth of a parsed changelog: a version label, an optional date,
/// and its grouped bullet items. Pure value types so the parser is fully testable
/// without any UI.
public struct ChangelogEntry: Equatable, Sendable, Identifiable {
    /// Version label, e.g. `"0.3.0"` or `"Unreleased"`.
    public var version: String
    /// Raw date string from the header (e.g. `"2026-06-24"`), when present.
    public var date: String?
    public var groups: [ChangelogGroup]

    public var id: String { version }
    public var isUnreleased: Bool { version.lowercased() == "unreleased" }

    public init(version: String, date: String? = nil, groups: [ChangelogGroup] = []) {
        self.version = version
        self.date = date
        self.groups = groups
    }
}

/// A titled group of bullet items within an entry (e.g. `### Added`). `title` is
/// `nil` for bullets that appear before any `###` subheading.
public struct ChangelogGroup: Equatable, Sendable, Identifiable {
    public var title: String?
    public var items: [String]

    public var id: String { title ?? "—" }

    public init(title: String? = nil, items: [String] = []) {
        self.title = title
        self.items = items
    }
}

/// Parses [Keep a Changelog](https://keepachangelog.com/) markdown into entries.
///
/// Grammar (everything else is ignored): `## [version] - date` starts an entry,
/// `### Group` starts a group, and `- ` / `* ` lines are bullets. Bullet text that
/// wraps onto continuation lines is rejoined. Item text keeps its inline markdown
/// so the view can render emphasis/code.
public enum ChangelogParser {
    public static func parse(_ markdown: String) -> [ChangelogEntry] {
        var entries: [ChangelogEntry] = []
        var groups: [ChangelogGroup] = []
        var currentGroup: ChangelogGroup?
        var version: String?
        var date: String?

        func flushGroup() {
            if let group = currentGroup, !group.items.isEmpty { groups.append(group) }
            currentGroup = nil
        }
        func flushEntry() {
            flushGroup()
            if let version { entries.append(ChangelogEntry(version: version, date: date, groups: groups)) }
            version = nil
            date = nil
            groups = []
        }
        func appendContinuation(_ text: String) {
            guard version != nil, currentGroup != nil,
                  let last = currentGroup?.items.indices.last else { return }
            currentGroup?.items[last] += " " + text
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flushEntry()
                (version, date) = parseHeader(String(line.dropFirst(3)))
            } else if line.hasPrefix("### ") {
                flushGroup()
                let title = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                currentGroup = ChangelogGroup(title: title.isEmpty ? nil : title, items: [])
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                guard version != nil else { continue }
                if currentGroup == nil { currentGroup = ChangelogGroup(title: nil, items: []) }
                currentGroup?.items.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if !line.isEmpty {
                appendContinuation(line)
            }
        }
        flushEntry()
        return entries
    }

    /// Split a `## ` header body into version + optional date. Accepts `[0.3.0] -
    /// 2026-06-24`, `0.3.0 - 2026-06-24`, and `[Unreleased]`.
    private static func parseHeader(_ text: String) -> (String, String?) {
        var version = text
        var date: String?
        if let dash = text.range(of: " - ") {
            version = String(text[..<dash.lowerBound])
            date = String(text[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        version = version.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        return (version, (date?.isEmpty ?? true) ? nil : date)
    }
}

/// Minimal dotted-numeric version comparison — enough to decide "is this build
/// newer than the one we last showed What's New for". Non-numeric segments count
/// as 0, so `"0.10.0" > "0.9.0"` and `"0.3.0" > "0.3"`.
public enum SemVer {
    public static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { segment in
            Int(segment.prefix { $0.isNumber }) ?? 0
        }
    }

    /// `true` when `lhs` is a strictly greater version than `rhs`.
    public static func isGreater(_ lhs: String, than rhs: String) -> Bool {
        let left = components(lhs)
        let right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue != rightValue { return leftValue > rightValue }
        }
        return false
    }
}
