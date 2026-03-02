// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sir-mix-a-layout",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "sir-mix-a-layout", targets: ["SirMixALayout"])
    ],
    targets: [
        .executableTarget(
            name: "SirMixALayout",
            path: "Sources/SirMixALayout"
        )
    ]
)
