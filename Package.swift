// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TodooCard",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "TodooCore", targets: ["TodooCore"]),
        .executable(name: "TodooCoreChecks", targets: ["TodooCoreChecks"]),
    ],
    targets: [
        .target(name: "TodooCore"),
        .executableTarget(name: "TodooCoreChecks", dependencies: ["TodooCore"]),
    ]
)
