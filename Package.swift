// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nexus",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Nexus",
            path: "Sources/Nexus",
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist so macOS shows a proper camera/mic permission prompt
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Nexus/Info.plist",
                ]),
            ]
        ),
    ]
)
