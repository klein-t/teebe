import Foundation
import Observation
import TeebeCore

/// Settings edits defaults. The main window edits only the selected project's
/// optional overrides, so later default changes still reach inheriting fields.
@MainActor
@Observable
final class PreferencesModel {
    var defaults: ProjectPreferences { didSet { if defaults != oldValue { onChange() } } }
    private(set) var projects: [String: ProjectPreferences]
    var repositoryPath: String?
    @ObservationIgnored var onChange: () -> Void = {}

    init(state: AppState) {
        defaults = state.defaultPreferences ?? ProjectPreferences(
            groupByStatus: state.showMergeStatus ?? false,
            fetchAutomatically: state.fetchAutomatically ?? true,
            worktreeSort: state.worktreeSortOrder ?? "folder", fileSort: "name",
            changedOnly: state.showChangedOnly, showIgnored: state.showIgnored)
        projects = state.projectPreferences ?? [:]
        if state.projectPreferences == nil {
            for (path, ref) in state.cleanupTargetByRepo ?? [:] {
                projects[path, default: ProjectPreferences()].comparisonRef = ref
            }
            for (path, folder) in state.worktreeParentByRepo ?? [:] {
                projects[path, default: ProjectPreferences()].worktreeParent = folder
            }
        }
    }

    var effective: ProjectPreferences { effective(for: repositoryPath) }
    func effective(for path: String?) -> ProjectPreferences {
        (path.flatMap { projects[$0] } ?? ProjectPreferences()).inheriting(defaults)
    }
    var hasOverrides: Bool { repositoryPath.flatMap { projects[$0] } != nil }

    func set<Value>(_ key: WritableKeyPath<ProjectPreferences, Value?>, _ value: Value) {
        guard let path = repositoryPath else {
            defaults[keyPath: key] = value
            return
        }
        var project = projects[path] ?? ProjectPreferences()
        project[keyPath: key] = value
        projects[path] = project
        onChange()
    }

    func setComparison(_ ref: String?, for path: String) {
        projects[path, default: ProjectPreferences()].comparisonRef = ref ?? ""
        onChange()
    }

    func setWorktreeParent(_ folder: String, for path: String) {
        projects[path, default: ProjectPreferences()].worktreeParent = folder
        onChange()
    }

    func reset() {
        guard let path = repositoryPath else { return }
        remove(path)
    }

    func remove(_ path: String) {
        projects[path] = nil
        onChange()
    }
}
