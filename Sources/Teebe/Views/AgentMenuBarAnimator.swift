import AppKit
import SwiftUI

/// Moves the menu bar orbs. Frames for the current title are drawn once into
/// bitmaps; each tick only swaps the status button's image, with no drawing and
/// no SwiftUI or model update. The timer runs only while an orb moves and the
/// item can be seen: not with Reduce Motion or Low Power Mode, nor while the
/// screen sleeps, the session is locked or the item is covered.
@MainActor
final class AgentMenuBarAnimator {
    static let shared = AgentMenuBarAnimator()
    /// Low on purpose: each frame costs a status item redraw in WindowServer.
    static let framesPerSecond: Double = 5

    struct Request: Equatable {
        let title: AgentMenuBarTitle
        let animates: Bool
    }

    private var request: Request?
    private var frames: [NSImage] = []
    /// Whether each frame differs from the one before it: the solving orb rests
    /// between turns, and an unchanged frame is not set on the button again.
    private var changes: [Bool] = []
    private var framesKey: (title: AgentMenuBarTitle, orbs: Set<AgentMenuBarAnimation.Orb>)?
    private var index = 0
    private var timer: Timer?
    private var screenAsleep = false
    private var sessionLocked = false
    private var observing = false
    private weak var button: NSStatusBarButton?

    func configure(title: AgentMenuBarTitle, animates: Bool) {
        request = Request(title: title, animates: animates)
        startObserving()
        update()
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var lowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    private func update() {
        guard let request else { return stop() }
        let orbs = AgentMenuBarAnimation.animated(request.title, animates: request.animates,
                                                  reduceMotion: reduceMotion, lowPower: lowPower)
        let visible = statusButton()?.window?.occlusionState.contains(.visible) ?? true
        guard AgentMenuBarAnimation.timerRuns(orbs, screenAsleep: screenAsleep, sessionLocked: sessionLocked,
                                              itemVisible: visible) else { return stop() }
        if framesKey?.title != request.title || framesKey?.orbs != orbs {
            frames = AgentMenuBarImage.frames(request.title, animated: orbs, framesPerSecond: Self.framesPerSecond)
            changes = frames.indices.map { index in
                let previous = frames[(index + frames.count - 1) % frames.count]
                return frames[index].tiffRepresentation != previous.tiffRepresentation
            }
            framesKey = (request.title, orbs)
            index = 0
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / Self.framesPerSecond, repeats: true) { _ in
            MainActor.assumeIsolated { AgentMenuBarAnimator.shared.tick() }
        }
        timer.tolerance = 0.4 / Self.framesPerSecond
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard !frames.isEmpty, let button = statusButton() else { return }
        index = (index + 1) % frames.count
        if changes[index] { button.image = frames[index] }
    }

    /// No timer; the still title, as SwiftUI drew it, goes back on the button.
    private func stop() {
        guard let timer else { return }
        timer.invalidate()
        self.timer = nil
        if let request { statusButton()?.image = AgentMenuBarImage.render(request.title) }
    }

    private func statusButton() -> NSStatusBarButton? {
        if let button, button.window != nil { return button }
        button = NSApp.windows.filter { String(describing: type(of: $0)).contains("StatusBar") }
            .lazy.compactMap { Self.findButton(in: $0.contentView) }.first
        return button
    }

    private static func findButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        return view.subviews.lazy.compactMap { findButton(in: $0) }.first
    }

    private func startObserving() {
        guard !observing else { return }
        observing = true
        let workspace = NSWorkspace.shared.notificationCenter
        let changes: [(NotificationCenter, Notification.Name, () -> Void)] = [
            (workspace, NSWorkspace.screensDidSleepNotification, { [weak self] in self?.screenAsleep = true }),
            (workspace, NSWorkspace.screensDidWakeNotification, { [weak self] in self?.screenAsleep = false }),
            (workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, {}),
            (NotificationCenter.default, .NSProcessInfoPowerStateDidChange, {}),
            (NotificationCenter.default, NSWindow.didChangeOcclusionStateNotification, {}),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"),
             { [weak self] in self?.sessionLocked = true }),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked"),
             { [weak self] in self?.sessionLocked = false })
        ]
        for (center, name, change) in changes {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    change()
                    AgentMenuBarAnimator.shared.update()
                }
            }
        }
    }
}
