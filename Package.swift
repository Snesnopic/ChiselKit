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
            url: "https://github.com/Snesnopic/chisel/releases/download/v1.8.0/Chisel.xcframework.zip",
            checksum: "f1f10367e4dc9807d083d05ee2d5e42fab47f1264b2ffa85bc8f8a781ae828f2"
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
