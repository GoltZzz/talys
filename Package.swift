// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Talys",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "talys", targets: ["Talys"])
    ],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder", from: "0.2.2")
    ],
    targets: [
        .target(
            name: "CTalysEngine",
            path: "Sources/CTalysEngine",
            publicHeadersPath: "include"
        ),
        .testTarget(name: "TalysTests", dependencies: ["Talys"]),
        .executableTarget(
            name: "Talys",
            dependencies: [
                "CTalysEngine",
                "TOMLDecoder"
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-LSources/CTalysEngine",
                    "-ltalys_engine"
                ])
            ]
        )
    ]
)
