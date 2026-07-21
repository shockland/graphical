// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Graphical",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GraphicalDomain", targets: ["GraphicalDomain"]),
        .library(name: "GraphicalEngine", targets: ["GraphicalEngine"]),
        .library(name: "GraphicalCLI", targets: ["GraphicalCLI"]),
        .executable(name: "Graphical", targets: ["GraphicalApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "GraphicalDomain",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ]
        ),
        .target(
            name: "GraphicalCLI",
            dependencies: [
                "GraphicalDomain"
            ]
        ),
        .target(
            name: "GraphicalEngine",
            dependencies: [
                "GraphicalDomain",
                "GraphicalCLI",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .executableTarget(
            name: "GraphicalApp",
            dependencies: [
                "GraphicalDomain",
                "GraphicalEngine",
                "GraphicalCLI"
            ]
        ),
        .testTarget(
            name: "GraphicalDomainTests",
            dependencies: ["GraphicalDomain"]
        ),
        .testTarget(
            name: "GraphicalEngineTests",
            dependencies: [
                "GraphicalEngine",
                "GraphicalDomain",
                "GraphicalCLI"
            ]
        )
    ]
)
