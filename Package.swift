// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Chisel",
    platforms: [
        .macOS(.v14), .iOS(.v16), .visionOS(.v1), .tvOS(.v16), .watchOS(.v9)
    ],
    products: [
        .library(
            name: "Chisel",
            targets: ["ChiselKit"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "libchisel",
            url: "https://github.com/Snesnopic/chisel/releases/download/v1.7.0/Chisel.xcframework.zip",
            checksum: "97cec3dc1f5c53bdbac7ede2ebd6c39fc0e96ca69f77205fb12dea036f2308b4"
        ),
        
        .target(
            name: "ChiselWrapper",
            dependencies: ["libchisel"],
            path: "Sources/ChiselWrapper",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-std=c++20"])
            ]
        ),
        
        .target(
            name: "ChiselKit",
            dependencies: ["ChiselWrapper"],
            path: "Sources/ChiselKit"
        )
    ],
    cxxLanguageStandard: .cxx20
)
