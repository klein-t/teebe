import SwiftUI
import AppKit
import Quartz

/// Bridges SwiftUI to the system Quick Look panel (`QLPreviewPanel`) — the real
/// Finder-style floating overlay. Pressing space toggles it on the selected item;
/// arrow keys pressed in the panel go to `onArrow`, which moves the list selection,
/// and `show(_:)` then follows it (Finder's behavior). `QLPreviewPanel` finds its data
/// source by walking the responder chain, so the host view installs itself as
/// first responder just before the panel opens (and restores focus on close).
@MainActor
final class QuickLookController {
    fileprivate weak var hostView: QuickLookHostView?
    /// An arrow key pressed while the panel is key.
    var onArrow: ((PeekArrow) -> Void)?

    /// Open the panel on `urls`, starting at `startIndex`; toggles closed if it's
    /// already showing.
    func toggle(urls: [URL], startIndex: Int) {
        hostView?.toggle(urls: urls, startIndex: startIndex)
    }

    var isOpen: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    func close() {
        if isOpen { QLPreviewPanel.shared()?.orderOut(nil) }
    }

    /// Swap the open panel's item for `url` (the selection moved). No-op when closed.
    func show(_ url: URL) {
        guard isOpen else { return }
        hostView?.show(url)
    }
}

/// Zero-hit-test NSView that owns the Quick Look panel's data source/delegate and
/// the responder-chain hooks. Lives (invisibly) behind the main window content.
final class QuickLookHostView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    fileprivate weak var controller: QuickLookController?
    private var urls: [URL] = []
    private var startIndex = 0
    private weak var previousResponder: NSResponder?

    override var acceptsFirstResponder: Bool { true }

    // Never intercept mouse events — this view exists only for keyboard/QL control.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func toggle(urls: [URL], startIndex: Int) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        guard !urls.isEmpty else { return }
        self.urls = urls
        self.startIndex = max(0, min(startIndex, urls.count - 1))
        previousResponder = window?.firstResponder
        window?.makeFirstResponder(self)
        panel.makeKeyAndOrderFront(nil)
    }

    func show(_ url: URL) {
        guard urls != [url] else { return }
        urls = [url]
        QLPreviewPanel.shared()?.reloadData()
    }

    // MARK: - Responder-chain control

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = startIndex
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        // Hand keyboard focus back to the SwiftUI content so space/arrows keep working.
        if let previousResponder { window?.makeFirstResponder(previousResponder) }
        previousResponder = nil
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }

    // MARK: - QLPreviewPanelDelegate

    /// Plain arrow keys move the list selection instead of the panel's own paging.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.isDisjoint(with: [.command, .option, .control]),
              let arrow = PeekArrow(keyCode: event.keyCode),
              let onArrow = controller?.onArrow else { return false }
        onArrow(arrow)
        return true
    }
}

/// Installs the Quick Look host view into the window hierarchy and keeps the
/// controller pointed at it.
struct QuickLookBridge: NSViewRepresentable {
    let controller: QuickLookController

    func makeNSView(context: Context) -> QuickLookHostView {
        let view = QuickLookHostView()
        view.controller = controller
        controller.hostView = view
        return view
    }

    func updateNSView(_ nsView: QuickLookHostView, context: Context) {
        nsView.controller = controller
        controller.hostView = nsView
    }
}
