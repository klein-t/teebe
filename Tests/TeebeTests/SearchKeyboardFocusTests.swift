import AppKit
import SwiftUI
import Testing
import TeebeCore
@testable import Teebe

@MainActor
@Suite("Search keyboard focus", .serialized)
struct SearchKeyboardFocusTests {
    @Test("leaving search returns focus to the keyboard-driven list")
    func restoresListResponder() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true)]
        let environment = makeTestEnvironment(git: git)
        let app = AppModel(environment: environment)
        await app.addRepository(path: "/repo")
        let hooks = GeometryTestHooks()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 100, width: 440, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: RootView(app: app, preview: PreviewModel(environment: environment), testHooks: hooks))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        try #require(hooks.focusSearch != nil)
        hooks.focusSearch?()
        try await Task.sleep(for: .milliseconds(100))
        #expect((window.firstResponder as? NSTextView)?.isFieldEditor == true)
        hooks.leaveSearch?()
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.firstResponder !== window)
        #expect((window.firstResponder as? NSTextView)?.isFieldEditor != true)
        #expect(app.activeSection == .files)
        hooks.focusSearch?()
        try await Task.sleep(for: .milliseconds(100))
        #expect((window.firstResponder as? NSTextView)?.isFieldEditor == true)
        hooks.focusSection?(.worktrees)
        try await Task.sleep(for: .milliseconds(100))
        #expect(app.activeSection == .worktrees)
        #expect((window.firstResponder as? NSTextView)?.isFieldEditor != true)
    }
}
