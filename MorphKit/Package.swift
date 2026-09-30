// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MorphKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MorphKit", targets: ["MorphKit"]),
    ],
    dependencies: [
        // libwebp 1.6.0 (BSD-3-Clause), compiled from source.
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode", from: "1.6.0"),
    ],
    targets: [
        // resvg + vtracer + oxipng + quantizr, built by scripts/build-rust.sh.
        .binaryTarget(name: "MorphRust", path: "Binaries/MorphRust.xcframework"),
        .target(
            name: "MorphKit",
            dependencies: [
                "MorphRust",
                .product(name: "libwebp", package: "libwebp-Xcode"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MorphKitTests",
            dependencies: ["MorphKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
