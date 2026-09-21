import AppKit
import SwiftUI
import Testing
import TeebeCore
@testable import Teebe

/// The window and the worktree rows, driven the way the user drives them.
///
/// Window sizing is the one part of teebe that no view-model test can vouch for: the
/// section heights resolve during a real layout pass, and the reconcile answers
/// AppKit's own `didResize`. So this suite hosts `RootView` in a real `NSWindow`,
/// drives it through `GeometryTestHooks` (the test process has no accessibility
/// access, so nothing can be clicked), and after every step asserts the two rules the
/// accordion lives by:
///
/// * the window is exactly as tall as the layout asks for, and got there in **at most
///   one** resize — a second one is the hop the user sees as a flicker;
/// * selecting a worktree never moves a row. The rows are sampled continuously while
///   the selection loads, not just once it has settled, because the regression this
///   guards against was a row jumping into another group and back within ~30ms.
@MainActor
@Suite("Window geometry", .serialized)
struct WindowGeometryTests {

    @Test("launch near the screen bottom settles without repeated corrections", arguments: [340.0, 420.0])
    func lowLaunchSettlesWithoutChasingItsFrame(topRoom: Double) async throws {
        guard let host = try await GeometryHost.make(topRoom: topRoom) else { return }
        defer { host.tearDown() }
        await host.settleGeometry()
        host.expectSettled("launch near screen bottom")
        if let screen = host.window.screen {
            #expect(host.window.frame.minY >= screen.visibleFrame.minY)
        }
    }

    @Test("restoring a low frame settles in one resize", arguments: [340.0, 420.0])
    func lowWindowSettlesWithoutChasingItsFrame(height: Double) async throws {
        guard let host = try await GeometryHost.make(), let screen = host.window.screen else { return }
        defer { host.tearDown() }
        host.hooks.reset()
        var frame = host.window.frame
        frame.size.height = height
        frame.origin.y = screen.visibleFrame.minY
        host.window.setFrame(frame, display: true)
        await host.settleGeometry()
        host.expectSettled("move near screen bottom")
        #expect(host.window.frame.minY >= screen.visibleFrame.minY,
                "restoring a low frame pushed the window below the screen: \(host.window.frame)")
    }

    @Test("selecting, collapsing, dragging and an AppKit resize each settle in one resize")
    func geometryStaysInStepWithTheLayout() async throws {
        guard let host = try await GeometryHost.make() else { return }   // no display (headless CI)
        defer { host.tearDown() }

        // Every worktree in turn: the row order must not change, and the window may
        // resize at most once — only because the CHANGES/FILES content is a different
        // height for the checkout that was just opened.
        for worktree in host.app.selector.worktrees {
            let name = worktree.branch ?? worktree.name
            let wasOpen = host.app.selector.selectedWorktree?.path == worktree.path
            let before = host.rowOrder()
            var sawLoadInFlight = false
            var jumbled: [[String]] = []
            host.hooks.reset()
            async let selection: Void = host.app.selector.selectWorktree(worktree)
            await host.settle(sample: {
                let model = host.app.selector.worktree
                // The window between "another row was clicked" and "its status read
                // came back" — where the row used to be described by the previous
                // checkout's status and hopped into the wrong group.
                if model.worktreePath != model.statusPath { sawLoadInFlight = true }
                let now = host.rowOrder()
                if now != before { jumbled.append(now) }
            }, until: { host.app.selector.worktree.statusPath == worktree.path && host.isSettled })
            await selection
            await host.settle(until: { host.isSettled })

            #expect(jumbled.isEmpty, "selecting \(name) reordered the rows: \(before) became \(jumbled.first ?? [])")
            // A worktree that was already open never has a status read in flight, so
            // only a real switch proves the sampling covered the load.
            #expect(wasOpen || sawLoadInFlight,
                    "selecting \(name) never showed a pending status read — the sampling missed the load")
            host.expectSettled("select \(name)")
        }

        // Collapse and reopen every section.
        for (name, setOpen) in host.sectionSetters {
            for open in [false, true] {
                host.hooks.reset()
                setOpen(open)
                await host.settle(until: { host.isSettled })
                host.expectSettled("\(name) \(open ? "open" : "collapsed")")
            }
        }

        // Both dividers, dragged down and back up through the same calls the handle's
        // drag gesture makes. The window is held still for the drag and sized once at
        // the end; with FILES open to absorb the room it must not move at all.
        for divider in host.dividerDrags {
            for delta in [100.0, -100.0] as [CGFloat] {
                let heightBefore = host.window.frame.height
                host.hooks.reset()
                let start = divider.currentHeight()
                for step in 1...10 {
                    divider.drag(start + delta * CGFloat(step) / 10)
                    await host.settle(timeout: 0.05, until: { false })
                }
                host.endDrag()
                await host.settle(until: { host.isSettled })
                host.expectSettled("\(divider.name) divider \(delta > 0 ? "down" : "up")")
                #expect(abs(host.window.frame.height - heightBefore) <= 1,
                        "\(divider.name) divider drag moved the window: \(heightBefore) → \(host.window.frame.height)")
            }
        }

        // AppKit resized the window behind our back (a constraint pass, a restored
        // frame): the reconcile pulls it back, once.
        host.hooks.reset()
        var grown = host.window.frame
        grown.size.height += 120
        grown.origin.y -= 120
        host.window.setFrame(grown, display: true)
        await host.settle(until: { host.isSettled })
        host.expectSettled("AppKit frame change")
    }
}

// MARK: - Host

/// `RootView` in a real window, wired to a throwaway repository with a checkout in
/// every worktree group.
@MainActor
private final class GeometryHost {
    let app: AppModel
    let hooks: GeometryTestHooks
    let window: NSWindow
    private let fixture: WorktreeFixture

    private init(app: AppModel, hooks: GeometryTestHooks, window: NSWindow, fixture: WorktreeFixture) {
        self.app = app
        self.hooks = hooks
        self.window = window
        self.fixture = fixture
    }

    /// Returns nil when there is no display to put a window on, which is the only
    /// state this test cannot run in.
    static func make(topRoom: CGFloat? = nil) async throws -> GeometryHost? {
        guard let screen = NSScreen.main else { return nil }
        NSApplication.shared.setActivationPolicy(.accessory)

        let fixture = try WorktreeFixture()
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("teebe-geometry-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
        let environment = AppEnvironment(
            git: ProcessGitClient(),
            opener: FakeFileOpener(),
            ops: FakeFileOps(),
            store: AppStateStore(url: storeURL),
            activityMonitor: WorktreeActivityMonitor(),
            makeWatcher: { FakeWatcher() }   // no FSEvents: nothing refreshes behind the test
        )
        let app = AppModel(environment: environment)
        app.mergeStatus.scanDebounce = .milliseconds(1)
        if topRoom != nil {
            await app.addRepository(path: fixture.repoPath)
            app.saveLayout(SectionLayout(worktreesOpen: true, changesOpen: true, filesOpen: true,
                                         windowHeight: 200, worktreesHeight: 400, changesHeight: 400),
                           forRepo: fixture.repoPath)
        }
        let hooks = GeometryTestHooks()
        let root = RootView(app: app, preview: PreviewModel(environment: environment), testHooks: hooks)

        // Most interactions start high on screen. Startup cases restore a lower
        // top edge, including one with less room than the section minimums need.
        let frame = NSRect(x: screen.visibleFrame.minX + 40,
                           y: topRoom.map { screen.visibleFrame.minY + $0 - 640 } ?? (screen.visibleFrame.maxY - 700),
                           width: 440, height: 640)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        let hostingView = NSHostingView(rootView: root)
        hostingView.sizingOptions = [.minSize]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = hostingView
        window.orderFront(nil)
        // NSWindow's initial placement clamps the origin; restoration happens after
        // that and can change both the height and top edge without a didMove event.
        if topRoom != nil { window.setFrame(frame, display: true) }

        let host = GeometryHost(app: app, hooks: hooks, window: window, fixture: fixture)
        await host.settle(timeout: 10, until: { hooks.targetHeight != nil })
        if topRoom == nil { await app.addRepository(path: fixture.repoPath) }
        // Wait for the picture the user would see: every worktree discovered, the merge
        // scan grouped, the window done settling on the layout.
        await host.settle(timeout: 20, until: {
            app.selector.worktrees.count == WorktreeFixture.worktreeCount
                && app.worktreeList(collapsed: []).groups.count == WorktreeFixture.groupCount
                && host.isSettled
        })
        #expect(app.selector.worktrees.count == WorktreeFixture.worktreeCount, "fixture worktrees not discovered")
        #expect(app.worktreeList(collapsed: []).groups.count == WorktreeFixture.groupCount,
                "merge scan did not group the fixture")
        return host
    }

    func tearDown() {
        window.orderOut(nil)
        window.contentView = nil
        fixture.cleanup()
    }

    // MARK: Assertions

    /// The window is the height the layout asks for (AppKit rounds the frame it hands
    /// back, so a point of slack).
    var isSettled: Bool { abs(window.frame.height - (hooks.targetHeight?() ?? 0)) <= 1 }

    func expectSettled(_ step: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let target = hooks.targetHeight?() ?? 0
        #expect(isSettled, "\(step): window is \(window.frame.height)pt, layout asks for \(target)pt",
                sourceLocation: sourceLocation)
        #expect(hooks.resizes <= 1, "\(step): \(hooks.resizes) window resizes, expected at most one",
                sourceLocation: sourceLocation)
    }

    /// The rows as the list shows them: every visible worktree, in order, tagged with
    /// the group it sits in — so a row changing group fails even if the order holds.
    func rowOrder() -> [String] {
        let list = app.worktreeList(collapsed: [])
        return list.pinned.map { "pinned:" + $0.name }
            + list.groups.flatMap { group in group.worktrees.map { "\(group.kind.rawValue):\($0.name)" } }
    }

    // MARK: Driving

    var sectionSetters: [(String, (Bool) -> Void)] {
        [("WORKTREES", { self.hooks.setWorktreesOpen?($0) }),
         ("CHANGES", { self.hooks.setChangesOpen?($0) }),
         ("FILES", { self.hooks.setFilesOpen?($0) })]
    }

    /// One resizable section's divider: the height it starts from and the call the
    /// handle's drag gesture makes for each step.
    struct Divider {
        let name: String
        let currentHeight: () -> CGFloat
        let drag: (CGFloat) -> Void
    }

    var dividerDrags: [Divider] {
        [Divider(name: "WORKTREES", currentHeight: { self.hooks.worktreeListHeight?() ?? 0 },
                 drag: { self.hooks.dragWorktreesDivider?($0) }),
         Divider(name: "CHANGES", currentHeight: { self.hooks.changesListHeight?() ?? 0 },
                 drag: { self.hooks.dragChangesDivider?($0) })]
    }

    func endDrag() { hooks.endDividerDrag?() }

    /// Do not accept a transient match between frame and target: queued AppKit and
    /// SwiftUI callbacks can still move both. Require a quiet interval as well.
    func settleGeometry() async {
        var lastFrame = window.frame
        var lastResizes = hooks.resizes
        var stableSince = Date()
        await settle(sample: {
            if self.window.frame != lastFrame || self.hooks.resizes != lastResizes {
                lastFrame = self.window.frame
                lastResizes = self.hooks.resizes
                stableSince = Date()
            }
        }, until: { self.isSettled && Date().timeIntervalSince(stableSince) >= 0.2 })
    }

    /// Run the main run loop — laying out, delivering AppKit notifications and letting
    /// the model's own tasks finish — until `condition` holds. Polls a predicate
    /// rather than sleeping a fixed time, and calls `sample` on every pass so a step
    /// can watch what happens *during* it, not only where it lands.
    func settle(timeout: TimeInterval = 5, sample: (() -> Void)? = nil, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            sample?()
            if condition() { break }
            Self.pumpRunLoop()
            await Task.yield()
        }
        sample?()
    }

    /// One pass of the main run loop. Synchronous on purpose: `RunLoop.run` is not
    /// callable from an async context, and this is exactly the "let AppKit catch up"
    /// step the async `settle` needs.
    private static func pumpRunLoop() {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
    }
}

// MARK: - Fixture

/// A throwaway repository whose checkouts land one in each worktree group, with
/// different numbers of uncommitted files so switching between them really does ask
/// the window for a different height.
private struct WorktreeFixture {
    static let worktreeCount = 5        // primary + one per group
    static let groupCount = 4           // merged, uncommitted changes, unmerged commits, broken

    let root: URL
    var repoPath: String { root.appendingPathComponent("repo").path }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("teebe-geometry-repo-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main"], in: repo)
        git(["config", "user.email", "test@teebe.local"], in: repo)
        git(["config", "user.name", "Teebe Test"], in: repo)
        git(["config", "commit.gpgsign", "false"], in: repo)
        write("a.txt", "a", in: repo)
        git(["add", "-A"], in: repo)
        git(["commit", "-qm", "init"], in: repo)

        // Merged: its commit is already in main.
        let merged = add(worktree: "wt-merged", branch: "feat/merged", from: repo)
        write("m.txt", "m", in: merged)
        git(["add", "-A"], in: merged)
        git(["commit", "-qm", "merged"], in: merged)
        git(["merge", "-q", "feat/merged"], in: repo)

        // Unmerged commits, clean folder.
        let ahead = add(worktree: "wt-ahead", branch: "feat/ahead", from: repo)
        write("z.txt", "z", in: ahead)
        git(["add", "-A"], in: ahead)
        git(["commit", "-qm", "ahead"], in: ahead)

        // Uncommitted changes — and enough of them that the CHANGES list is a
        // different height here than anywhere else.
        let dirty = add(worktree: "wt-dirty", branch: "feat/dirty", from: repo)
        for index in 1...4 { write("d\(index).txt", "d", in: dirty) }

        // Broken: git still lists it, the folder is gone.
        let gone = add(worktree: "wt-gone", branch: "feat/gone", from: repo)
        try? FileManager.default.removeItem(at: gone)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    private func add(worktree name: String, branch: String, from repo: URL) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        git(["worktree", "add", "-q", "-b", branch, url.path], in: repo)
        return url
    }

    private func write(_ name: String, _ contents: String, in directory: URL) {
        try? Data(contents.utf8).write(to: directory.appendingPathComponent(name))
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"].map { "\($0):/usr/bin:/bin" }) ?? "/usr/bin:/bin"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try? process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}
