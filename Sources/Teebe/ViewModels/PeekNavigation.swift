import Foundation
import TeebeCore

/// An arrow key pressed while a peek (the Quick Look panel or the diff preview) is
/// showing. Like Finder under Quick Look, it moves the list's selection and the
/// peek follows.
enum PeekArrow: Equatable {
    case up, down, left, right

    /// The arrow for a hardware key code (`NSEvent.keyCode`), nil for other keys.
    init?(keyCode: UInt16) {
        switch keyCode {
        case 123: self = .left
        case 124: self = .right
        case 125: self = .down
        case 126: self = .up
        default: return nil
        }
    }
}

extension WorktreeModel {
    /// Move the `section` list's selection for `arrow` and return the item the
    /// peek should now show, or nil when the key does nothing there. FILES: ↑/↓
    /// step through the visible rows, folders included; ←/→ collapse and expand, as
    /// in Finder's list view. CHANGES: ↑/↓ step through the changes. Both stop at
    /// the ends.
    func stepPeek(_ arrow: PeekArrow, in section: AppModel.FocusSection) -> FileNode? {
        switch section {
        case .files: return stepFilesPeek(arrow)
        case .changes: return stepChangesPeek(arrow)
        case .worktrees: return nil
        }
    }

    private func stepFilesPeek(_ arrow: PeekArrow) -> FileNode? {
        switch arrow {
        case .up: selectPrevious()
        case .down: selectNext()
        case .left: selectCollapseOrAscend()
        case .right: selectExpandOrDescend()
        }
        return selectedNode
    }

    private func stepChangesPeek(_ arrow: PeekArrow) -> FileNode? {
        let delta: Int
        switch arrow {
        case .up: delta = -1
        case .down: delta = 1
        case .left, .right: return nil
        }
        guard let change = moveChangeSelection(by: delta), let worktreePath else { return nil }
        return FileNode(path: worktreePath + "/" + change.path, isDirectory: false, change: change)
    }
}
