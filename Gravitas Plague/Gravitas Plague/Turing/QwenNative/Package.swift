// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TuringQwenNative",
    platforms: [
        .visionOS("2.0"),
        .macOS("15.0")
    ],
    products: [
        .library(
            name: "TuringQwenNative",
            targets: ["TuringQwenNative"]
        )
    ],
    dependencies: [
        .package(path: "../../../../ThirdParty/LocalSwiftPackages/mlx-swift")
    ],
    targets: [
        .target(
            name: "TuringQwenNative",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "TuringQwenNativeTests",
            dependencies: [
                "TuringQwenNative",
                .product(name: "MLX", package: "mlx-swift")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
