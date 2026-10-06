// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Bore",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Bore",
            path: "Bore"
        )
    ]
)
