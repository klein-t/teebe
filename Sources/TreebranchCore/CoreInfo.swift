import Foundation

/// Top-level namespace + invariants for the Treebranch core library.
///
/// Intentionally tiny: it exists from M0 to prove the red→green→refactor loop and
/// the CI pipeline before any real logic lands.
public enum TreebranchCore {
    /// Library version (kept in sync with releases).
    public static let version = "0.1.0"
}
