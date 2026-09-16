import Foundation
import Testing
import TeebeCore

@Suite("Repository history")
struct RepositoryHistoryTests {
    @Test("duplicate paths collapse while retaining the most recent occurrence")
    func duplicates() {
        let repos = RepositoryHistory.unique(["/projects/a", "/projects/b", "/projects/a/", "/projects/other/../b"])
        #expect(repos.map(\.path) == ["/projects/a", "/projects/b"])
    }

    @Test("a case variant of a real folder is the same project")
    func caseVariants() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let variant = root.appendingPathComponent("project")
        // On a case-sensitive volume the variant is a different folder, so there is
        // nothing to collapse and nothing to assert.
        guard FileManager.default.fileExists(atPath: variant.path) else { return }
        let repos = RepositoryHistory.unique([folder.path, variant.path])
        #expect(repos.count == 1)
        #expect(repos.first?.name == "Project")
    }

    @Test("aliases resolve to one project and equal folder names stay distinct")
    func aliasesAndNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("first/project")
        let other = root.appendingPathComponent("second/project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        let repos = RepositoryHistory.unique([folder.path, alias.path, other.path])
        #expect(repos.count == 2)
        let titles = repos.map { RepositoryHistory.title(for: $0, among: repos) }
        #expect(Set(titles).count == 2)
        #expect(titles.allSatisfy { $0.hasPrefix("project (") })
        #expect(RepositoryHistory.title(for: repos[0], among: [repos[0]]) == "project")
    }
}
