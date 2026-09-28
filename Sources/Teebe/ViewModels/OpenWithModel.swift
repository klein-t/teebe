import Foundation
import Observation
import TeebeCore

/// Which app each file type opens with. The first open of a type asks (Finder's
/// Open With > Other…); the choice is remembered and used directly from then on,
/// until the app is gone, the user changes it, or forgets the type in Settings.
@MainActor
@Observable
final class OpenWithModel {
    /// A remembered file type and its app, for the Settings list.
    struct Entry: Identifiable, Equatable {
        let typeKey: String
        let appURL: URL
        var id: String { typeKey }
        var typeName: String { FileTypeKey.displayName(forKey: typeKey) }
        var appName: String { appURL.deletingPathExtension().lastPathComponent }
    }

    /// Type key (`FileTypeKey`) → the chosen app's path.
    private(set) var apps: [String: String]
    /// Called after every change so the owner can persist `apps`.
    @ObservationIgnored var onChange: () -> Void = {}

    private let environment: AppEnvironment

    init(environment: AppEnvironment, apps: [String: String]) {
        self.environment = environment
        self.apps = apps
    }

    /// Remembered types, alphabetical by how they read.
    var entries: [Entry] {
        apps.map { Entry(typeKey: $0.key, appURL: URL(fileURLWithPath: $0.value)) }
            .sorted { $0.typeName.localizedStandardCompare($1.typeName) == .orderedAscending }
    }

    /// The remembered app for `file`'s type, if it is still installed.
    func rememberedApp(for file: URL) -> URL? {
        guard let path = apps[FileTypeKey.key(forFileName: file.lastPathComponent)] else { return nil }
        let url = URL(fileURLWithPath: path)
        return environment.appExists(url) ? url : nil
    }

    /// Open `file` with its type's app, asking first when there is none (or it's
    /// gone). Returns false when the user cancels the chooser: nothing opens.
    @discardableResult
    func open(_ file: URL) throws -> Bool {
        if let app = rememberedApp(for: file) {
            try environment.opener.open(file, withApplicationAt: app)
            return true
        }
        return try chooseAndOpen(file)
    }

    /// Open With…: always ask, then remember the choice for the type.
    @discardableResult
    func chooseAndOpen(_ file: URL) throws -> Bool {
        let key = FileTypeKey.key(forFileName: file.lastPathComponent)
        guard let app = environment.chooseApp(file, key, rememberedApp(for: file)) else { return false }
        remember(app, forType: key)
        try environment.opener.open(file, withApplicationAt: app)
        return true
    }

    /// Settings' Change…: pick a new app for a remembered type.
    func changeApp(forType key: String) {
        let current = apps[key].map { URL(fileURLWithPath: $0) }
        guard let app = environment.chooseApp(nil, key, current) else { return }
        remember(app, forType: key)
    }

    func forget(type key: String) {
        apps[key] = nil
        onChange()
    }

    func forgetAll() {
        apps.removeAll()
        onChange()
    }

    private func remember(_ app: URL, forType key: String) {
        apps[key] = app.path
        onChange()
    }
}
