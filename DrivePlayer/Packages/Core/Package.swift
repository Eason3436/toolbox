// swift-tools-version: 6.0
// DrivePlayer 的純邏輯：不 import UIKit／AVFoundation／SwiftUI／SwiftData，
// 所以可以在 Linux 直接 `swift test`。

import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "Core", targets: ["Core"]),
    ],
    targets: [
        .target(name: "Core"),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
    ]
)
