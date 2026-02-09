// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PartialCacheTestPackage",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "Base", targets: ["Base"]),
        .library(name: "Bad", targets: ["Bad"]),
        .library(name: "Good", targets: ["Good"]),
    ],
    targets: [
        .target(name: "Base"),
        .target(name: "Bad", dependencies: ["Base"]),
        .target(name: "Good"),
    ]
)
