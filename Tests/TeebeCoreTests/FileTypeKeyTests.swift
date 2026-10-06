import Testing
@testable import TeebeCore

@Suite("File type keys")
struct FileTypeKeyTests {
    @Test("files with an extension are keyed by it, case-insensitively")
    func byExtension() {
        #expect(FileTypeKey.key(forFileName: "main.swift") == ".swift")
        #expect(FileTypeKey.key(forFileName: "README.MD") == ".md")
        #expect(FileTypeKey.key(forFileName: "archive.tar.gz") == ".gz")
    }

    @Test("dotfiles are keyed by their name; a dotfile with an extension by that")
    func dotfiles() {
        #expect(FileTypeKey.key(forFileName: ".gitignore") == ".gitignore")
        #expect(FileTypeKey.key(forFileName: ".ENV") == ".env")
        #expect(FileTypeKey.key(forFileName: ".env.local") == ".local")
    }

    @Test("build files like Makefile and Dockerfile are keyed by their name")
    func namedFiles() {
        #expect(FileTypeKey.key(forFileName: "Makefile") == "makefile")
        #expect(FileTypeKey.key(forFileName: "Dockerfile") == "dockerfile")
    }

    @Test("other files without an extension share one type")
    func noExtension() {
        #expect(FileTypeKey.key(forFileName: "LICENSE") == FileTypeKey.noExtension)
        #expect(FileTypeKey.key(forFileName: "gradlew") == FileTypeKey.noExtension)
        #expect(FileTypeKey.key(forFileName: "trailing.") == FileTypeKey.noExtension)
        #expect(FileTypeKey.key(forFileName: "file") == FileTypeKey.noExtension)
    }

    @Test("display names")
    func displayNames() {
        #expect(FileTypeKey.displayName(forKey: ".swift") == ".swift")
        #expect(FileTypeKey.displayName(forKey: "makefile") == "Makefile")
        #expect(FileTypeKey.displayName(forKey: FileTypeKey.noExtension) == "No extension")
    }
}
