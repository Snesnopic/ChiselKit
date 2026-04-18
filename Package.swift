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
            url: "https://github.com/Snesnopic/chisel/releases/download/v1.4.1/Chisel.xcframework.zip",
            checksum: "68c71fea4b55d90508d37eb52b8f4afbdd69a56bb39623777873c8f8a551a2a0"
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
