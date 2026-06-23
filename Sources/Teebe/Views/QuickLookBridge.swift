import SwiftUI
import AppKit
import Quartz

/// Bridges SwiftUI to the system Quick Look panel (`QLPreviewPanel`) — the real
/// Finder-style floating overlay. Pressing space toggles it; the panel's own
/// arrow keys page through the files we hand it. `QLPreviewPanel` finds its data
/// source by walking the responder chain, so the host view installs itself as
/// first responder just before the panel opens (and restores focus on close).
@MainActor
final class QuickLookController {
    fileprivate weak var hostView: QuickLookHostView?

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
}

/// Zero-hit-test NSView that owns the Quick Look panel's data source/delegate and
/// the responder-chain hooks. Lives (invisibly) behind the main window content.
final class QuickLookHostView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
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
        urls[index] as NSURL
    }
}

/// Installs the Quick Look host view into the window hierarchy and keeps the
/// controller pointed at it.
struct QuickLookBridge: NSViewRepresentable {
    let controller: QuickLookController

    func makeNSView(context: Context) -> QuickLookHostView {
        let view = QuickLookHostView()
        controller.hostView = view
        return view
    }

    func updateNSView(_ nsView: QuickLookHostView, context: Context) {
        controller.hostView = nsView
    }
}
