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
            url: "https://github.com/Snesnopic/chisel/releases/download/v1.10.0/Chisel.xcframework.zip",
            checksum: "8f72cee086a1c52751e9238d55587eb91295da5d24f346c366d860fef8fe61f0"
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
