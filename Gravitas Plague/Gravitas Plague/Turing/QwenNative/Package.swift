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
                // Debug exercises the qualification budget; Release uses the
                // bounded Phase 2R production recovery policy.
                .define(
                    "GR_TURING_METAL_RECOVERY_QUALIFICATION",
                    .when(configuration: .debug)
                ),
                .define(
                    "GR_TURING_METAL_STREAM_RECOVERY",
                    .when(configuration: .release)
                ),
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
                .define(
                    "GR_TURING_METAL_RECOVERY_QUALIFICATION",
                    .when(configuration: .debug)
                ),
                .define(
                    "GR_TURING_METAL_STREAM_RECOVERY",
                    .when(configuration: .release)
                ),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
