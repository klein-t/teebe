import SwiftUI
import AppKit

/// Where to find the project and its author. Shown as clickable links in the
/// About panel's credits area.
enum ProjectLinks {
    static let website = URL(string: "https://teebe.io")!
    static let github = URL(string: "https://github.com/klein-t/teebe")!
    static let x = URL(string: "https://x.com/KleinTahiraj")!
}

/// Replaces the stock "About teebe" menu item so the standard About panel carries
/// links to the website, the GitHub repo, and the author's X account. Everything
/// else (icon, version, copyright) still comes from `Info.plist`.
struct AboutMenuCommand: View {
    var body: some View {
        Button("About \(Brand.name)") { AboutPanel.show() }
    }
}

enum AboutPanel {
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
    }

    /// One centered line: "teebe.io · GitHub · @KleinTahiraj", each a link.
    static func credits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        let result = NSMutableAttributedString()
        let items: [(String, URL)] = [
            ("teebe.io", ProjectLinks.website),
            ("GitHub", ProjectLinks.github),
            ("@KleinTahiraj", ProjectLinks.x)
        ]
        for (index, (title, url)) in items.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "  ·  ", attributes: base)) }
            var attrs = base
            attrs[.link] = url
            result.append(NSAttributedString(string: title, attributes: attrs))
        }
        return result
    }
}
