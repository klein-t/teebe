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

    /// One centered line: "teebe.io · <GitHub mark> · <X logo>", each a link.
    static func credits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        let separator = NSAttributedString(string: "   ·   ", attributes: base)

        let result = NSMutableAttributedString()
        result.append(link(NSAttributedString(string: "teebe.io", attributes: base), to: ProjectLinks.website))
        result.append(separator)
        result.append(link(icon(named: "github-mark", font: font, fallback: "GitHub", base: base), to: ProjectLinks.github))
        result.append(separator)
        result.append(link(icon(named: "x-logo", font: font, fallback: "@KleinTahiraj", base: base), to: ProjectLinks.x))
        return result
    }

    private static func link(_ text: NSAttributedString, to url: URL) -> NSAttributedString {
        let linked = NSMutableAttributedString(attributedString: text)
        linked.addAttribute(.link, value: url, range: NSRange(location: 0, length: linked.length))
        return linked
    }

    /// A bundled SVG logo as an inline text attachment, tinted like secondary text and
    /// vertically centred on the line. Falls back to a text label if the asset is missing.
    private static func icon(
        named name: String, font: NSFont, fallback: String, base: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        guard let url = Brand.resourceBundle?.url(forResource: name, withExtension: "svg"),
              let source = NSImage(contentsOf: url) else {
            return NSAttributedString(string: fallback, attributes: base)
        }
        let side = font.pointSize + 2
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            source.draw(in: rect)
            NSColor.secondaryLabelColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        // Sit the glyph on the text baseline, nudged down so its optical centre lines up.
        let yOffset = font.descender + (font.capHeight - side) / 2 + 1
        attachment.bounds = NSRect(x: 0, y: yOffset, width: side, height: side)
        return NSAttributedString(attachment: attachment)
    }
}
