import AppKit
import Foundation
import Testing
@testable import Teebe
@testable import TeebeCore

@Suite("Agent menu bar counts")
@MainActor
struct AgentOverviewTests {
    func entry(_ name: String, repo: String, _ state: AgentActivityState) -> AgentOverviewModel.Entry {
        AgentOverviewModel.Entry(repoPath: "/r/\(repo)", repoTitle: repo, worktreePath: "/r/\(repo)/\(name)", name: name,
                                 state: state, context: nil)
    }

    @Test("counts waiting and working across repositories; idle counts for nothing")
    func counts() {
        let summary = AgentOverviewModel.summarize([
            entry("feat/b", repo: "web", .needsAttention), entry("main", repo: "web", .idle),
            entry("fix/a", repo: "api", .working), entry("feat/a", repo: "web", .needsAttention),
            entry("feat/z", repo: "api", .needsAttention)
        ])
        #expect(summary.waiting.map(\.name) == ["feat/z", "feat/a", "feat/b"])
        #expect(summary.working.map(\.name) == ["fix/a"])
    }
}

@Suite("Worktree agent lines")
struct WorktreeAgentLinesTests {
    let waiting = AgentContext(state: .needsAttention, firstPrompt: "First", latestPrompt: "Latest", waitingReason: "Proceed?")

    @Test("a waiting row shows the task and the question; options turn each off")
    func options() {
        let all = WorktreeAgentLines(context: waiting, mark: .waiting, options: AgentDisplayOptions())
        #expect(all == WorktreeAgentLines(task: "First", question: "Proceed?"))
        #expect(all.count == 2)
        let latest = AgentDisplayOptions(showsQuestion: false, showsTask: true, taskSource: .latest)
        #expect(WorktreeAgentLines(context: waiting, mark: .waiting, options: latest) == WorktreeAgentLines(task: "Latest", question: nil))
        let none = AgentDisplayOptions(showsQuestion: false, showsTask: false)
        #expect(WorktreeAgentLines(context: waiting, mark: .waiting, options: none) == .none)
    }

    @Test("only the waiting mark shows a question; a missing prompt falls back to the other one")
    func fallbacks() {
        #expect(WorktreeAgentLines(context: waiting, mark: .working, options: AgentDisplayOptions()).question == nil)
        let onlyLatest = AgentContext(state: .working, latestPrompt: "Latest")
        #expect(WorktreeAgentLines(context: onlyLatest, mark: .working, options: AgentDisplayOptions()).task == "Latest")
        #expect(WorktreeAgentLines(context: nil, mark: .waiting, options: AgentDisplayOptions()) == .none)
    }

    @Test("the waiting card says what the agent asks, or the generic sentence without it")
    func card() {
        let worktree = Worktree(path: "/feature", branch: "feature", head: "abc")
        var info = SelectorModel.WorktreeInfo()
        info.agentState = .needsAttention
        info.agentContext = waiting
        let status = WorktreeStatus(worktree: worktree, merge: nil, info: info, targetNames: [], isChecking: false)
        #expect(status.card.title == "Waiting for you")
        #expect(status.card.subtitle == "Proceed?")
        let off = WorktreeStatus(worktree: worktree, merge: nil, info: info, targetNames: [], isChecking: false,
                                 agentDisplay: AgentDisplayOptions(showsQuestion: false))
        #expect(off.card.subtitle == "An agent is waiting for your input.")
        info.agentContext = nil
        let unknown = WorktreeStatus(worktree: worktree, merge: nil, info: info, targetNames: [], isChecking: false)
        #expect(unknown.card.subtitle == "An agent is waiting for your input.")
    }

    @Test("the list grows by each agent line and one bottom inset; one-line rows keep their height")
    func listHeight() {
        let worktree = Worktree(path: "/feature", branch: "feature", head: "abc")
        var info = SelectorModel.WorktreeInfo()
        info.agentState = .needsAttention
        info.agentContext = waiting
        let status = WorktreeStatus(worktree: worktree, merge: nil, info: info, targetNames: [], isChecking: false)
        let plain = WorktreeListPresentation(worktrees: [worktree], statuses: [:], grouped: false, collapsed: [], hasRepository: true)
        let lined = WorktreeListPresentation(worktrees: [worktree], statuses: [worktree.path: status], grouped: false,
                                             collapsed: [], hasRepository: true)
        #expect(lined.naturalHeight - plain.naturalHeight
                == 2 * WorktreeListPresentation.agentLineHeight + WorktreeListPresentation.agentLinesBottomInset)
        #expect(WorktreeListPresentation.rowHeight(agentLines: 0) == WorktreeListPresentation.rowHeight)
        #expect(WorktreeListPresentation.rowHeight(agentLines: 2) == WorktreeListPresentation.rowHeight + 36)
    }
}

@Suite("Menu bar title and app presence")
@MainActor
struct AgentMenuBarTitleTests {
    @Test("waiting first, then working; a zero count or an option off leaves its segment out")
    func segments() {
        #expect(AgentMenuBarTitle(waiting: 3, working: 2, showsWaiting: true, showsWorking: true).segments
                == [.waiting(3), .working(2)])
        #expect(AgentMenuBarTitle(waiting: 3, working: 0, showsWaiting: true, showsWorking: true).segments == [.waiting(3)])
        #expect(AgentMenuBarTitle(waiting: 0, working: 2, showsWaiting: true, showsWorking: true).segments == [.working(2)])
        #expect(AgentMenuBarTitle(waiting: 3, working: 2, showsWaiting: false, showsWorking: true).segments == [.working(2)])
        #expect(AgentMenuBarTitle(waiting: 3, working: 2, showsWaiting: true, showsWorking: false).segments == [.waiting(3)])
    }

    @Test("nothing to show falls back to the neutral glyph; VoiceOver still hears both counts")
    func neutral() {
        let idle = AgentMenuBarTitle(waiting: 0, working: 0, showsWaiting: true, showsWorking: true)
        #expect(idle.isNeutral)
        let off = AgentMenuBarTitle(waiting: 3, working: 2, showsWaiting: false, showsWorking: false)
        #expect(off.isNeutral)
        #expect(off.accessibilityLabel == "Teebe: 3 waiting, 2 working")
    }

    @Test("the Dock icon hides only while the menu bar item shows, and comes back when it hides")
    func presenceRule() {
        var presence = AppPresence(showsMenuBarIcon: true, showsDockIcon: true)
        presence.setDockIcon(false)
        #expect(!presence.showsDockIcon)
        presence.setMenuBarIcon(false)
        #expect(presence.showsDockIcon)
        #expect(!presence.canHideDockIcon)
        presence.setDockIcon(false)
        #expect(presence.showsDockIcon)
        // A saved state with neither is read as Dock on.
        #expect(AppPresence(showsMenuBarIcon: false, showsDockIcon: false).showsDockIcon)
    }

    @Test("the choices round-trip through the saved state, and hiding the menu bar item restores the Dock")
    func persistence() {
        let prefs = AgentDisplayPreferences(state: AppState())
        var dockCalls: [Bool] = []
        prefs.onDockIconChange = { dockCalls.append($0) }
        prefs.showsDockIcon = false
        prefs.showsWorkingAgents = false
        var state = AppState()
        prefs.write(to: &state)
        #expect(state.showDockIcon == false && state.agentMenuBarWorking == false && state.agentMenuBarWaiting == true)
        let reloaded = AgentDisplayPreferences(state: state)
        #expect(!reloaded.showsDockIcon && !reloaded.showsWorkingAgents && reloaded.showsWaitingAgents)
        prefs.showsMenuBarIcon = false
        #expect(prefs.showsDockIcon)
        #expect(dockCalls == [false, true])
        prefs.write(to: &state)
        #expect(state.showDockIcon == true && state.agentMenuBarIcon == false)
    }

    @Test("saved state from before these options decodes with everything on")
    func migration() throws {
        let old = #"{"repositories":[],"showChangedOnly":false,"showIgnored":false,"floatOnTop":false,"agentMenuBarIcon":true}"#
        let state = try JSONDecoder().decode(AppState.self, from: Data(old.utf8))
        let prefs = AgentDisplayPreferences(state: state)
        #expect(prefs.showsWaitingAgents && prefs.showsWorkingAgents && prefs.showsDockIcon && prefs.showsMenuBarIcon && prefs.animatesMenuBarIcons)
    }
}

@Suite("Menu bar dropdown sections and motion")
@MainActor
struct AgentMenuBarSectionsTests {
    @Test("each kind is listed only when its choice is on and it has agents")
    func sections() {
        let both = AgentMenuBarSections(waiting: 2, working: 1, showsWaiting: true, showsWorking: true)
        #expect(both.showsWaiting && both.showsWorking && both.emptyNote == nil)
        let waitingOnly = AgentMenuBarSections(waiting: 2, working: 1, showsWaiting: true, showsWorking: false)
        #expect(waitingOnly.showsWaiting && !waitingOnly.showsWorking && waitingOnly.emptyNote == nil)
        let workingOnly = AgentMenuBarSections(waiting: 2, working: 1, showsWaiting: false, showsWorking: true)
        #expect(!workingOnly.showsWaiting && workingOnly.showsWorking && workingOnly.emptyNote == nil)
        let neither = AgentMenuBarSections(waiting: 2, working: 1, showsWaiting: false, showsWorking: false)
        #expect(!neither.showsWaiting && !neither.showsWorking && neither.emptyNote == nil)
    }

    @Test("without sessions a shown kind says it is empty; both off says nothing")
    func empty() {
        #expect(AgentMenuBarSections(waiting: 0, working: 0, showsWaiting: true, showsWorking: true).emptyNote
                == "No agents waiting or working")
        #expect(AgentMenuBarSections(waiting: 0, working: 3, showsWaiting: true, showsWorking: false).emptyNote
                == "No agents waiting")
        #expect(AgentMenuBarSections(waiting: 3, working: 0, showsWaiting: false, showsWorking: true).emptyNote
                == "No agents working")
        let neither = AgentMenuBarSections(waiting: 0, working: 0, showsWaiting: false, showsWorking: false)
        #expect(neither.emptyNote == nil && !neither.showsWaiting && !neither.showsWorking)
        // One kind empty, the other listed: no note.
        #expect(AgentMenuBarSections(waiting: 0, working: 2, showsWaiting: true, showsWorking: true).emptyNote == nil)
    }

    @Test("only drawn segments move, and nothing moves with the option off, Reduce Motion or Low Power Mode")
    func animationGating() {
        let both = AgentMenuBarTitle(waiting: 2, working: 1, showsWaiting: true, showsWorking: true)
        #expect(AgentMenuBarAnimation.animated(both, animates: true, reduceMotion: false) == [.waiting, .working])
        let zeroWorking = AgentMenuBarTitle(waiting: 2, working: 0, showsWaiting: true, showsWorking: true)
        #expect(AgentMenuBarAnimation.animated(zeroWorking, animates: true, reduceMotion: false) == [.waiting])
        let hiddenWaiting = AgentMenuBarTitle(waiting: 2, working: 1, showsWaiting: false, showsWorking: true)
        #expect(AgentMenuBarAnimation.animated(hiddenWaiting, animates: true, reduceMotion: false) == [.working])
        #expect(AgentMenuBarAnimation.animated(both, animates: false, reduceMotion: false).isEmpty)
        #expect(AgentMenuBarAnimation.animated(both, animates: true, reduceMotion: true).isEmpty)
        #expect(AgentMenuBarAnimation.animated(both, animates: true, reduceMotion: false, lowPower: true).isEmpty)
        let idle = AgentMenuBarTitle(waiting: 0, working: 0, showsWaiting: true, showsWorking: true)
        #expect(AgentMenuBarAnimation.animated(idle, animates: true, reduceMotion: false).isEmpty)
    }

    @Test("the timer runs only while something moves and can be seen")
    func timer() {
        #expect(AgentMenuBarAnimation.timerRuns([.working], screenAsleep: false, sessionLocked: false, itemVisible: true))
        #expect(!AgentMenuBarAnimation.timerRuns([], screenAsleep: false, sessionLocked: false, itemVisible: true))
        #expect(!AgentMenuBarAnimation.timerRuns([.working], screenAsleep: true, sessionLocked: false, itemVisible: true))
        #expect(!AgentMenuBarAnimation.timerRuns([.working], screenAsleep: false, sessionLocked: true, itemVisible: true))
        #expect(!AgentMenuBarAnimation.timerRuns([.working], screenAsleep: false, sessionLocked: false, itemVisible: false))
    }

    @Test("a question slides only when it is clipped, by the clipped width, at a reading pace")
    func slide() {
        #expect(HoverSlide(textWidth: 200, available: 240) == nil)
        #expect(HoverSlide(textWidth: 240.5, available: 240) == nil)
        #expect(HoverSlide(textWidth: 300, available: 0) == nil)
        let slide = HoverSlide(textWidth: 390, available: 240)
        #expect(slide?.distance == 150)
        #expect(slide?.duration == 5)
    }

    @Test("the animate choice defaults on and round-trips")
    func animateOption() {
        let prefs = AgentDisplayPreferences(state: AppState())
        #expect(prefs.animatesMenuBarIcons)
        prefs.animatesMenuBarIcons = false
        var state = AppState()
        prefs.write(to: &state)
        #expect(state.agentMenuBarAnimate == false)
        #expect(!AgentDisplayPreferences(state: state).animatesMenuBarIcons)
    }
}

@Suite("Menu bar frames")
@MainActor
struct AgentMenuBarFramesTests {
    /// The pixels of a frame's first digit, as alpha values.
    func digitAlpha(_ image: NSImage, from x: CGFloat, width: CGFloat) -> [UInt8] {
        guard let rep = image.representations.first as? NSBitmapImageRep else { return [] }
        let scale = CGFloat(rep.pixelsWide) / image.size.width
        var alphas: [UInt8] = []
        for py in 0..<rep.pixelsHigh {
            for px in Int(x * scale)..<min(rep.pixelsWide, Int((x + width) * scale)) {
                alphas.append(UInt8((rep.colorAt(x: px, y: py)?.alphaComponent ?? 0) * 255))
            }
        }
        return alphas
    }

    /// The digit drawn upright the plain way, in a y-up bitmap, as a reference.
    func reference(_ digit: String, height: CGFloat, scale: CGFloat) -> NSBitmapImageRep? {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let size = (digit as NSString).size(withAttributes: attributes)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)),
                                   pixelsHigh: Int(ceil(height * scale)), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        rep.size = NSSize(width: size.width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (digit as NSString).draw(at: NSPoint(x: 0, y: (height - size.height) / 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    @Test("every frame draws both digits upright and the same; only the orbs move")
    func digitsUpright() throws {
        let title = AgentMenuBarTitle(waiting: 3, working: 2, showsWaiting: true, showsWorking: true)
        let frames = AgentMenuBarImage.frames(title, animated: [.waiting, .working], framesPerSecond: 8)
        let still = AgentMenuBarImage.render(title)
        #expect(frames.count > 10)
        let image = AgentMenuBarImage.self
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let digitWidth = ("3" as NSString).size(withAttributes: [.font: font]).width
        let firstDigit = image.glyphSize + image.digitGap
        let secondDigit = 2 * (image.glyphSize + image.digitGap) + ceil(digitWidth) + image.segmentGap
        for x in [firstDigit, secondDigit] {
            let expected = digitAlpha(still, from: x, width: digitWidth)
            #expect(expected.contains { $0 > 128 })
            for frame in frames {
                #expect(frame.size == still.size)
                #expect(digitAlpha(frame, from: x, width: digitWidth) == expected)
            }
        }
        // Upright: the still "2" matches a plainly drawn "2", not its mirror image.
        let rep = try #require(still.representations.first as? NSBitmapImageRep)
        let scale = CGFloat(rep.pixelsWide) / still.size.width
        let plain = try #require(reference("2", height: still.size.height, scale: scale))
        func rows(_ r: NSBitmapImageRep, x0: Int) -> [[Bool]] {
            (0..<plain.pixelsHigh).map { py in
                (0..<plain.pixelsWide).map { px in (r.colorAt(x: x0 + px, y: py)?.alphaComponent ?? 0) > 0.5 }
            }
        }
        let drawn = rows(rep, x0: Int(secondDigit * scale))
        let upright = rows(plain, x0: 0)
        func mismatch(_ a: [[Bool]], _ b: [[Bool]]) -> Int { zip(a, b).map { zip($0, $1).filter { $0 != $1 }.count }.reduce(0, +) }
        #expect(mismatch(drawn, upright) < mismatch(drawn, upright.reversed()))
    }
}
