// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KubeKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "KubeModels", targets: ["KubeModels"]),
        .library(name: "KubeKit", targets: ["KubeKit"]),
        .library(name: "KubeKeychain", targets: ["KubeKeychain"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        // Layer 1: data types only. No networking, no platform frameworks, no SwiftUI.
        .target(name: "KubeModels"),

        // Layer 2: transport, auth contracts, kubeconfig parsing, error mapping.
        .target(
            name: "KubeKit",
            dependencies: [
                "KubeModels",
                .product(name: "Yams", package: "Yams"),
            ]
        ),

        // Layer 3: platform-backed implementation of KubeKit's storage contract.
        .target(name: "KubeKeychain", dependencies: ["KubeKit", "KubeModels"]),

        // Test-only doubles, shared by the test targets.
        .target(name: "KubeTestSupport", dependencies: ["KubeKit", "KubeModels"]),

        .testTarget(name: "KubeModelsTests", dependencies: ["KubeModels"]),
        .testTarget(name: "KubeKitTests", dependencies: ["KubeKit", "KubeTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
