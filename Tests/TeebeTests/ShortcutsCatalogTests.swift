import Testing
@testable import Teebe

@Suite("ShortcutsCatalog")
struct ShortcutsCatalogTests {
    @Test("has the expected groups in order")
    func groupTitles() {
        let titles = ShortcutsCatalog.groups.map(\.title)
        #expect(titles == ["Sections", "Navigate", "Select files", "Files actions", "Search"])
    }

    @Test("every row has non-empty keys and an action")
    func rowsAreWellFormed() {
        let items = ShortcutsCatalog.groups.flatMap(\.items)
        #expect(!items.isEmpty)
        for item in items {
            #expect(!item.keys.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!item.action.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @Test("row identifiers are unique")
    func idsAreUnique() {
        let ids = ShortcutsCatalog.groups.flatMap(\.items).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("documents the headline shortcuts")
    func coversKeyShortcuts() {
        let keys = ShortcutsCatalog.groups.flatMap(\.items).map(\.keys)
        // Spot-check that the marquee bindings are listed so the sheet can't silently
        // drift from RootView/FilesSection.
        #expect(keys.contains { $0.contains("⌘⇧C") })   // copy @-refs
        #expect(keys.contains { $0.contains("⌘⌫") })    // trash
        #expect(keys.contains { $0.contains("⌘F") })    // search
        #expect(keys.contains { $0.contains("⌘1") })    // section focus
    }
}
