// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Treebranch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TreebranchCore", targets: ["TreebranchCore"]),
        .executable(name: "Treebranch", targets: ["Treebranch"]),
    ],
    targets: [
        // Pure, UI-independent core: models, git layer, parsers, services.
        .target(
            name: "TreebranchCore"
        ),
        // SwiftUI app: thin views + @Observable view models. Depends on Core.
        .executableTarget(
            name: "Treebranch",
            dependencies: ["TreebranchCore"],
            resources: [.process("Resources")]
        ),
        // Core unit + integration tests (Swift Testing).
        .testTarget(
            name: "TreebranchCoreTests",
            dependencies: ["TreebranchCore"]
        ),
        // View-model tests (Swift Testing) against the app target.
        .testTarget(
            name: "TreebranchTests",
            dependencies: ["Treebranch"]
        ),
    ],
    // Build in Swift 5 language mode (spec: "Swift 5.9+"). Keeps actor/Sendable
    // semantics pragmatic while still allowing `@Observable`, async/await, and
    // Swift Testing on a Swift 6 toolchain.
    swiftLanguageModes: [.v5]
)
