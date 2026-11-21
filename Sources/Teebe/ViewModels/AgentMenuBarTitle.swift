import Foundation

/// What the menu bar item draws: the waiting glyph and count, then the working
/// glyph and count, each left out when its count is zero or its option is off.
/// With nothing left it falls back to the neutral teebe glyph, so the item never
/// disappears on its own. Pure, so every combination is testable.
struct AgentMenuBarTitle: Equatable {
    enum Segment: Equatable {
        case waiting(Int)
        case working(Int)
    }

    let segments: [Segment]
    /// What VoiceOver reads: always both counts, whatever is drawn.
    let accessibilityLabel: String

    var isNeutral: Bool { segments.isEmpty }

    init(waiting: Int, working: Int, showsWaiting: Bool, showsWorking: Bool) {
        var segments: [Segment] = []
        if showsWaiting, waiting > 0 { segments.append(.waiting(waiting)) }
        if showsWorking, working > 0 { segments.append(.working(working)) }
        self.segments = segments
        accessibilityLabel = "Teebe: \(waiting) waiting, \(working) working"
    }
}

/// The rule between the Dock icon and the menu bar item: the app always keeps one
/// way in. The Dock icon can be hidden only while the menu bar item shows, and
/// hiding the menu bar item brings the Dock icon back. Pure.
struct AppPresence: Equatable {
    private(set) var showsMenuBarIcon: Bool
    private(set) var showsDockIcon: Bool

    init(showsMenuBarIcon: Bool, showsDockIcon: Bool) {
        self.showsMenuBarIcon = showsMenuBarIcon
        // A saved state can't leave the app with neither.
        self.showsDockIcon = showsDockIcon || !showsMenuBarIcon
    }

    /// Hiding the menu bar item while the Dock icon is hidden shows the Dock icon.
    mutating func setMenuBarIcon(_ shown: Bool) {
        showsMenuBarIcon = shown
        if !shown { showsDockIcon = true }
    }

    /// Hiding the Dock icon is refused while the menu bar item is hidden.
    mutating func setDockIcon(_ shown: Bool) {
        showsDockIcon = shown || !showsMenuBarIcon
    }

    /// Whether the Dock icon toggle can be changed right now.
    var canHideDockIcon: Bool { showsMenuBarIcon }
}
