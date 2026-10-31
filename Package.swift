// swift-tools-version:5.9
// Mac 原生重构（docs/REFACTOR_PLAN.md）。OCRCore 是纯 Swift，Linux 上也能编译和跑单测；
// 依赖 Apple 框架的部分（Vision / PDFKit / Core ML）都在 OCREngines，用 canImport 隔开。
import PackageDescription

let package = Package(
    name: "DocOCR",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OCRCore", targets: ["OCRCore"]),
        .executable(name: "ocr-cli", targets: ["ocr-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.33.0")),
    ],
    targets: [
        .target(name: "OCRCore", path: "mac/Sources/OCRCore"),
        .target(name: "OCRVL", dependencies: [
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXFast", package: "mlx-swift"),
        ], path: "mac/Sources/OCRVL"),
        .target(name: "OCREngines", dependencies: ["OCRCore"], path: "mac/Sources/OCREngines"),
        .executableTarget(name: "ocr-cli", dependencies: ["OCRCore", "OCREngines", "OCRVL"],
                          path: "mac/Sources/ocr-cli"),
        .testTarget(name: "OCRCoreTests", dependencies: ["OCRCore"], path: "mac/Tests/OCRCoreTests"),
        .testTarget(name: "OCREnginesTests", dependencies: ["OCREngines", "OCRCore"], path: "mac/Tests/OCREnginesTests"),
    ]
)
