// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tabby",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Tabby", targets: ["Tabby"])
    ],
    targets: [
        .executableTarget(
            name: "Tabby",
            path: "Sources/Tabby"
        )
    ],
    // Swift 6.1 on GitHub's macOS runner diagnoses AppKit's MainActor
    // annotations more strictly than the local Swift 6.2 toolchain. The app
    // already confines UI work to the main thread; keep source compatibility
    // across the release toolchains without weakening runtime behavior.
    swiftLanguageModes: [.v5]
)
