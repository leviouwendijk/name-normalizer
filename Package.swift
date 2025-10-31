// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "name-normalizer",
    platforms: [
        .macOS(.v13),
        .iOS(.v15)
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/leviouwendijk/plate.git",
            branch: "master"
        ),
        // .package(
        //     url: "https://github.com/apple/pkl-swift",
        //     from: "0.2.1"
        // ),
        // .package(
        //     url: "https://github.com/leviouwendijk/Structures.git",
        //     branch: "master"
        // ),
        // .package(
        //     url: "https://github.com/leviouwendijk/Parsers.git",
        //     branch: "master"
        // ),
        // .package(
        //     url: "https://github.com/leviouwendijk/Extensions.git",
        //     branch: "master"
        // ),
    ],
    targets: [
        .executableTarget(
            name: "nn",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "plate", package: "plate"),
                // .product(name: "PklSwift", package: "pkl-swift"),
                // .product(name: "Structures", package: "Structures"),
                // .product(name: "Parsers", package: "Parsers"),
                // .product(name: "Extensions", package: "Extensions"),
            ],
            sources: [
                "name-normalizer"
            ],
        )
    ]
)
