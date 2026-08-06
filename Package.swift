// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Maxima",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Maxima",
            path: "Sources/Maxima",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "MaximaTests",
            dependencies: ["Maxima"],
            path: "Tests/MaximaTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
