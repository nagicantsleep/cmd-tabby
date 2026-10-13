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
    ]
)
