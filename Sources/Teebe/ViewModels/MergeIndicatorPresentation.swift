import TeebeCore

struct MergeIndicatorPresentation {
    enum Symbol { case branch, merge, edit, ignored, unknown, warning, checking }
    enum Tone { case merged, attention, secondary }
    let symbol: Symbol
    let tone: Tone
    let hasLocalFiles: Bool
    let title: String
    let details: [String]
    var description: String { ([title] + details).joined(separator: ". ") }

    init(entry: CleanupEntry?, targetName: String?, isChecking: Bool) {
        guard let entry else {
            self.init(symbol: isChecking ? .checking : .unknown,
                      title: isChecking ? "Checking merge status" : "Status unavailable",
                      details: isChecking ? [] : ["Refresh to try again"])
            return
        }
        if entry.isBroken {
            let reason = entry.problem?.replacingOccurrences(of: "Broken worktree: ", with: "")
                .replacingOccurrences(of: " Remaining files were not changed.", with: "")
                ?? "Git cannot access this checkout"
            self.init(symbol: .warning, tone: .attention, title: "Broken worktree", details: [reason])
            return
        }
        var local: [String] = []
        if entry.hasLocalChanges { local.append("Uncommitted changes") }
        if entry.hasIgnoredFiles { local.append("Ignored files (excluded from commits)") }
        if entry.hasUncheckedFiles { local.append("Git skips change checks on some files") }
        if entry.hasSubmodules { local.append("Nested Git repository (submodule)") }
        guard let targetName else {
            self.init(symbol: .unknown, hasLocalFiles: !local.isEmpty, title: "No comparison branch",
                      details: ["Choose one in Clean up worktrees"] + local)
            return
        }
        if !local.isEmpty, entry.mergeStatus != .unknown {
            let merge = entry.mergeStatus == .merged
                ? (entry.hasEquivalentContent ? "Changes already in \(targetName)" : "Merged into \(targetName)")
                : "Merge unconfirmed against \(targetName)"
            let symbol: Symbol = entry.hasLocalChanges ? .edit
                : (entry.hasUncheckedFiles || entry.hasSubmodules ? .warning : .ignored)
            let title = entry.hasLocalChanges ? "Uncommitted changes"
                : (symbol == .warning ? "Files need attention" : "Ignored files")
            let reasons = local.filter { $0 != title }.map {
                title == "Ignored files" && $0.hasPrefix("Ignored files") ? "Excluded from Git commits" : $0
            }
            self.init(symbol: symbol, tone: symbol == .ignored ? .secondary : .attention,
                      hasLocalFiles: true, title: title, details: [merge] + reasons)
            return
        }
        switch entry.mergeStatus {
        case .merged:
            self.init(symbol: .merge, tone: local.isEmpty ? .merged : .secondary,
                      hasLocalFiles: !local.isEmpty,
                      title: entry.hasEquivalentContent ? "Changes already in \(targetName)" : "Merged into \(targetName)",
                      details: local.isEmpty ? ["No local changes or ignored files"] : local)
        case .notConfirmed:
            self.init(symbol: .branch, hasLocalFiles: !local.isEmpty, title: "Merge unconfirmed",
                      details: ["Compared with \(targetName)"] + local)
        case .unknown:
            self.init(symbol: .unknown, hasLocalFiles: !local.isEmpty, title: "Status unavailable",
                      details: [entry.problem ?? "Refresh to check against \(targetName)"] + local)
        }
    }

    private init(symbol: Symbol, tone: Tone = .secondary, hasLocalFiles: Bool = false,
                 title: String, details: [String]) {
        self.symbol = symbol
        self.tone = tone
        self.hasLocalFiles = hasLocalFiles
        self.title = title
        self.details = details
    }
}
