// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Teebe",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TeebeCore", targets: ["TeebeCore"]),
        .executable(name: "Teebe", targets: ["Teebe"]),
    ],
    targets: [
        // Pure, UI-independent core: models, git layer, parsers, services.
        .target(
            name: "TeebeCore"
        ),
        // SwiftUI app: thin views + @Observable view models. Depends on Core.
        .executableTarget(
            name: "Teebe",
            dependencies: ["TeebeCore"],
            resources: [.process("Resources")]
        ),
        // Core unit + integration tests (Swift Testing).
        .testTarget(
            name: "TeebeCoreTests",
            dependencies: ["TeebeCore"]
        ),
        // View-model tests (Swift Testing) against the app target.
        .testTarget(
            name: "TeebeTests",
            dependencies: ["Teebe"]
        ),
    ],
    // Build in Swift 5 language mode (spec: "Swift 5.9+"). Keeps actor/Sendable
    // semantics pragmatic while still allowing `@Observable`, async/await, and
    // Swift Testing on a Swift 6 toolchain.
    swiftLanguageModes: [.v5]
)
