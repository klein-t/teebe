import Testing
import Foundation
@testable import TeebeCore

@Suite("ChangelogParser")
struct ChangelogParserTests {
    private let sample = """
    # Changelog

    Intro paragraph that should be ignored.

    ## [Unreleased]

    ### Added
    - A brand new thing.

    ## [0.3.0] - 2026-06-24

    ### Changed
    - Window resizing reworked into a coherent model — no more bounce on a
      window drag.

    ### Fixed
    - Dock icon rendering.
    - Updater start-up.

    ## [0.2.0] - 2026-06-23

    - An ungrouped bullet before any subheading.
    """

    @Test("parses entries newest-first with versions and dates")
    func entriesAndDates() {
        let entries = ChangelogParser.parse(sample)
        #expect(entries.map(\.version) == ["Unreleased", "0.3.0", "0.2.0"])
        #expect(entries[0].isUnreleased)
        #expect(entries[1].date == "2026-06-24")
        #expect(entries[0].date == nil)
    }

    @Test("groups bullets under their ### subheadings")
    func groups() {
        let entries = ChangelogParser.parse(sample)
        let v030 = entries[1]
        #expect(v030.groups.map(\.title) == ["Changed", "Fixed"])
        #expect(v030.groups[1].items == ["Dock icon rendering.", "Updater start-up."])
    }

    @Test("rejoins a bullet that wraps across lines")
    func wrappedBullet() {
        let entries = ChangelogParser.parse(sample)
        let changed = entries[1].groups[0].items
        #expect(changed == ["Window resizing reworked into a coherent model — no more bounce on a window drag."])
    }

    @Test("bullets before any subheading land in an untitled group")
    func ungroupedBullets() {
        let entries = ChangelogParser.parse(sample)
        let v020 = entries[2]
        #expect(v020.groups.count == 1)
        #expect(v020.groups[0].title == nil)
        #expect(v020.groups[0].items == ["An ungrouped bullet before any subheading."])
    }

    @Test("empty input yields no entries")
    func empty() {
        #expect(ChangelogParser.parse("").isEmpty)
        #expect(ChangelogParser.parse("# Changelog\n\nNothing here yet.").isEmpty)
    }
}

@Suite("SemVer")
struct SemVerTests {
    @Test("compares dotted numeric versions")
    func compare() {
        #expect(SemVer.isGreater("0.3.0", than: "0.2.2"))
        #expect(SemVer.isGreater("0.10.0", than: "0.9.0"))   // numeric, not lexicographic
        #expect(SemVer.isGreater("1.0.0", than: "0.99.99"))
        #expect(SemVer.isGreater("0.3.1", than: "0.3"))      // 0.3.1 > 0.3.0
    }

    @Test("equal or lower versions are not greater")
    func notGreater() {
        #expect(!SemVer.isGreater("0.3.0", than: "0.3.0"))
        #expect(!SemVer.isGreater("0.2.0", than: "0.3.0"))
        #expect(!SemVer.isGreater("0.3", than: "0.3.0"))     // trailing zero == equal
        #expect(!SemVer.isGreater("0.3.0", than: "0.3"))
    }
}
