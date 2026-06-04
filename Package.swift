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
            url: "https://github.com/Snesnopic/chisel/releases/download/v1.5.0/Chisel.xcframework.zip",
            checksum: "d1fa1dc0f5841e30c2ae47604833d75e951e69bfe8fb7292d1ce4daa58a4fb4a"
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
