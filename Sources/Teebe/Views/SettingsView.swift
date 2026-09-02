import SwiftUI
import AppKit

/// The user's appearance choice. `system` follows macOS; the others force it.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Push the choice to every window (and future ones) at once. `NSApp` is nil
    /// under `swift test` (no application object), so this is a no-op there.
    @MainActor func apply() {
        guard let app = NSApp else { return }
        switch self {
        case .system: app.appearance = nil
        case .light: app.appearance = NSAppearance(named: .aqua)
        case .dark: app.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// The Settings window (⌘,). Small on purpose: only preferences that aren't
/// already a one-click toggle in the main window live here.
struct SettingsView: View {
    @Bindable var app: AppModel

    var body: some View {
        Form {
            Picker("Appearance", selection: $app.appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }
}
