import Foundation
import TeebeCore

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

/// Which agent sections the menu bar dropdown lists. The "Waiting agents" and
/// "Working agents" choices govern the dropdown as they govern the title. Pure.
struct AgentMenuBarSections: Equatable {
    let showsWaiting: Bool
    let showsWorking: Bool
    /// Said when every section shown is empty; nil when a section has rows or
    /// both are switched off (then the dropdown holds only its commands).
    let emptyNote: String?

    init(waiting: Int, working: Int, showsWaiting: Bool, showsWorking: Bool) {
        self.showsWaiting = showsWaiting && waiting > 0
        self.showsWorking = showsWorking && working > 0
        switch (showsWaiting, showsWorking) {
        case (true, true): emptyNote = waiting == 0 && working == 0 ? "No agents waiting or working" : nil
        case (true, false): emptyNote = waiting == 0 ? "No agents waiting" : nil
        case (false, true): emptyNote = working == 0 ? "No agents working" : nil
        case (false, false): emptyNote = nil
        }
    }
}

/// Which orbs of the menu bar title move: a segment that is drawn, while the
/// "Animate icons" choice is on and Reduce Motion is off. Nothing moving means
/// no timer runs. Pure.
enum AgentMenuBarAnimation {
    enum Orb: Hashable {
        case waiting, working

        /// The rows' orb for this kind: waiting breathes, working solves.
        var state: ThinkingOrbState { self == .waiting ? .breathing : .solving }
    }

    static func animated(_ title: AgentMenuBarTitle, animates: Bool, reduceMotion: Bool) -> Set<Orb> {
        guard animates, !reduceMotion else { return [] }
        return Set(title.segments.map { segment in
            switch segment {
            case .waiting: return .waiting
            case .working: return .working
            }
        })
    }
}

extension AgentMenuBarAnimation {
    /// Whether the frame timer runs: something moves and someone can see it.
    static func timerRuns(_ orbs: Set<Orb>, screenAsleep: Bool, sessionLocked: Bool, itemVisible: Bool) -> Bool {
        !orbs.isEmpty && !screenAsleep && !sessionLocked && itemVisible
    }
}
